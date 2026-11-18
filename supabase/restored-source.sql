-- restored-source.sql — build 44, change 2 (owner-directed, Nov 18, 2026).
--
-- DASHBOARD-APPLY FILE — NOT yet applied live. Apply via the Supabase
-- dashboard SQL Editor (project "Budget", ref tnkhvdkmwmwiogiienee)
-- BEFORE, or together with, deploying the build-44 native app that
-- calls force_restore_transaction. Until it lands, Trash Restore on a
-- no-snapshot row keeps refusing with 'cannot restore: no prior state
-- recorded' — the normal restore path is untouched by this file, so
-- nothing else changes. Verify after applying:
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--     where conrelid = 'transactions'::regclass
--       and pg_get_constraintdef(oid) like '%restored%';
--   select proname from pg_proc where proname = 'force_restore_transaction';
--   select grantee, privilege_type from information_schema.routine_privileges
--     where routine_name = 'force_restore_transaction';
-- Expected: the source check lists ('csv', 'amex_alert', 'plaid',
-- 'manual', 'restored'); force_restore_transaction exists;
-- authenticated has EXECUTE on it, public/anon do not.
-- Re-running is safe: the constraint drop is looked up by definition
-- (never guessed), the re-add is idempotent in effect, and the RPC is
-- CREATE OR REPLACE.
--
-- WHY: Plaid's /transactions/sync can return a row in removed[] that
-- the bank still reports — the $3,500 check deposit (Nov 17, 2026)
-- is the live case: plaid-sync marked it state='reversed' +
-- excluded=true without going through exclude_transaction, so no
-- pre_exclusion_state snapshot was ever recorded and the normal
-- restore_transaction refuses it by design (N4: no date fallback —
-- a pending row restored as posted after midnight was the exact bug
-- N4 was written to kill). The $3,500 row was already restored by a
-- one-off owner-approved SQL repair (Nov 18 ~11:05) — do NOT
-- re-restore it, and do NOT use this file on it. This file gives
-- the app a sanctioned path for the REMAINING bank-dropped rows
-- (e.g. the $75 Mobile Check Deposit, Nov 12): the admin confirms
-- in the app, and the row comes back as verified with
-- source='restored' so it is never again mistaken for a bank,
-- email, file, or hand-entered row.
--
-- DECISIONS (owner, Nov 18):
--   (1) New source value 'restored', displayed "Restored" — not
--       bank, not email. The constraint below adds it alongside
--       the four existing values; no value is dropped.
--   (2) A NEW RPC, force_restore_transaction — the normal
--       restore_transaction is NOT modified. The normal path keeps
--       the original source and restores the stored snapshot;
--       the force path only ever runs on rows WITH NO snapshot.
--   (3) The force-restored row comes back state='verified'
--       (posted): the admin has confirmed with the bank that the
--       money is really there — that confirmation IS the posting
--       evidence N4 demanded. It does NOT come back provisional.
--
-- No secrets, tokens, or keys appear in this file.

-- ---------------------------------------------------------------------
-- §1 — source check: add 'restored' alongside the existing values.
-- The original schema.sql check is anonymous, so its generated name
-- is looked up from pg_constraint by definition rather than guessed
-- (same pattern as supabase/transfer-kind.sql). The lookup matches
-- the definition containing 'csv' so the debt-fund source check
-- (extra_fund/surplus/clear) and the kind check are never touched.
-- ---------------------------------------------------------------------
do $$
declare
  c text;
begin
  select conname into c
    from pg_constraint
   where conrelid = 'transactions'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) like '%''csv''%';
  if c is not null then
    execute 'alter table transactions drop constraint ' || quote_ident(c);
  end if;
end $$;

alter table transactions
  add constraint transactions_source_check
  check (source in ('csv', 'amex_alert', 'plaid', 'manual', 'restored'));

