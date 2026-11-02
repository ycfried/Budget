-- 08-decline-fix.sql — coordinator integration migration (audit-fixes branch)
--
-- AUDIT P1-11 (closes it): the original decline_fund_request() in
-- live-admin-rpcs.sql ran a conditional UPDATE (status='pending') but
-- an UNCONDITIONAL audit INSERT, so declining an already-decided
-- request wrote a false "Extra Fund request declined" audit row.
-- This version checks FOUND after the UPDATE and raises
-- 'request already decided' when the request was not pending —
-- matching approve_and_allocate()'s strictness — so no audit row is
-- written for a decision that did not happen.
-- DEPLOY ORDER: after 07-service-rpc-access.sql. Grants unchanged
-- (authenticated only, never public).
create or replace function public.decline_fund_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  hid uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select household_id into hid from fund_requests where id = p_request_id;
  if hid is null then raise exception 'request not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = hid and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  update fund_requests set status = 'declined' where id = p_request_id and status = 'pending';
  if not found then raise exception 'request already decided'; end if;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (hid, auth.uid(), 'admin', 'Extra Fund request declined', 'Request ' || p_request_id::text || ' declined.');
end;
$$;
revoke execute on function public.decline_fund_request(uuid) from public;
grant execute on function public.decline_fund_request(uuid) to authenticated;
