-- fund-hidden.sql — Hide a fund from Home (build 47, owner Nov 19, 2026).
--
-- The owner: "The only ones that stay and are built in are
-- spending & Charity." Spending and Tzedaka ALWAYS stay on Home;
-- ONLY Savings and Overspent (Past) can be removed from Home and
-- added back. A hidden fund still exists on the Funds page (with
-- its data) and is re-added from its edit sheet there.
--
-- Storage mirrors fund-prominence.sql (build 46) exactly: one
-- `fund_hidden` JSONB column on `households`, a map from fund key
-- to true, e.g. {"fund": true}. Only hidden funds are stored; a
-- missing key means shown. Hiding NEVER overwrites the fund's
-- prominence — the prominence stays stored, so re-adding puts the
-- fund back at its prominence (hero / card / quiet row) without
-- re-picking it.
--
-- Apply via the Supabase dashboard SQL editor (project "Budget").
-- The native app degrades gracefully if this is not applied yet:
-- the hidden read returns empty (every fund shows) and a hide
-- change fails with a plain-language error. Apply BEFORE the
-- build-47 TestFlight build goes out, as with the build-46
-- fund-prominence.sql.
--
-- DO NOT apply from here — the parent applies it via the dashboard.

alter table public.households
  add column if not exists fund_hidden jsonb not null default '{}'::jsonb;

-- Hide a fund from Home, or show it again (admin only).
-- `p_fund_key` is one of fund / debt (Savings / Overspent
-- (Past)) — Spending and Charity are built in and can never be
-- hidden; the RPC refuses them. `p_hidden` true hides the fund,
-- false shows it again (removing the key). Returns the
-- household's updated fund_hidden map.
create or replace function public.set_fund_hidden(
  p_household_id uuid, p_fund_key text, p_hidden boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hidden_map jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_fund_key is null or p_fund_key not in ('fund', 'debt') then
    raise exception 'only Savings and Overspent can be hidden from Home';
  end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if p_hidden then
    update public.households
       set fund_hidden = jsonb_set(fund_hidden, array[p_fund_key], to_jsonb(true), true)
     where id = p_household_id
     returning fund_hidden into v_hidden_map;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund hidden from Home',
            'Fund ' || p_fund_key || ' hidden from Home.');
  else
    update public.households
       set fund_hidden = fund_hidden - p_fund_key
     where id = p_household_id
     returning fund_hidden into v_hidden_map;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund shown on Home',
            'Fund ' || p_fund_key || ' shown on Home again.');
  end if;
  if v_hidden_map is null then raise exception 'household not found'; end if;
  return v_hidden_map;
end;
$$;

revoke execute on function public.set_fund_hidden(uuid, text, boolean) from public;
grant execute on function public.set_fund_hidden(uuid, text, boolean) to authenticated;
