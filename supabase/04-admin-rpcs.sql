-- =====================================================================
-- S1 migration 04 — Admin RPCs: safe approval, shortfall path,
-- server-side audit identity, allowance history, one approval path
-- DO NOT APPLY IN FULL (P1-B9, Nov 8, 2026): §1 approve_and_allocate
-- below has ambiguous parameter names (re-applying it makes every
-- Approve fail — see the §1 banner; canonical is
-- supabase/approve-ambiguity-fix.sql). Apply individual sections
-- only from their canonical files, never this file whole.
-- Deploy order: FOURTH of the five S1 files (01..05).
-- Depends on: schema.sql, fund-ledger.sql (fund_requests,
--   fund_ledger, transactions, households, audit_log exist;
--   fund_requests.status already allows 'split'; households already
--   has fund_shortfall_cents from fund-ledger.sql), 02 (the
--   fund-request trigger in 02 also guards transaction linkage).
--
-- What this fixes (audit):
--   P1-8  approve_and_allocate approved MORE than requested, lost
--         the split remainder, mislabelled splits, and OVERWROTE
--         fund_allocation_cents instead of accumulating it.
--   P0-5  (approve half) approve_and_allocate rewrote another
--         household's transaction with no household-equality check.
--   P1-9  (approval half) concurrent approvals could jointly
--         overdraw: balance read then insert with no lock. Fixed
--         here with SELECT ... FOR UPDATE on the households row
--         (the per-household lock), held for the whole RPC
--         transaction. No new household_locks table is created: the
--         households row already exists for every household, is
--         never deleted independently of the household, and a row
--         lock on it serializes all fund writers for that household
--         without a backfill. Week-close double-release (the other
--         P1-9 half) is NOT fixed here — week-close is an Edge
--         Function sequence, not an RPC, and needs its own atomic
--         rewrite; flagged in INTERFACE.md.
--   P0-15 (server half) week-close had NO households UPDATE path at
--         all (no grant/policy), so the shortfall write always
--         failed silently. update_fund_shortfall() is the
--         admin-checked SECURITY DEFINER path week-close must call
--         instead of a direct households UPDATE. (Week-close must
--         also start CHECKING its write errors — Edge Function work,
--         not SQL; flagged in INTERFACE.md.)
--   P1-12 (audit third) audit rows forgeable: the trigger in §4
--         overwrites actor/actor_name from the caller's JWT.
--   P0-14 (audit half) set_base_allowance logged only the new value;
--         it now logs old -> new. (The empty-input -> $0 client bug
--         is UI work, not SQL; the RPC still accepts >= 0 — see §6.)
--   P1-10 Old approve_fund_request approved without moving money.
--         It now delegates to approve_and_allocate for the FULL
--         requested amount, so exactly one approval path exists.
--
-- INTERFACE NOTE — argument names (read this before coding callers):
--   The S1 brief's interface contract names approve_and_allocate's
--   arguments (request_id, amount_cents, override_reason) WITHOUT
--   the p_ prefix used by the old live.js calls (p_request_id,
--   p_amount_cents, p_override_reason). This file follows the
--   CONTRACT names: existing live.js approve calls must be updated
--   by the UI workstream, or they will fail with an unknown-argument
--   error. The same contract naming is used for every NEW function
--   in this file and in 05 (update_fund_shortfall(household_id,
--   shortfall_cents), join_household_by_code(code) in 01).
--   Unchanged older RPCs (set_base_allowance, delete_transaction,
--   decline_fund_request) keep their p_ names so their existing
--   callers keep working.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Split remainder storage (P1-8)
-- ---------------------------------------------------------------------
alter table fund_requests
  add column if not exists remainder_cents integer not null default 0
    check (remainder_cents >= 0);

