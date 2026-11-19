-- fund-prominence.sql — How each fund shows on Home (build 46, owner Nov 18, 2026).
--
-- The owner picked the simpler Home mockup: Spending is the hero,
-- Tzedaka is the clear second card, Savings and Overspent (Past)
-- are quiet rows. But the OTHER cards must be customizable too —
-- not just Spending: the owner wants to set up each card the way
-- he wants, so every fund gets a prominence: hero / card / quiet
-- row. This mirrors fund-icons.sql (build 41) exactly: one
-- `fund_prominence` JSONB column on `households`, a map from fund
-- key to prominence, e.g. {"spending": "hero", "charity": "card",
-- "fund": "quiet", "debt": "quiet"}. Only keys that differ from the
-- default are stored; a missing key means the default prominence
-- for that fund (Spending hero, Tzedaka card, Savings quiet,
-- Overspent quiet — the mockup layout). Reads go through the
-- existing `households` SELECT policy (members can read their own
-- household's row); writes go through the `set_fund_prominence`
-- RPC below (admin-only, security definer, audited), never a
-- direct UPDATE.
--
-- Apply via the Supabase dashboard SQL editor (project "Budget").
-- The native app degrades gracefully if this is not applied yet:
-- the prominence read returns empty (the mockup defaults show)
-- and a prominence change fails with a plain-language error.
-- Apply BEFORE the build-46 TestFlight build goes out, as with
-- the build-41 fund-icons.sql.

alter table public.households
  add column if not exists fund_prominence jsonb not null default '{}'::jsonb;

-- Set a fund's Home prominence (admin only). `p_fund_key` is one
-- of spending / fund / charity / debt (the FundSectionID raw
-- values). `p_prominence` is one of hero / card / quiet. An empty /
-- whitespace-only prominence REMOVES the key, resetting that fund
-- to its default prominence. Returns the household's updated
-- fund_prominence map.
create or replace function public.set_fund_prominence(
  p_household_id uuid, p_fund_key text, p_prominence text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prominence text;
  v_prominence_map jsonb;
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
  v_prominence := btrim(coalesce(p_prominence, ''));
  if v_prominence = '' then
    update public.households
       set fund_prominence = fund_prominence - p_fund_key
     where id = p_household_id
     returning fund_prominence into v_prominence_map;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund prominence changed',
            'Fund ' || p_fund_key || ' reset to its default Home prominence.');
  else
    if v_prominence not in ('hero', 'card', 'quiet') then
      raise exception 'prominence must be hero, card, or quiet';
    end if;
    update public.households
       set fund_prominence = jsonb_set(fund_prominence, array[p_fund_key], to_jsonb(v_prominence), true)
     where id = p_household_id
     returning fund_prominence into v_prominence_map;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund prominence changed',
            'Fund ' || p_fund_key || ' shows on Home as ' || v_prominence || '.');
  end if;
  if v_prominence_map is null then raise exception 'household not found'; end if;
  return v_prominence_map;
end;
$$;

revoke execute on function public.set_fund_prominence(uuid, text, text) from public;
grant execute on function public.set_fund_prominence(uuid, text, text) to authenticated;
