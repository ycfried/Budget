-- Household Budget — refund restoration snapshots + held queue (S2).
-- Apply BEFORE deploying the new compute-week / week-close Edge
-- Functions. This file is additive only: no column, table, or row is
-- dropped, and no existing value is rewritten.
--
-- WHAT IT ADDS
-- 1. Per-week policy snapshots on week_closes (audit P0-11):
--    base_allowance_cents + temp_increase_cents, stamped by week-close
--    at close time. A recompute uses the snapshot, never the
--    household's current allowance. late_adjustment_cents freezes
--    locked-week late charges into the week that absorbs them
--    (audit P0-9, total-minus-stored rule in week-close).
-- 2. surplus_releases.closed_at, so the 7-day pending window anchors
--    to the actual close date (audit P1-6: release_date =
--    closed_at + 7 days for new closes).
-- 3. restoration_entries: ONE row per posted refund event (unique on
--    refund_transaction_id — the idempotency key). Columns:
--      id, household_id, week_start (posting week), purchase_ +
--      refund_transaction_id, restored_surplus_cents,
--      debt_reduction_cents, fund_credit_cents, created_at.
--    fund_credit_cents is an S2 addition beyond the brief's listed
--    columns: without it, a fund-purchase refund ($60 case) has no
--    idempotent record and would re-credit on every week-close run.
--    Transaction ids intentionally have NO foreign key to
--    transactions: an entry must survive its refund row being
--    corrected, so the audit trail is never deleted by cascade.
-- 4. held_refunds: refund amounts beyond the original charge, queued
--    for admin review (status 'pending' / 'resolved').
-- 5. transactions linkage columns: original_purchase_id (the purchase
--    a refund restores; self-referencing, null on delete), plus
--    plaid_pending_transaction_id and plaid_transaction_id (Plaid
--    pending/posted linking; the S3 workstream owns populating them).
-- 6. fund_ledger kind 'restoration', so restoration credits are
--    distinguishable from releases/allocations/adjustments.
--
-- WHAT IT DELIBERATELY DOES NOT DO
-- - It does NOT drop week_closes.outgoing_credit_cents or the
--   surplus_releases 'held' status value. Old rows keep their values
--   for history, but no S2 code writes or reads them anymore. A
--   future migration may drop them once the parent confirms no other
--   reader depends on them.
-- - It does NOT extend the transactions kind check to 'payment' /
--   'cashback'. Kinds are the S3 workstream's file; compute-week and
--   week-close already filter those kinds by string, so the filter
--   works as soon as S3 extends the check.
-- - It grants NO direct member write access to the new tables
--   (RLS hardening is another workstream's file). Members get SELECT
--   only. Until that workstream provides a write path for the
--   week-close Edge Function (service-role key or SECURITY DEFINER
--   RPCs), restoration inserts will fail loudly in week-close — see
--   S2_NOTES.md "Blocking dependency". Do not "fix" this by adding
--   permissive member INSERT policies here; that would reintroduce
--   the direct-write bypass (audit P0-2).
--
-- RPC DEPENDENCIES (defined by other workstreams, called by name):
-- - update_fund_shortfall(household_id, shortfall_cents) [S1]:
--   week-close calls it with exactly these argument names. If S1
--   names the parameters differently, week-close's call must change.
-- - reclassify_transaction [S1]: compute-week needs no call; it
--   counts every row under its CURRENT kind, so a reclassified
--   cash-back row automatically stops being excluded.

create extension if not exists pgcrypto;

-- 1. Snapshots + late adjustment on week_closes.
alter table week_closes
  add column if not exists base_allowance_cents integer,
  add column if not exists temp_increase_cents integer,
  add column if not exists late_adjustment_cents integer not null default 0;

-- 2. Actual close time on surplus_releases.
alter table surplus_releases
  add column if not exists closed_at timestamptz;

-- 3. Restoration entries (one per refund event).
create table if not exists restoration_entries (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  week_start date not null,
  purchase_transaction_id uuid,
  refund_transaction_id uuid not null,
  restored_surplus_cents integer not null default 0,
  debt_reduction_cents integer not null default 0,
  fund_credit_cents integer not null default 0,
  created_at timestamptz not null default now(),
  unique (refund_transaction_id)
);
create index if not exists restoration_entries_household_purchase_idx
  on restoration_entries (household_id, purchase_transaction_id);

-- 4. Held excess refunds.
create table if not exists held_refunds (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  refund_transaction_id uuid not null,
  purchase_transaction_id uuid,
  held_cents integer not null check (held_cents > 0),
  status text not null default 'pending' check (status in ('pending', 'resolved')),
  resolution_note text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (refund_transaction_id)
);
create index if not exists held_refunds_household_status_idx
  on held_refunds (household_id, status);

-- 5. Transactions linkage columns.
alter table transactions
  add column if not exists original_purchase_id uuid references transactions(id) on delete set null,
  add column if not exists plaid_pending_transaction_id text,
  add column if not exists plaid_transaction_id text;
create index if not exists transactions_original_purchase_idx
  on transactions (household_id, original_purchase_id);

-- 6. Fund ledger 'restoration' kind (drop + re-add the check with the
--    new value; existing kinds are unchanged).
alter table fund_ledger drop constraint if exists fund_ledger_kind_check;
alter table fund_ledger add constraint fund_ledger_kind_check
  check (kind in ('release', 'allocation', 'override_allocation', 'adjustment', 'reversal', 'restoration'));

-- RLS: members read their own household's rows only. NO member
-- INSERT/UPDATE/DELETE policies are created here (see header).
alter table restoration_entries enable row level security;
alter table held_refunds enable row level security;
create policy "members read own restoration entries"
  on restoration_entries for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));
