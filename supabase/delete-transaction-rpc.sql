-- Household Budget — delete_transaction RPC (Nov 1, 2026).
-- WHY: the live app needs a delete option, but deleting must stay
-- honest. A hand-entered (manual) purchase can be truly deleted —
-- it exists only in this app. A bank / email-alert / file row cannot
-- be erased: the bank would re-sync it on the next pull, so the app
-- must exclude those rows instead (the UI's "Remove" button does
-- that directly; this RPC refuses them). So this RPC:
--   * admin only (a member cannot delete the household's record);
--   * refuses any row whose source is not 'manual';
--   * hard-deletes the row and writes an audit row first, so the
--     deletion itself stays in the append-only audit log.
-- Granted to authenticated only, never to public.
-- MATH-NEW1 (Nov 9, 2026): locked-week 35-day check added — the same
-- rule as exclude/restore/reclassify (n4-pre-exclusion-state.sql) and
-- mark_transaction_charity. Deleting a not-yet-adjusted manual row in
-- a locked week would remove its pending late charge from the current
-- week's figures via latePart while the stored close keeps it, so the
-- delete refuses here like every other mutation RPC. Apply this file
-- live to land the fix (CREATE OR REPLACE, idempotent, no other
-- change); the copy in 04-admin-rpcs.sql §5 is kept identical in-repo.
--
-- F-2 (build 61 audit, Nov 23, 2026): BEFORE DELETE guard
-- (trg_transactions_delete_guard below). Before this fix, deleting
-- a manual income row left its charity_income row status='active'
-- with transaction_id nulled by the ON DELETE SET NULL FK — an
-- orphaned accrual that kept overstating committed charity AND was
-- invisible to the missed-reversal detection query in
-- reclassify-income-accrual.sql (it joins on transaction_id).
-- Deleting a manual charge with a live linked refund orphaned the
-- refund the same way (it became unlinked and netted in its own
-- week). Both break standing rules: the charity invariant and
-- "linked transactions must not be breakable" (owner, Nov 20).
--   The guard, which fires for EVERY delete path (not just this
--   RPC — a direct SQL delete is caught too):
--   * reverses any ACTIVE charity accrual linked to the row
--     (status -> 'reversed', append-only, with a matching audit
--     row) and detaches the link explicitly (transaction_id NULL),
--     so the orphan can never exist;
--   * REFUSES the delete when a live linked refund exists in
--     either direction — a refund linked TO this row, or this row
--     being a refund linked to a live purchase — with a clear
--     message. The admin must handle the refund first (re-point
--     it with link_refund, or exclude the pair together); the
--     delete never silently strands it.
--   The FK stays ON DELETE SET NULL (charity-auto-accrue.sql): a
--   conditional ON DELETE RESTRICT ("restrict only when an active
--   accrual exists") does not exist in Postgres, and an
--   unconditional RESTRICT would also block deletes of rows whose
--   accrual was already reversed. The trigger does the conditional
--   work; SET NULL is only the backstop for a row the trigger
--   somehow missed (which the verification query below detects).
create or replace function public.guard_transaction_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_accrual record;
  v_refund record;
  v_committed bigint;
begin
  -- (1) Reverse any ACTIVE charity accrual linked to this row.
  -- At most one can be active (partial unique index
  -- charity_income_household_transaction_uidx), but loop
  -- defensively so a second active row could never slip through.
  for v_accrual in
    select id, household_id, amount_cents, rate_bp, source_label
      from public.charity_income
     where transaction_id = OLD.id
       and status = 'active'
  loop
    update public.charity_income
       set status = 'reversed', transaction_id = null
     where id = v_accrual.id;
    v_committed := (v_accrual.amount_cents::bigint * v_accrual.rate_bp + 5000) / 10000;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (v_accrual.household_id, null, 'auto-accrual', 'Charity income reversed',
            'Income ' || v_accrual.source_label || ' ' || v_accrual.amount_cents::text || ' cents'
            || ' at ' || v_accrual.rate_bp::text || ' basis points was deleted; '
            || v_committed::text || ' cents deducted from charity owed.');
  end loop;
  -- (2) Refuse when a live refund is linked TO this row (this row
  -- is a purchase with a live refund). A reversed / excluded refund
  -- does not block: it no longer counts anywhere.
  select id, merchant, amount_cents into v_refund
    from public.transactions
   where original_purchase_id = OLD.id
     and kind = 'refund'
     and excluded is not true
     and state not in ('excluded', 'reversed')
   limit 1;
  if v_refund.id is not null then
    raise exception 'cannot delete: a live refund (% % cents) is linked to this transaction — re-point or exclude the refund first',
      v_refund.merchant, v_refund.amount_cents;
  end if;
  -- (3) Refuse when THIS row is a refund linked to a live purchase.
  if OLD.kind = 'refund' and OLD.original_purchase_id is not null then
    if exists (select 1 from public.transactions
                where id = OLD.original_purchase_id
                  and excluded is not true
                  and state not in ('excluded', 'reversed')) then
      raise exception 'cannot delete: this refund is linked to a live purchase — unlink it first';
    end if;
  end if;
  return OLD;
end;
$$;

drop trigger if exists trg_transactions_delete_guard on public.transactions;
create trigger trg_transactions_delete_guard
  before delete on public.transactions
  for each row execute function public.guard_transaction_delete();
create or replace function public.delete_transaction(p_transaction_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  hid uuid;
  src text;
  merch text;
  amt integer;
  tx_date date;
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select household_id, source, merchant, amount_cents, date
    into hid, src, merch, amt, tx_date from transactions where id = p_transaction_id;
  if hid is null then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = hid and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- MATH-NEW1 (Nov 9, 2026): a locked week's transactions are immutable
  -- through the mutation RPCs — the same 35-day rule as
  -- exclude/restore/reclassify (P1-M2). Locked-week corrections go
  -- through restoration, never a direct edit or delete.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := tx_date - extract(dow from tx_date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
  end if;
  if src <> 'manual' then
    raise exception 'only hand-entered purchases can be deleted; bank records must be removed from the budget instead';
  end if;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (hid, auth.uid(), 'admin', 'Transaction deleted',
            merch || ' ' || amt::text || ' cents (manual entry) deleted by admin.');
  delete from transactions where id = p_transaction_id;
end;
$$;
revoke execute on function public.delete_transaction(uuid) from public;
grant execute on function public.delete_transaction(uuid) to authenticated;

-- =====================================================================
-- VERIFICATION (F-2, commented — run manually after applying, on a
-- TEST household first, never the live household):
--   -- Trigger exists:
--   select tgname from pg_trigger
--    where tgname = 'trg_transactions_delete_guard';  -- 1 row
--   -- Deleting a manual income row with an active accrual reverses
--   -- it (as admin, throwaway manual income row, $100.00, that
--   -- accrued 1000 cents): the row deletes, the accrual is
--   -- status='reversed' with transaction_id NULL, and the committed
--   -- total drops by 1000 cents:
--   select delete_transaction('<manual-income-txn>');
--   select status, transaction_id from charity_income
--    where household_id = '<household>' and source_label = '<merchant>';
--     -- expect: status 'reversed', transaction_id null
--   -- Deleting a manual purchase with a live linked refund REFUSES:
--   select delete_transaction('<manual-purchase-with-refund>');
--     -- expect: ERROR 'cannot delete: a live refund ... is linked
--     -- to this transaction'
--   -- Deleting a manual refund linked to a live purchase REFUSES:
--   select delete_transaction('<manual-refund-linked>');
--     -- expect: ERROR 'cannot delete: this refund is linked to a
--     -- live purchase'
--   -- No orphaned ACTIVE auto-accrual may exist (detection query
--   -- — the one the old bug hid from; expect 0 rows, any household).
--   -- Hand-recorded accruals have transaction_id NULL by design, so
--   -- the query scopes to auto-accrued rows only (note =
--   -- 'Auto-accrued from synced income'), which must always keep
--   -- their link while active:
--   select count(*) from charity_income
--    where status = 'active' and transaction_id is null
--      and note = 'Auto-accrued from synced income';
--     -- expect: 0
-- =====================================================================