-- ---------------------------------------------------------------------
-- 1. approve_and_allocate — full replacement
--    DO NOT RE-APPLY THIS SECTION (P1-B1, Nov 8, 2026). Its
--    parameters are named request_id / amount_cents / override_reason
--    and amount_cents COLLIDES with the amount_cents column of
--    fund_requests / fund_ledger — applying this version makes every
--    Approve fail with Postgres "column reference amount_cents is
--    ambiguous" (audit A finding 1, Nov 3). The body is otherwise
--    the correct strong version; the CANONICAL definition is
--    supabase/approve-ambiguity-fix.sql (same body, p_-prefixed
--    parameters). Apply that file instead.
--    approve_and_allocate(request_id uuid, amount_cents int,
--                         override_reason text) returns void
--    Rules, in order:
--      * caller authenticated; request exists; caller is admin of
--        the request's household (checked AFTER the household row
--        lock, so the admin check sees a stable row);
--      * request must be 'pending' (unchanged from the old RPC);
--      * amount must be > 0 (unchanged) AND <= requested (NEW —
--        P1-8 over-approval is now an exception, not a "split");
--      * linked transaction, when present, must belong to the SAME
--        household (NEW — P0-5), and its fund_allocation_cents is
--        INCREMENTED by amount, never overwritten (NEW — P1-8:
--        two requests against one purchase no longer clobber each
--        other in week math while the ledger is charged twice);
--      * fund-balance / override rule unchanged: amount > available
--        requires a non-blank override reason, logged as kind
--        'override_allocation';
--      * status = 'approved' when amount = requested, else 'split',
--        with remainder_cents = requested - amount stored on the
--        row (NEW — P1-8). NOTE on the remainder (flagged, not
--        hidden): a 'split' row is CLOSED — it is no longer
--        'pending', so the remainder cannot be approved later
--        without a brand-new request. The brief specifies
--        status='split' + remainder_cents, and this file follows
--        it; the audit's alternative ("carry the remainder as
--        still-pending") is NOT implemented. If the parent wants
--        re-approvable remainders, that is a follow-up design
--        decision, not something to smuggle in here.
--      * decided_by / decided_at are now recorded (the old RPC left
--        them NULL even on approval).
-- ---------------------------------------------------------------------
--    NOTE (deploy fix, Nov 2): the live function still uses the old
--    p_-prefixed parameter names, and Postgres forbids renaming
--    parameters via CREATE OR REPLACE (error 42P13). The DROP below
--    MUST run before the CREATE, or the file fails here. Safe: no
--    view/trigger depends on this function (the old
--    approve_fund_request references it only inside a PL/pgSQL body,
--    which Postgres does not track), and §7 below replaces
--    approve_fund_request anyway, calling the new function
--    positionally. Re-running this file after a partial failure is
--    safe: §0 is IF NOT EXISTS and the DROP is IF EXISTS.
drop function if exists public.approve_and_allocate(uuid, integer, text);
create or replace function public.approve_and_allocate(request_id uuid, amount_cents integer, override_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req fund_requests%rowtype;
  v_available integer;
  v_txn_household uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if amount_cents is null or amount_cents <= 0 then raise exception 'amount must be positive'; end if;

  select * into v_req from fund_requests where id = request_id;
  if not found then raise exception 'request not found'; end if;

  -- Per-household serialization (P1-9): lock the households row for
  -- the whole RPC transaction. A second concurrent approval (or
  -- allocate_fund call, §2) for the SAME household blocks here until
  -- the first commits, so both can never read the same stale
  -- available balance. Different households do not contend.
  perform 1 from households where id = v_req.household_id for update;
  if not found then raise exception 'household not found'; end if;

  -- Re-read the request under lock: a concurrent approval that was
  -- already in flight is now either committed (status no longer
  -- pending -> exception below) or still blocked behind us.
  select * into v_req from fund_requests where id = request_id for update;
  if not found then raise exception 'request not found'; end if;

  if v_req.status <> 'pending' then raise exception 'request is not pending'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_req.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- P1-8: never approve more than was requested.
  if amount_cents > v_req.amount_cents then
    raise exception 'amount exceeds requested amount';
  end if;

  -- P0-5: the linked transaction must live in the request's household.
  if v_req.transaction_id is not null then
    select household_id into v_txn_household from transactions where id = v_req.transaction_id;
    if not found then raise exception 'linked transaction not found'; end if;
    if v_txn_household <> v_req.household_id then
      raise exception 'fund request transaction belongs to a different household';
    end if;
  end if;

  select coalesce(sum(amount_cents), 0) into v_available
    from fund_ledger where household_id = v_req.household_id;
  if amount_cents > v_available and (override_reason is null or btrim(override_reason) = '') then
    raise exception 'insufficient fund: available % cents', v_available;
  end if;

  insert into fund_ledger (household_id, kind, amount_cents, week_start, request_id, note, created_by)
    values (v_req.household_id,
            case when amount_cents > v_available then 'override_allocation' else 'allocation' end,
            -amount_cents, null, request_id,
            case when amount_cents > v_available then 'Override: ' || override_reason else coalesce(v_req.note, '') end,
            auth.uid());

  update fund_requests
    set status = case when amount_cents = v_req.amount_cents then 'approved' else 'split' end,
        decided_by = auth.uid(),
        decided_at = now(),
        remainder_cents = v_req.amount_cents - amount_cents
    where id = request_id;

  if v_req.transaction_id is not null then
    -- ACCUMULATE, do not overwrite (P1-8). The household guard in
    -- the WHERE clause is redundant after the check above, but it
    -- makes the write itself incapable of touching another
    -- household's row even if the check is ever refactored away.
    update transactions
      set fund_allocation_cents = fund_allocation_cents + amount_cents
      where id = v_req.transaction_id and household_id = v_req.household_id;
    if not found then raise exception 'linked transaction not found'; end if;
  end if;

  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_req.household_id, auth.uid(), 'admin', 'Extra Fund request approved',
            'Request ' || request_id::text || ' approved for ' || amount_cents::text || ' cents'
            || case when amount_cents < v_req.amount_cents
                    then ' (split; remainder ' || (v_req.amount_cents - amount_cents)::text || ' cents)'
                    else '' end
            || case when amount_cents > v_available then ' (override: ' || override_reason || ')' else '' end || '.');