create policy "members read own held refunds"
  on held_refunds for select
  using (household_id in (select household_id from household_members where user_id = auth.uid()));
grant select on restoration_entries to authenticated;
grant select on held_refunds to authenticated;

-- resolve_held_refund: admin-only, SECURITY DEFINER.
-- Semantics (exact — see S2_NOTES.md for the flagged 'release' item):
-- - action 'write_off' or 'resolve': closes the held row WITHOUT
--   moving any money (status -> 'resolved', resolved_at = now(),
--   resolution_note = note, or the action name when note is empty).
--   An audit_log row records held_id, action, and note. This is the
--   admin-reviewed closure path: the excess amount is acknowledged
--   and written off the queue, not credited anywhere.
-- - action 'release' (owner decision 2, Nov 2, 2026): the held excess
--   becomes spendable surplus. Like a weekly surplus release, it
--   offsets the fund shortfall first; the remainder posts to
--   fund_ledger as kind='release' (immediately spendable — no 7-day
--   pending, because the admin explicitly released it). Then the held
--   row resolves with its own audit record stating the amounts.
-- - any other action, a missing row, a non-pending row, or a
--   non-admin caller: exception, no change.
create or replace function public.resolve_held_refund(p_held_id uuid, p_action text, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row held_refunds%rowtype;
  v_note text;
  v_shortfall integer;
  v_applied integer;
  v_to_fund integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from held_refunds where id = p_held_id;
  if not found then raise exception 'held refund not found'; end if;
  if v_row.status <> 'pending' then raise exception 'held refund is not pending'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if p_action = 'release' then
    select fund_shortfall_cents into v_shortfall from households where id = v_row.household_id;
    v_shortfall := coalesce(v_shortfall, 0);
    v_applied := least(v_shortfall, v_row.held_cents);
    v_to_fund := v_row.held_cents - v_applied;
    if v_to_fund > 0 then
      insert into fund_ledger (household_id, kind, amount_cents, note, created_by)
        values (v_row.household_id, 'release', v_to_fund,
                'Held refund ' || p_held_id::text || ' released to spendable surplus.', auth.uid());
    end if;
    if v_applied > 0 then
      update households set fund_shortfall_cents = v_shortfall - v_applied where id = v_row.household_id;
    end if;
    v_note := nullif(btrim(coalesce(p_note, '')), '');
    if v_note is null then v_note := 'release'; end if;
    update held_refunds
      set status = 'resolved', resolved_at = now(), resolution_note = v_note
      where id = p_held_id;
    insert into audit_log (household_id, actor, actor_name, action, detail)
      values (v_row.household_id, auth.uid(), 'admin', 'Held refund released',
              'Held refund ' || p_held_id::text || ' released to spendable surplus: '
              || v_to_fund::text || ' cents to the fund, '
              || v_applied::text || ' cents offset shortfall.');
    return;
  end if;
  if p_action not in ('write_off', 'resolve') then
    raise exception 'unknown action: % (expected write_off, resolve, or release)', p_action;
  end if;
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if v_note is null then v_note := p_action; end if;
  update held_refunds
    set status = 'resolved', resolved_at = now(), resolution_note = v_note
    where id = p_held_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Held refund resolved',
            'Held refund ' || p_held_id::text || ' resolved via ' || p_action
            || ' (' || v_note || '). No money was moved.');
end;
$$;
revoke execute on function public.resolve_held_refund(uuid, text, text) from public;
grant execute on function public.resolve_held_refund(uuid, text, text) to authenticated;
