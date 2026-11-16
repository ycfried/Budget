-- fund-names.sql — Fund rename (build 37, owner Nov 16, 2026).
--
-- The owner asked how to rename the funds. Renaming was a confirmed
-- rule (Nov 15) but never built: each fund (Spending, Charity, Extra
-- Fund, Carried Debt) is renamable from the Funds page, and the new
-- name updates EVERYWHERE (Funds, Home, Transactions filters,
-- buttons, widget). The custom name is stored per household so it
-- persists and syncs across devices.
--
-- Storage: one `fund_names` JSONB column on `households`, a map from
-- fund key to custom name, e.g. {"spending": "Weekly Spending",
-- "charity": "Tzedakah"}. Only keys that differ from the default are
-- stored; a missing key means the default name. Reads go through the
-- existing `households` SELECT policy (members can read their own
-- household's row); writes go through the `set_fund_name` RPC below
-- (admin-only, security definer, audited), never a direct UPDATE.
--
-- Apply via the Supabase dashboard SQL editor (project "Budget").
-- The native app degrades gracefully if this is not applied yet:
-- the fund-names read returns empty (defaults shown) and a rename
-- attempt fails with a plain-language error. Apply BEFORE the
-- build-37 TestFlight build goes out, as with the build-34
-- includes migration.

alter table public.households
  add column if not exists fund_names jsonb not null default '{}'::jsonb;

-- Set a fund's custom name (admin only). `p_fund_key` is one of
-- spending / fund / charity / debt (the FundSectionID raw values).
-- `p_name` is the new name as typed — stored exactly as typed, no
-- Title Case forcing. An empty / whitespace-only name REMOVES the
-- key, resetting that fund to its default name. Names are capped at
-- 40 characters. Returns the household's updated fund_names map.
create or replace function public.set_fund_name(
  p_household_id uuid, p_fund_key text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_names jsonb;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_fund_key is null or p_fund_key not in ('spending', 'fund', 'charity', 'debt') then
    raise exception 'fund must be spending, fund, charity, or debt';
  end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  v_name := btrim(coalesce(p_name, ''));
  if v_name = '' then
    update public.households
       set fund_names = fund_names - p_fund_key
     where id = p_household_id
     returning fund_names into v_names;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund renamed',
            'Fund ' || p_fund_key || ' reset to its default name.');
  else
    if char_length(v_name) > 40 then
      raise exception 'name must be 40 characters or fewer';
    end if;
    update public.households
       set fund_names = jsonb_set(fund_names, array[p_fund_key], to_jsonb(v_name), true)
     where id = p_household_id
     returning fund_names into v_names;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund renamed',
            'Fund ' || p_fund_key || ' renamed to "' || v_name || '".');
  end if;
  if v_names is null then raise exception 'household not found'; end if;
  return v_names;
end;
$$;

revoke execute on function public.set_fund_name(uuid, text, text) from public;
grant execute on function public.set_fund_name(uuid, text, text) to authenticated;