end;
$$;
revoke execute on function public.approve_and_allocate(uuid, integer, text) from public;
grant execute on function public.approve_and_allocate(uuid, integer, text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. allocate_fund — same replacement, household lock only
--    (P1-9 also covered the direct-spend RPC; its signature and
--    balance/override behaviour are unchanged.)
-- ---------------------------------------------------------------------
create or replace function public.allocate_fund(p_household_id uuid, p_amount_cents integer, p_note text, p_override_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_available integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Same per-household lock as approve_and_allocate (§1).
  perform 1 from households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  select coalesce(sum(amount_cents), 0) into v_available
    from fund_ledger where household_id = p_household_id;
  if p_amount_cents > v_available and (p_override_reason is null or btrim(p_override_reason) = '') then
    raise exception 'insufficient fund: available % cents', v_available;
  end if;
  insert into fund_ledger (household_id, kind, amount_cents, week_start, request_id, note, created_by)
    values (p_household_id,
            case when p_amount_cents > v_available then 'override_allocation' else 'allocation' end,
            -p_amount_cents, null, null,
            case when p_amount_cents > v_available then 'Override: ' || p_override_reason || ' — ' || coalesce(p_note, '')
                 else coalesce(p_note, '') end,
            auth.uid());
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Extra Fund spending recorded',
            'Fund spending ' || p_amount_cents::text || ' cents'
            || case when p_amount_cents > v_available then ' (override: ' || p_override_reason || ')' else '' end || '.');
end;
$$;
revoke execute on function public.allocate_fund(uuid, integer, text, text) from public;
grant execute on function public.allocate_fund(uuid, integer, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. update_fund_shortfall — the missing households UPDATE path
--    (P0-15). update_fund_shortfall(household_id uuid,
--    shortfall_cents int) returns void.
--    Admin-only, SECURITY DEFINER. Week-close must call this RPC
--    instead of issuing a direct households UPDATE (which has no
--    grant/policy and always failed). Shortfall is a non-negative
--    remainder per spec A4 ("reduce the fund ... but never below
--    zero. Any remainder is recorded as a reconciliation
--    shortfall"); a negative value is rejected rather than stored.
--    The audit row records old -> new so a lost shortfall can never
--    again vanish silently.
-- ---------------------------------------------------------------------
create or replace function public.update_fund_shortfall(household_id uuid, shortfall_cents integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if shortfall_cents is null or shortfall_cents < 0 then raise exception 'shortfall must be non-negative'; end if;
  if not exists (select 1 from household_members
                 where household_id = household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  select fund_shortfall_cents into v_old from households where id = household_id for update;
  if not found then raise exception 'household not found'; end if;
  update households set fund_shortfall_cents = shortfall_cents where id = household_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (household_id, auth.uid(), 'admin', 'Fund shortfall updated',
            'Fund shortfall changed from ' || v_old::text || ' cents to ' || shortfall_cents::text || ' cents.');
end;
$$;
revoke execute on function public.update_fund_shortfall(uuid, integer) from public;
grant execute on function public.update_fund_shortfall(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Server-side audit identity (P1-12 audit third)
--    BEFORE INSERT trigger on audit_log. For a caller WITH a JWT
--    (every member/admin client call, and every SECURITY DEFINER
--    RPC invoked by such a caller — auth.uid() still reflects the
--    caller's JWT inside a SECURITY DEFINER function), the trigger
--    OVERWRITES whatever actor/actor_name the caller supplied:
--      actor      := auth.uid()
--      actor_name := the caller's household_members.display_name,
--                    else the JWT user_metadata full_name / name,
--                    else the JWT email claim,
--                    else auth.uid() as text (documented fallback:
--                    display names are usually empty in this app —
--                    live.js never sets display_name — so in
--                    practice actor_name will often be the uid or
--                    the account email until a display-name source
--                    is populated. That is still attributable and
--                    unforgeable, which is the security property;
--                    the pretty name is cosmetic.)
--    For a caller WITHOUT a JWT (service-role Edge Function path,
--    e.g. bootstrap-household's admin client): auth.uid() is NULL
--    and overwriting would DESTROY attribution, so the trigger
--    keeps the supplied actor/actor_name, defaulting a blank
--    actor_name to the actor id as text. Service-role calls bypass
--    RLS and this trigger's identity rule by design — nothing in
--    SQL can authenticate a service-role caller beyond the key
--    itself, and that key must never reach a client.
--    Consequence to expect: existing RPCs pass actor_name='admin'
--    (or 'member'); after this trigger those rows will show the
--    real caller name/uid instead. That is intended — 'admin' was
--    never a person — but any UI or report that filters on
--    actor_name = 'admin' will stop matching and must be updated.
-- ---------------------------------------------------------------------
create or replace function public.force_audit_actor()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_name text;
begin
  if auth.uid() is not null then
    NEW.actor := auth.uid();
    select display_name into v_name
      from household_members
      where household_id = NEW.household_id and user_id = auth.uid();
    if v_name is null or btrim(v_name) = '' then
      v_name := coalesce(
        auth.jwt() -> 'user_metadata' ->> 'full_name',
        auth.jwt() -> 'user_metadata' ->> 'name',
        auth.jwt() ->> 'email'
      );
    end if;
    if v_name is null or btrim(v_name) = '' then
      v_name := auth.uid()::text;
    end if;
    NEW.actor_name := v_name;
  else
    -- No JWT (service-role / system path): preserve supplied values.
    if NEW.actor_name is null or btrim(NEW.actor_name) = '' then
      NEW.actor_name := coalesce(NEW.actor::text, 'system');
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_audit_log_force_actor on audit_log;
create trigger trg_audit_log_force_actor
  before insert on audit_log
  for each row execute function public.force_audit_actor();

-- ---------------------------------------------------------------------
-- 5. delete_transaction — VERIFIED, NOT weakened (re-created
--    byte-for-byte in behaviour from delete-transaction-rpc.sql):
--    admin only, source='manual' only, audit row written BEFORE the
--    delete. Re-created here so 04 is self-contained and the
--    guarantee is re-asserted rather than assumed from an older file.
-- ---------------------------------------------------------------------
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
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select household_id, source, merchant, amount_cents
    into hid, src, merch, amt from transactions where id = p_transaction_id;
  if hid is null then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = hid and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
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

-- ---------------------------------------------------------------------
-- 6. set_base_allowance — replacement: audit records OLD and NEW
--    (P0-14 audit half). Signature and >= 0 validation unchanged
--    so existing callers keep working. The empty-input -> $0 client
--    bug is NOT fixed here: the RPC cannot distinguish "admin meant
--    $0" from "admin cleared the field"; the UI must reject empty /
--    non-numeric input and confirm before calling (UI workstream).
-- ---------------------------------------------------------------------
create or replace function public.set_base_allowance(p_household_id uuid, p_cents integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_cents is null or p_cents < 0 then raise exception 'allowance must be non-negative'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  select base_allowance_cents into v_old from households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  update households set base_allowance_cents = p_cents where id = p_household_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Base allowance changed',
            'Base allowance changed from ' || v_old::text || ' cents to ' || p_cents::text || ' cents.');
end;
$$;
revoke execute on function public.set_base_allowance(uuid, integer) from public;
grant execute on function public.set_base_allowance(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 7. approve_fund_request — replacement: delegate to the ONE
--    approval path (P1-10). The old body (approve with no money
--    movement) is GONE. This function now loads the full requested
--    amount and calls approve_and_allocate() with it, so every
--    approval moves money, checks the fund balance, accumulates the
--    allocation, and is serialized — exactly like the new path.
--    BEHAVIOUR CHANGE to expect: an old-path approval now FAILS
--    with 'insufficient fund' when the fund cannot cover the full
--    amount (no override reason is supplied on this path), where
--    the old RPC would have approved anyway. That failure is the
--    fix, not a regression: a money-less approval must not exist.
--    decline_fund_request is NOT touched here (P1-11 false-audit
--    on already-decided rows remains open — flagged in
--    INTERFACE.md; it was outside this file's brief).
-- ---------------------------------------------------------------------
create or replace function public.approve_fund_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select amount_cents into v_amount from fund_requests where id = p_request_id;
  if not found then raise exception 'request not found'; end if;
  perform public.approve_and_allocate(p_request_id, v_amount, null);
  -- NOTE: approve_and_allocate's contract argument names are
  -- (request_id, amount_cents, override_reason); positional call
  -- above is used deliberately so this delegation does not depend
  -- on argument names at all.
end;
$$;
revoke execute on function public.approve_fund_request(uuid) from public;
grant execute on function public.approve_fund_request(uuid) to authenticated;

-- =====================================================================
-- VERIFICATION (commented — run manually after deploy, on test data):
--   -- Column + functions exist:
--   select column_name from information_schema.columns where
--     table_name = 'fund_requests' and column_name = 'remainder_cents';
--     -- one row
--   -- Over-approval rejected (as admin, pending request of $25):
--   select approve_and_allocate('<req>', 100000, null);
--     -- expect: 'amount exceeds requested amount'
--   -- Split stores remainder (approve $10 of $25):
--   select approve_and_allocate('<req>', 1000, null);
--   select status, remainder_cents from fund_requests where id='<req>';
--     -- 'split', 1500
--   -- Accumulation (two requests, same transaction, $10 + $5):
--   select fund_allocation_cents from transactions where id='<txn>';
--     -- 1500, not 500
--   -- Cross-household link rejected: request in household A linked
--   -- to a transaction in household B (admin of A approving):
--   select approve_and_allocate('<req-A>', 1000, null);
--     -- expect: 'belongs to a different household'
--   -- Shortfall path (as admin):
--   select update_fund_shortfall('<household>', 3500);
--   select fund_shortfall_cents from households where id='<household>';
--     -- 3500; as a non-admin the same call raises 'admin only';
--     -- negative shortfall raises 'shortfall must be non-negative'.
--   -- Audit identity forcing (as a member, direct insert):
--   insert into audit_log (household_id, actor, actor_name, action)
--     values ('<own-household>', '00000000-0000-0000-0000-000000000000',
--             'admin', 'Forged action test');
--   select actor, actor_name from audit_log where action =
--     'Forged action test' order by created_at desc limit 1;
--     -- actor = caller's real uid, actor_name != 'admin' (uid/email/
--     -- display name) — the forged values must NOT survive.
--   -- Old approval path now moves money (full-amount delegation):
--   select approve_fund_request('<pending-req>');
--   select status from fund_requests where id='<pending-req>';
--     -- 'approved', and fund_ledger gained a matching allocation row.
-- =====================================================================
