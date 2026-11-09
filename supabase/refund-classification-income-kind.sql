-- Refund misclassification fix — add 'income' as an 8th transaction kind.
-- CANONICAL KIND CONSTRAINT (P1-B5, Nov 8, 2026): this file holds the
-- single authoritative transactions_kind_check (8 kinds). No other
-- file's kind list may be applied — merged-audit-kind-constraint.sql
-- (7 kinds, no income) and schema.sql's original 3-kind list are both
-- superseded and bannered never-reapply.
-- Owner-approved Nov 5, 2026. DO NOT APPLY LIVE without the owner's
-- explicit approval of the statements in the branch HANDOFF addendum
-- (HANDOFF.md, "Refund classification fix — live correction, owner
-- approval pending"): the constraint + RPC below must be applied
-- FIRST, in order, and only then the three reclassifications and the
-- $700 charity recording. This file is the schema/RPC step only.
--
-- Background: four verified rows on the Rewards Checking account
-- (••1636, week Nov 1–7) were classified kind='refund' and netted in
-- full, uncapped, against the week's charges, flooring hero spent to
-- $0. Owner confirmed: MOBILE CHECK DEPOSIT -$7,000.00 is INCOME,
-- ONLINE TRANSFER / PAYMENT: CREDIT -$1,012.79 is a CC PAYMENT,
-- PRIME STRATEGIC CORPORATION -$350.00 is a TRANSFER (friend's money,
-- pass-through, no charity), NORDSTROM -$158.97 is a genuine REFUND
-- and stays a refund. See REFUND_CLASSIFICATION_FIX_PLAN.md.
--
-- STEP 0 — VERIFY LIVE FIRST (read-only; run these and compare before
-- applying anything). Expected: constraint = the 7-kind list below;
-- reclassify allow-list = the 6-kind list (no 'charity' — the repo
-- copy matches that; if live already allows 'charity', KEEP it in
-- the new allow-list below instead of dropping it, and report the
-- difference; do not add it as a side effect if live does not have
-- it). Also verify no week_closes row exists for 2026-11-01 yet —
-- if one does, STOP and use the restoration path instead.
--
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--   where conrelid = 'transactions'::regclass and conname = 'transactions_kind_check';
--   select pg_get_functiondef(oid) from pg_proc
--   where proname = 'reclassify_transaction';
--   select count(*) from week_closes where week_start = '2026-11-01';
--
-- STEP 1 — Extend the kind constraint to 8 kinds (superset of the
-- live 7; dropping/re-adding a CHECK changes no rows and fails only
-- if a row already holds a kind outside the new list).
alter table transactions drop constraint if exists transactions_kind_check;
alter table transactions
  add constraint transactions_kind_check
  check (kind in ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income'));

-- STEP 2 — Extend reclassify_transaction to allow 'income' AND
-- 'charity' ('charity' added Nov 8, 2026, P1-NEW1). The 'charity'
-- entry is the ADMIN OVERRIDE only: it lets reclassify_transaction
-- set kind='charity' directly, bypassing mark_transaction_charity's
-- posted/unlocked-week guards. The client never calls it that way —
-- doTxReclassify dispatches Charity to mark_transaction_charity
-- (guarded path). Identical to supabase/05-transaction-mutation-rpcs.sql
-- except the allow-list and the error message gain 'income' and
-- 'charity'. Admin-only and the audit row are unchanged. Do NOT apply
-- the 05 file in full (its §1 Approve is outdated and would break Approve).
create or replace function public.reclassify_transaction(txn_id uuid, new_kind text, reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if new_kind is null or new_kind not in ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'transfer', 'income', 'charity') then
    raise exception 'invalid kind: must be charge, refund, fund_charge, payment, cashback, transfer, income, or charity';
  end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- P1-M2 (Nov 8, 2026): a locked week's transactions are immutable
  -- through the mutation RPCs — the same 35-day rule as
  -- mark_transaction_charity (r13-charity.sql). Locked-week
  -- corrections go through restoration, never a direct edit.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
  end if;
  update transactions set kind = new_kind where id = txn_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction reclassified',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents reclassified from '
            || v_row.kind || ' to ' || new_kind
            || case when reason is not null and btrim(reason) <> ''
                    then ' — reason: ' || reason else ' — no reason given' end || '.');
end;
$$;
revoke execute on function public.reclassify_transaction(uuid, text, text) from public;
grant execute on function public.reclassify_transaction(uuid, text, text) to authenticated;

-- VERIFICATION (run after applying, read-only):
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--   where conrelid = 'transactions'::regclass and conname = 'transactions_kind_check';
--   -- expected: kind in ('charge','refund','fund_charge','payment','cashback','charity','transfer','income')
--   select pg_get_functiondef(oid) from pg_proc where proname = 'reclassify_transaction';
--   -- expected: allow-list contains 'income'
