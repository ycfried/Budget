-- charity-auto-accrue.sql — build 44, item 5 (charity auto-accrual).
--
-- DASHBOARD-APPLY FILE — NOT yet applied live. Apply via the Supabase
-- dashboard SQL Editor (project "Budget", ref tnkhvdkmwmwiogiienee)
-- BEFORE, or together with, deploying the build-44 plaid-sync /
-- gmail-poll / ingest-amex-alert Edge Functions. Until it lands, the
-- functions' accrual hook fails open (logs, sync/ingest continues) —
-- no charity is accrued, nothing else breaks. Verify after applying:
--   select column_name from information_schema.columns
--     where table_name = 'charity_income' and column_name = 'transaction_id';
--   select indexname from pg_indexes
--     where indexname = 'charity_income_household_transaction_uidx';
--   select proname from pg_proc where proname = 'accrue_charity_for_transaction';
--   select grantee, privilege_type from information_schema.routine_privileges
--     where routine_name = 'accrue_charity_for_transaction';
-- Expected: the column exists, the partial unique index exists,
-- service_role has EXECUTE on the RPC, authenticated does not.
--
-- DECISION (owner rule, build 44): income auto-accrues charity at the
-- household default rate (10% unless changed) when an income
-- transaction is DETECTED. The RPC below accrues VERIFIED rows only
-- (the ingest hook calls it on the pending→posted transition, and
-- on insert of a verified row); a provisional income row accrues
-- through the TRIGGER instead (reclassify-income-accrual.sql v4:
-- provisional income accrues immediately when it becomes income
-- by reclassification / restore, owner rule Nov 22, 2026 — pending
-- counts toward totals). Transfers, refunds, card payments, and
-- cashback NEVER accrue: only kind='income' rows reach the RPC, and
-- the RPC refuses every other kind itself.
--
-- RATE LOCK (F-10, owner decision Nov 23, 2026 — "Always stay to
-- old charity rate.. unless changed for a specific transaction.."):
-- the rate is locked at income time. This RPC reads
-- charity_settings.default_rate_bp ONCE, at accrual time, and
-- stores it as the row's rate_bp (rate_at_accrual). Changing the
-- household default rate affects NEW income only; existing
-- charity_income rows keep their recorded rate_bp, and NOTHING
-- restates them on a rate change — there is no trigger on
-- charity_settings, and the reclassify trigger's amount/date
-- re-derive (reclassify-income-accrual.sql v5) re-reads the
-- ORIGINAL rate from the existing accrual row, not the current
-- default. A per-transaction override is the only way to change
-- one row's rate: correct_charity_income (r13-charity.sql)
-- reverses the row and replaces it at the override rate.
-- Do NOT hand-record charity for the existing $3,500 check deposit
-- through this file: that deposit predates this accrual path and its
-- reclassification is a separate, still-open owner step.
--
-- WHY A NEW RPC: record_charity_income is admin-only — it raises
-- 'not authenticated' when auth.uid() is null, which is exactly the
-- case under the service role, so edge functions CANNOT call it.
-- record_charity_income is NOT modified (it stays the deliberate,
-- admin-only path). accrue_charity_for_transaction is the
-- service-role-only entry point, mirroring
-- supabase/07-service-rpc-access.sql: SECURITY DEFINER, an explicit
-- auth.role() = 'service_role' check, EXECUTE granted to service_role
-- only. It resolves the rate from charity_settings.default_rate_bp
-- (default 1000 = 10%), computes committed half-up in bigint
-- ((amount * rate + 5000) / 10000, the R13 formula), inserts one
-- charity_income row linked to the transaction, and returns the
-- EXISTING income_id when the row already accrued (idempotent via
-- the partial unique index below). Pre-November-2026 income is
-- refused, matching the R13 "charity starts November 2026" rule.
--
-- CSV accrual is OUT OF SCOPE for this build (no hook added): the
-- frozen web app's CSV import path is untouched. That is owed work,
-- not a silent gap.

alter table public.charity_income
  add column if not exists transaction_id uuid references public.transactions(id) on delete set null;

-- One ACTIVE accrual per transaction, per household. A reversed row
-- (append-only correction) frees the slot, so a corrected income can
-- accrue again. NULL transaction_id rows (hand-recorded incomes from
-- record_charity_income) never conflict with each other — Postgres
-- unique indexes treat NULLs as distinct.
create unique index if not exists charity_income_household_transaction_uidx
  on public.charity_income (household_id, transaction_id)
  where status = 'active';

create or replace function public.accrue_charity_for_transaction(p_transaction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tx transactions%rowtype;
  v_rate integer;
  v_amount integer;
  v_committed bigint;
  v_id uuid;
  v_existing jsonb;
begin
  if auth.role() <> 'service_role' then raise exception 'service role only'; end if;
  select * into v_tx from public.transactions where id = p_transaction_id;
  if not found then raise exception 'transaction not found'; end if;
  -- Guards: only a VERIFIED, non-excluded income row dated on/after
  -- 2026-11-01 accrues. Anything else returns accrued:false with a
  -- reason — the edge-function caller is best-effort and must never
  -- fail the sync on this.
  if v_tx.kind <> 'income' then
    return jsonb_build_object('accrued', false, 'reason', 'not_income');
  end if;
  if v_tx.state <> 'verified' then
    return jsonb_build_object('accrued', false, 'reason', 'not_verified');
  end if;
  if coalesce(v_tx.excluded, false) then
    return jsonb_build_object('accrued', false, 'reason', 'excluded');
  end if;
  if v_tx.date < date '2026-11-01' then
    return jsonb_build_object('accrued', false, 'reason', 'before_nov_2026');
  end if;
  -- Idempotency: an active accrual already linked to this row wins.
  select jsonb_build_object('income_id', id, 'rate_bp', rate_bp,
          'committed_cents', (amount_cents::bigint * rate_bp + 5000) / 10000,
          'accrued', false, 'replayed', true)
    into v_existing
    from public.charity_income
   where household_id = v_tx.household_id
     and transaction_id = p_transaction_id
     and status = 'active';
  if v_existing is not null then return v_existing; end if;
  select default_rate_bp into v_rate from public.charity_settings where household_id = v_tx.household_id;
  v_rate := coalesce(v_rate, 1000);
  -- Income rows store negative cents; the ledger stores positive.
  v_amount := abs(v_tx.amount_cents);
  if v_amount <= 0 then
    return jsonb_build_object('accrued', false, 'reason', 'zero_amount');
  end if;
  -- P2-B14: bigint product — the int4 product overflows above ~$21.5k
  -- of income at the 10% default rate (see r13-charity.sql header).
  v_committed := (v_amount::bigint * v_rate + 5000) / 10000;
  insert into public.charity_income
    (household_id, source_label, amount_cents, income_date, rate_bp, note, transaction_id, created_by)
  values (v_tx.household_id,
          coalesce(nullif(btrim(v_tx.merchant), ''), 'Income'),
          v_amount, v_tx.date, v_rate, 'Auto-accrued from synced income', p_transaction_id, null)
  on conflict (household_id, transaction_id) where status = 'active' do nothing
  returning id into v_id;
  if v_id is null then
    -- Lost a race with a concurrent accrual: return the row that won.
    select id into v_id from public.charity_income
     where household_id = v_tx.household_id
       and transaction_id = p_transaction_id
       and status = 'active';
    if v_id is null then raise exception 'charity accrual conflict without a stored row'; end if;
    return jsonb_build_object('income_id', v_id, 'rate_bp', v_rate, 'committed_cents', v_committed, 'accrued', false, 'replayed', true);
  end if;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_tx.household_id, null, 'auto-accrual', 'Charity income auto-accrued',
          'Income ' || v_tx.merchant || ' ' || v_amount::text || ' cents on ' || v_tx.date::text
          || ' at ' || v_rate::text || ' basis points commits ' || v_committed::text || ' cents to charity.');
  return jsonb_build_object('income_id', v_id, 'rate_bp', v_rate, 'committed_cents', v_committed, 'accrued', true, 'replayed', false);
end;
$$;

revoke execute on function public.accrue_charity_for_transaction(uuid) from public;
revoke execute on function public.accrue_charity_for_transaction(uuid) from authenticated;
revoke execute on function public.accrue_charity_for_transaction(uuid) from anon;
grant execute on function public.accrue_charity_for_transaction(uuid) to service_role;
