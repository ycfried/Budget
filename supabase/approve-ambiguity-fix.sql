-- approve-ambiguity-fix.sql — Audit-merge fix, Nov 3, 2026 (NOT APPLIED BY THE BUILDER)
-- Audit A finding 1: Extra Fund Approve always failed with Postgres
-- "column reference amount_cents is ambiguous". Root cause: the live
-- approve_and_allocate parameters were named request_id / amount_cents /
-- override_reason, and amount_cents collides with the amount_cents
-- column of fund_requests / fund_ledger inside the function's UPDATE
-- and INSERT statements, so Postgres cannot tell parameter from column.
-- Fix: drop and recreate the function with p_-prefixed parameters.
-- This file is an EXACT copy of supabase/04-admin-rpcs.sql §1 except
-- for the parameter renames (request_id -> p_request_id,
-- amount_cents -> p_amount_cents, override_reason -> p_override_reason)
-- applied consistently to the signature and every bare parameter use
-- in the body. Column references are UNCHANGED: v_req.amount_cents,
-- sum(amount_cents) over fund_ledger, and the INSERT column list
-- (amount_cents, request_id) all keep their column names — only the
-- VALUES side of those statements uses the p_ parameters.
-- Types are unchanged (uuid, integer, text), so the DROP matches the
-- old signature and the live.js RPC call must use the new names:
--   supabase.rpc('approve_and_allocate',
--     { p_request_id, p_amount_cents, p_override_reason })
-- approve_fund_request (§7 of 04-admin-rpcs.sql) calls this function
-- positionally, so it is unaffected by the rename.
-- DO NOT APPLY from this branch automatically: the parent applies it
-- in the Supabase dashboard after the code ships, then retests Approve
-- (full, split, member request, override) on a synthetic household.
drop function if exists public.approve_and_allocate(uuid, integer, text);
create or replace function public.approve_and_allocate(p_request_id uuid, p_amount_cents integer, p_override_reason text)
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
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;

  select * into v_req from fund_requests where id = p_request_id;
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
  select * into v_req from fund_requests where id = p_request_id for update;
  if not found then raise exception 'request not found'; end if;

  if v_req.status <> 'pending' then raise exception 'request is not pending'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_req.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- P1-8: never approve more than was requested.
  if p_amount_cents > v_req.amount_cents then
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
  if p_amount_cents > v_available and (p_override_reason is null or btrim(p_override_reason) = '') then
    raise exception 'insufficient fund: available % cents', v_available;
  end if;

  insert into fund_ledger (household_id, kind, amount_cents, week_start, request_id, note, created_by)
    values (v_req.household_id,
            case when p_amount_cents > v_available then 'override_allocation' else 'allocation' end,
            -p_amount_cents, null, p_request_id,
            case when p_amount_cents > v_available then 'Override: ' || p_override_reason else coalesce(v_req.note, '') end,
            auth.uid());

  update fund_requests
    set status = case when p_amount_cents = v_req.amount_cents then 'approved' else 'split' end,
        decided_by = auth.uid(),
        decided_at = now(),
        remainder_cents = v_req.amount_cents - p_amount_cents
    where id = p_request_id;

  if v_req.transaction_id is not null then
    -- ACCUMULATE, do not overwrite (P1-8). The household guard in
    -- the WHERE clause is redundant after the check above, but it
    -- makes the write itself incapable of touching another
    -- household's row even if the check is ever refactored away.
    update transactions
      set fund_allocation_cents = fund_allocation_cents + p_amount_cents
      where id = v_req.transaction_id and household_id = v_req.household_id;
    if not found then raise exception 'linked transaction not found'; end if;
  end if;

  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_req.household_id, auth.uid(), 'admin', 'Extra Fund request approved',
            'Request ' || p_request_id::text || ' approved for ' || p_amount_cents::text || ' cents'
            || case when p_amount_cents < v_req.amount_cents
                    then ' (split; remainder ' || (v_req.amount_cents - p_amount_cents)::text || ' cents)'
                    else '' end
            || case when p_amount_cents > v_available then ' (override: ' || p_override_reason || ')' else '' end || '.');
end;
$$;
revoke execute on function public.approve_and_allocate(uuid, integer, text) from public;
grant execute on function public.approve_and_allocate(uuid, integer, text) to authenticated;
