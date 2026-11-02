-- Reaudit N2 + N3 (Nov 2, 2026). Apply in the Supabase SQL Editor, then
-- report the verification rows. Idempotent: revokes of absent grants are
-- harmless notices, and CREATE OR REPLACE keeps the function identity.
--
-- N2: get_plaid_ciphertext becomes service_role ONLY. The old membership
-- branch was unreachable (EXECUTE revoked) but a future re-grant would
-- have silently reopened P0-4 (member-readable Plaid ciphertext). All
-- live callers (plaid-sync, plaid-webhook-register, plaid-disconnect)
-- use the service-role key, so no legitimate caller is affected.
create or replace function public.get_plaid_ciphertext(p_household_id uuid, p_item_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  ct text;
begin
  if auth.role() <> 'service_role' then raise exception 'service role only'; end if;
  select access_token_encrypted into ct from plaid_items
    where household_id = p_household_id and plaid_item_id = p_item_id;
  return ct;
end;
$$;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from public;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from authenticated;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from anon;
grant execute on function public.get_plaid_ciphertext(uuid, text) to service_role;

-- N3: log_webhook_event must be service_role only. The Plaid webhook
-- function records events via the service path; the authenticated (and
-- anon) grants are leftovers from earlier migrations.
revoke execute on function public.log_webhook_event(text, text, text) from authenticated;
revoke execute on function public.log_webhook_event(text, text, text) from anon;
grant execute on function public.log_webhook_event(text, text, text) to service_role;

-- Verification: report every row returned here.
select grantee, privilege_type
from information_schema.routine_privileges
where routine_schema = 'public'
  and routine_name in ('get_plaid_ciphertext', 'log_webhook_event')
order by routine_name, grantee;