-- ---------------------------------------------------------------------
-- force_restore_transaction(txn_id uuid) returns void
--   Force-restore a bank-dropped Trash row that has NO
--   pre_exclusion_state snapshot. Mirrors restore_transaction
--   (supabase/n4-pre-exclusion-state.sql) guard-for-guard — same
--   auth check, same admin-only membership check, same 35-day
--   locked-week check, same 'not excluded or reversed' guard, same
--   linked-refund check, same best-effort refund re-link, same
--   audit row — with exactly two deliberate differences:
--     * it REFUSES rows that HAVE a snapshot ('transaction has a
--       prior state recorded: use restore_transaction') — those
--       rows take the normal path, which restores their stored
--       state and keeps their original source;
--     * it restores as state='verified' with source='restored'
--       (see header decision 3) and clears the snapshot/reason.
--   The locked-week check is kept on purpose (P2-NEW1 in the N4
--   file): a locked week's transactions are immutable through the
--   mutation RPCs, and a force-restore re-enters the row into
--   compute-week's live recompute. The sanctioned locked-week
--   restore stays the one-off owner-approved SQL repair in the
--   SQL editor, never this RPC from the app.
-- ---------------------------------------------------------------------
create or replace function public.force_restore_transaction(txn_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
  v_original_kind text;
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Same 35-day locked-week check as restore_transaction (P1-M2 /
  -- P2-NEW1, n4-pre-exclusion-state.sql).
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
  end if;
  if v_row.state <> 'excluded' and v_row.state <> 'reversed' then
    raise exception 'transaction is not excluded or reversed';
  end if;
  -- THE force-restore guard: a row WITH a snapshot takes the normal
  -- path. Only a NULL snapshot (bank-dropped, never snapshotted)
  -- may be force-restored.
  if v_row.pre_exclusion_state is not null then
    raise exception 'transaction has a prior state recorded: use restore_transaction';
  end if;
  -- Refund check (same as restore_transaction, via the real linkage
  -- column): a linked refund restores only while its original
  -- purchase still exists. Unlinked refunds restore without it.
  if v_row.kind = 'refund' and v_row.original_purchase_id is not null then
    select kind into v_original_kind from transactions where id = v_row.original_purchase_id;
    if v_original_kind is null then
      raise exception 'cannot restore refund: original transaction is missing';
    end if;
  end if;
  update transactions
    set excluded = false, state = 'verified', exclude_reason = '',
        pre_exclusion_state = null, source = 'restored'
    where id = txn_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction force-restored',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents force-restored as verified '
            || '(bank-dropped row, no prior state recorded; source set to restored).');
  -- Same best-effort refund re-link as restore_transaction (P2-N7):
  -- a linking failure must never fail the restore.
  begin
    if v_row.kind = 'refund' then
      perform public.auto_link_refund(txn_id);
    elsif v_row.kind in ('charge', 'fund_charge') then
      perform public.link_refunds_to_purchase(txn_id);
    end if;
  exception when others then
    null;
  end;
end;
$$;
revoke execute on function public.force_restore_transaction(uuid) from public;
grant execute on function public.force_restore_transaction(uuid) to authenticated;

-- =====================================================================
-- VERIFICATION (commented — run manually after deploy, do NOT run
-- blindly against production data; use a throwaway transaction in a
-- TEST household, never the live household):
--   -- Source constraint allows 'restored', keeps the old values:
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--     where conrelid = 'transactions'::regclass
--       and pg_get_constraintdef(oid) like '%restored%';
--     -- expect: transactions_source_check,
--     -- check (source in ('csv', 'amex_alert', 'plaid', 'manual', 'restored'))
--   -- Force-restore REFUSES a row WITH a snapshot (as admin,
--   -- throwaway row excluded via exclude_transaction first):
--   select force_restore_transaction('<txn-uuid-with-snapshot>');
--     -- expect: ERROR 'transaction has a prior state recorded:
--     -- use restore_transaction'; row unchanged.
--   -- Normal restore still refuses NULL snapshots, unchanged
--   -- (run FIRST on the same throwaway row — it refuses and the
--   -- row stays excluded — then force-restore it below):
--   select restore_transaction('<txn-uuid-no-snapshot>');
--     -- expect: ERROR 'cannot restore: no prior state recorded'
--   -- Force-restore restores a NULL-snapshot row (as admin,
--   -- throwaway row excluded by a direct update, never via
--   -- exclude_transaction, so no snapshot exists):
--   select force_restore_transaction('<txn-uuid-no-snapshot>');
--   select state, excluded, source, pre_exclusion_state from transactions
--    where id = '<txn-uuid-no-snapshot>';
--     -- expect: state 'verified', excluded false,
--     -- source 'restored', pre_exclusion_state null
--   -- Audit row written:
--   select action, detail from audit_log
--    where household_id = '<test-household-uuid>'
--    order by created_at desc limit 1;
--     -- expect: action 'Transaction force-restored'
-- =====================================================================
