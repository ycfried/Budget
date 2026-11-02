-- =====================================================================
-- S1 migration 02 — RLS hardening: close direct-write holes
-- Deploy order: SECOND of the five S1 files (01..05).
-- Depends on: schema.sql, schema-inserts.sql, fund-ledger.sql,
--   fix-transactions-upsert.sql, webhook-events.sql,
--   webhook-events-v2.sql (the policies/grants dropped below live
--   in those files; every DROP is IF EXISTS so re-runs are safe).
--
-- What this fixes (audit):
--   P0-2  Member mints fund money / forges week closes by direct
--         INSERT/UPDATE on week_closes, surplus_releases, fund_ledger.
--   P0-3  Member edits/excludes/fabricates transactions by direct
--         UPDATE; member inserts fake rows (source='plaid',
--         state='verified', negative refunds) by direct INSERT.
--   P0-5  (insert half) Fund request linked to another household's
--         transaction. (The approve half is fixed in 04.)
--   P1-12 (two thirds) Fund requests arriving pre-approved; any
--         member suppressing auto-sync via webhook_events UPDATE.
--         (The audit-forgery third is fixed by the trigger in 04;
--         see the audit_log note in §5.)
--   P1-13 (anon half) log_webhook_event granted to anon. The
--         authenticated grant is deliberately left in place here
--         and flagged — see §6.
--
-- IMPORTANT DEPLOY DEPENDENCY — read before deploying:
--   Plaid sync currently upserts transactions with the CALLER's JWT
--   (supabase/functions/plaid-sync/index.ts, source='plaid',
--   state='provisional'/'verified'). After §3 below, that upsert
--   FAILS: member INSERT is constrained to source IN ('manual','csv')
--   AND state='provisional', and member UPDATE is revoked. That is
--   the intended P0-3 fix (audit: "Plaid-sync's own upsert then needs
--   a privileged path, not the member's JWT"), but the privileged
--   path does NOT exist yet in this workstream's scope. Do NOT
--   deploy §3 until plaid-sync has been moved to a service-role /
--   SECURITY DEFINER upsert path, or Plaid sync will break on the
--   next run. The same applies to any CSV import that writes with a
--   member JWT using source/state outside ('manual'|'csv',
--   'provisional') — verify the CSV path before deploy.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Fund books: revoke direct member writes, drop member policies
--    (P0-2). After this, week_closes / surplus_releases / fund_ledger
--    are writable only by the table owner, SECURITY DEFINER RPCs,
--    and service-role Edge Functions — never by a member's JWT.
--    SELECT grants/policies are untouched: members still READ their
--    own household's fund books (spec A1: member sees everything).
-- ---------------------------------------------------------------------
revoke insert, update on week_closes from authenticated;
revoke insert, update on surplus_releases from authenticated;
revoke insert, update on fund_ledger from authenticated;

drop policy if exists "members write own week closes" on week_closes;
drop policy if exists "members update own week closes" on week_closes;
drop policy if exists "members write own surplus releases" on surplus_releases;
drop policy if exists "members update own surplus releases" on surplus_releases;
drop policy if exists "members write own fund ledger" on fund_ledger;
-- No update policy for fund_ledger ever existed in the repo (only a
-- table UPDATE grant, revoked above), but drop it if one appears:
drop policy if exists "members update own fund ledger" on fund_ledger;

-- ---------------------------------------------------------------------
-- 2. Transactions: revoke direct member UPDATE, drop its policy
--    (P0-3). Exclusion / restore / reclassification move to the
--    admin-checked RPCs in 05-transaction-mutation-rpcs.sql, which
--    run SECURITY DEFINER and are unaffected by this revoke.
--    NOTE: this also removes the upsert path plaid-sync relied on —
--    see the deploy dependency at the top of this file.
-- ---------------------------------------------------------------------
revoke update on transactions from authenticated;

drop policy if exists "members update own transactions" on transactions;

-- ---------------------------------------------------------------------
-- 3. Transactions: constrain member INSERT to hand-entered / CSV
--    provisional rows only (P0-3).
--    A table-level CHECK is deliberately NOT used: a CHECK would
--    also bind the future privileged sync path (service role
--    bypasses RLS but NOT CHECKs). A WITH CHECK policy binds only
--    member-JWT writes, which is exactly the hole being closed.
--    The live manual form inserts source='manual',
--    state='provisional' (live.js manualForm) and is unaffected.
-- ---------------------------------------------------------------------
drop policy if exists "members insert own transactions" on transactions;

create policy "members insert own transactions"
  on transactions for insert
  with check (
    household_id in (select household_id from household_members
                     where user_id = auth.uid())
    and source in ('manual', 'csv')
    and state = 'provisional'
  );

-- ---------------------------------------------------------------------
-- 4. Fund requests: INSERT must be pending, own-household, and
--    transaction-linked only within the same household (P0-5 insert
--    half, P1-12 pre-approval).
--    Two layers, both kept:
--      (a) the policy below (member-JWT writes), and
--      (b) the trigger in §4b (fires for EVERY writer, including
--          SECURITY DEFINER RPCs and service-role-adjacent paths
--          that bypass RLS — belt and braces for P0-5).
-- ---------------------------------------------------------------------
drop policy if exists "members insert own fund requests" on fund_requests;

create policy "members insert own fund requests"
  on fund_requests for insert
  with check (
    household_id in (select household_id from household_members
                     where user_id = auth.uid())
    and requested_by = auth.uid()
    and status = 'pending'
    -- transaction_id, when present, must belong to this household.
    -- (The subquery is itself subject to the transactions SELECT
    -- policy, so a cross-household id is invisible here and the
    -- EXISTS fails closed — exactly what P0-5 needs.)
    and (transaction_id is null
         or exists (select 1 from transactions t
                    where t.id = transaction_id
                      and t.household_id = fund_requests.household_id))
  );

-- 4b. Trigger: same two rules, enforced regardless of RLS bypass.
--     Status is enforced on INSERT only: admin RPCs legitimately
--     move status pending -> approved/split/declined (04), and those
--     updates must not trip the trigger.
--     Transaction-household equality is enforced on INSERT and
--     whenever transaction_id itself changes; it is NOT re-checked
--     on status-only updates, so a pre-existing (pre-fix) mismatched
--     row can still be declined/closed but can never gain a NEW
--     mismatched link. approve_and_allocate() in 04 additionally
--     refuses to allocate against a mismatched link.
create or replace function public.validate_fund_request_txn()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' and NEW.status <> 'pending' then
    raise exception 'fund requests must be created as pending';
  end if;
  -- Transaction-household equality: always on INSERT; on UPDATE
  -- only when transaction_id itself changes (OLD is not referenced
  -- on INSERT at all — it is NULL there — so the two cases are kept
  -- in separate branches on purpose).
  if TG_OP = 'INSERT' then
    if NEW.transaction_id is not null and not exists (
      select 1 from transactions t
       where t.id = NEW.transaction_id
         and t.household_id = NEW.household_id
    ) then
      raise exception 'fund request transaction belongs to a different household';
    end if;
  elsif NEW.transaction_id is distinct from OLD.transaction_id then
    if NEW.transaction_id is not null and not exists (
      select 1 from transactions t
       where t.id = NEW.transaction_id
         and t.household_id = NEW.household_id
    ) then
      raise exception 'fund request transaction belongs to a different household';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_fund_request_validate on fund_requests;
create trigger trg_fund_request_validate
  before insert or update on fund_requests
  for each row execute function public.validate_fund_request_txn();

-- ---------------------------------------------------------------------
-- 5. Audit log: direct INSERT is KEPT (membership-scoped), but
--    forgery is closed by the trigger in 04-admin-rpcs.sql, which
--    overwrites actor/actor_name from the caller's JWT on every
--    insert. That ordering matters: this file intentionally does NOT
--    revoke audit_log INSERT, because two live writers depend on it
--    with the caller's JWT — week-close's audit inserts and the
--    live.js audit() helper. Removing direct INSERT entirely is the
--    audit's stricter fix (P1-12) and remains owed work: it requires
--    week-close + live.js to write audit rows through an RPC first.
--    RESIDUAL RISK (flagged, not hidden): until that RPC exists, a
--    member can still insert an audit row with arbitrary action /
--    detail TEXT, but it is now attributable to them — they cannot
--    forge actor/actor_name (04 trigger) and cannot backdate or
--    rewrite existing rows (no UPDATE/DELETE policy or grant).
--    No policy change is needed here; this section documents why.
-- ---------------------------------------------------------------------
-- (No statement: audit_log INSERT policy "members insert own audit
-- rows" is left in place on purpose. The enforcement is the 04
-- trigger trg_audit_log_force_actor.)

-- ---------------------------------------------------------------------
-- 6. Webhook events: revoke member UPDATE, drop its policy (P1-12:
--    a member could set processed=true and suppress auto-sync).
--    After this, webhook_events rows are updated only by the owner /
--    service-role sync path. SELECT policy/grant are untouched.
--    And revoke the anon grant on log_webhook_event (P1-13): the
--    RPC must no longer be callable without authentication.
--    RESIDUAL (flagged): the authenticated grant on
--    log_webhook_event is left in place by this migration because
--    the brief scopes this step to the anon revoke. Any authenticated
--    user can therefore still plant a webhook event row (dedupe hash
--    permitting). The parent should revoke the authenticated grant
--    too once plaid-webhook writes events through its own verified
--    service-role path, and should fix the dedupe-hash collision
--    noted in P1-13 (same item|code|count collides for distinct
--    events) — neither is done here.
-- ---------------------------------------------------------------------
revoke update on webhook_events from authenticated;

drop policy if exists "members update own webhook events" on webhook_events;

revoke execute on function public.log_webhook_event(text, text, text) from anon;

-- =====================================================================
-- VERIFICATION (commented — run manually after deploy):
--   -- Policies/grants gone:
--   select policyname from pg_policies where tablename in
--     ('week_closes','surplus_releases','fund_ledger','transactions',
--      'webhook_events') order by tablename, policyname;
--     -- must NOT list: "members write own week closes",
--     -- "members update own week closes", "members write own surplus
--     -- releases", "members update own surplus releases",
--     -- "members write own fund ledger", "members update own
--     -- transactions", "members update own webhook events".
--   select has_table_privilege('authenticated',
--     'week_closes', 'INSERT');  -- false; same for UPDATE, and for
--     -- surplus_releases, fund_ledger; transactions UPDATE false;
--     -- webhook_events UPDATE false.
--   -- Member INSERT still works for manual/provisional, fails else:
--   -- (as a household member) insert source='manual',
--   -- state='provisional' -> succeeds; source='plaid' or
--   -- state='verified' -> "new row violates row-level security".
--   -- Pre-approved fund request fails:
--   insert into fund_requests (household_id, requested_by,
--     amount_cents, status) values ('<own-household>', auth.uid(),
--     1000, 'approved');  -- expect: violates policy OR trigger
--   -- Cross-household linked request fails:
--   insert into fund_requests (household_id, requested_by,
--     amount_cents, status, transaction_id) values ('<own-household>',
--     auth.uid(), 1000, 'pending', '<other-household-txn>');
--     -- expect: exception 'belongs to a different household'
--   -- Anon webhook RPC fails:
--   select has_function_privilege('anon',
--     'log_webhook_event(text,text,text)', 'EXECUTE');  -- false
-- =====================================================================
