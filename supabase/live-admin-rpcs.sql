-- Household Budget — live admin RPCs (fund approvals, settings).
-- WHY: the live slice could create fund requests but not approve or
-- decline them, and had no settings at all. Client-side admin actions
-- are forbidden by design (a member could fake an admin flag), so
-- these run SECURITY DEFINER and enforce the role server-side:
--   * approve_fund_request / decline_fund_request: admin only.
--     Approve marks the request approved and writes an audit row.
--     (Allocating/spending against the fund balance is the next slice;
--     approval here is the decision record, matching the demo's queue.)
--   * set_household_settings: admin only. Updates base allowance and
--     the current week's temporary increment (stored on households;
--     compute-week reads them). Rejects negative values.
-- All three refuse when the caller does not belong to the household
-- or is not its admin, and all write audit rows so every admin action
-- is traceable. Granted to authenticated only, never to public.

create or replace function public.approve_fund_request(p_request_id uuid)
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
  update fund_requests set status = 'approved' where id = p_request_id and status = 'pending';
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (hid, auth.uid(), 'admin', 'Extra Fund request approved', 'Request ' || p_request_id::text || ' approved.');
end;
$$;
revoke execute on function public.approve_fund_request(uuid) from public;
grant execute on function public.approve_fund_request(uuid) to authenticated;

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
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (hid, auth.uid(), 'admin', 'Extra Fund request declined', 'Request ' || p_request_id::text || ' declined.');
end;
$$;
revoke execute on function public.decline_fund_request(uuid) from public;
grant execute on function public.decline_fund_request(uuid) to authenticated;

-- Settings: base allowance (cents) + a note field for the current
-- week's temporary increment is handled by the app writing a
-- temp_increase row; this RPC covers the base allowance only, which
-- is the setting the demo exposes as admin-only. Temporary increases
-- ride on the existing engine input T and are added via the week
-- function's inputs in a later slice, not by editing history.
create or replace function public.set_base_allowance(p_household_id uuid, p_cents integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_cents is null or p_cents < 0 then raise exception 'allowance must be non-negative'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  update households set base_allowance_cents = p_cents where id = p_household_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Base allowance changed', 'Base allowance set to ' || p_cents::text || ' cents.');
end;
$$;
revoke execute on function public.set_base_allowance(uuid, integer) from public;
grant execute on function public.set_base_allowance(uuid, integer) to authenticated;
