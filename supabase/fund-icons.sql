-- fund-icons.sql — Custom fund icons (build 41, owner Nov 16, 2026).
--
-- The owner wants to choose the ICON for each fund (Spending,
-- Tzedaka, Savings, Overspent (Past)). The icon shows in the
-- colored header's white circle on Home and Funds. This mirrors
-- fund-names.sql (build 37) exactly: one `fund_icons` JSONB column
-- on `households`, a map from fund key to SF Symbol name, e.g.
-- {"spending": "cart.fill", "charity": "heart.fill"}. Only keys
-- that differ from the default are stored; a missing key means the
-- default icon for that fund. Reads go through the existing
-- `households` SELECT policy (members can read their own
-- household's row); writes go through the `set_fund_icon` RPC below
-- (admin-only, security definer, audited), never a direct UPDATE.
--
-- Apply via the Supabase dashboard SQL editor (project "Budget").
-- The native app degrades gracefully if this is not applied yet:
-- the fund-icons read returns empty (default icons shown) and an
-- icon change fails with a plain-language error. Apply BEFORE the
-- build-41 TestFlight build goes out, as with the build-37
-- fund-names.sql.

alter table public.households
  add column if not exists fund_icons jsonb not null default '{}'::jsonb;

-- Set a fund's custom icon (admin only). `p_fund_key` is one of
-- spending / fund / charity / debt (the FundSectionID raw values).
-- `p_icon` is the SF Symbol name as picked in the app — stored
-- exactly as picked, no validation beyond the length cap (the app
-- only offers symbols from its picker list; the stored value is
-- rendered with a fallback to the default icon if it ever fails
-- to resolve). An empty / whitespace-only icon REMOVES the key,
-- resetting that fund to its default icon. Icons are capped at
-- 40 characters. Returns the household's updated fund_icons map.
create or replace function public.set_fund_icon(
  p_household_id uuid, p_fund_key text, p_icon text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_icon text;
  v_icons jsonb;
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
  v_icon := btrim(coalesce(p_icon, ''));
  if v_icon = '' then
    update public.households
       set fund_icons = fund_icons - p_fund_key
     where id = p_household_id
     returning fund_icons into v_icons;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund icon changed',
            'Fund ' || p_fund_key || ' reset to its default icon.');
  else
    if char_length(v_icon) > 40 then
      raise exception 'icon must be 40 characters or fewer';
    end if;
    update public.households
       set fund_icons = jsonb_set(fund_icons, array[p_fund_key], to_jsonb(v_icon), true)
     where id = p_household_id
     returning fund_icons into v_icons;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund icon changed',
            'Fund ' || p_fund_key || ' icon set to "' || v_icon || '".');
  end if;
  if v_icons is null then raise exception 'household not found'; end if;
  return v_icons;
end;
$$;

revoke execute on function public.set_fund_icon(uuid, text, text) from public;
grant execute on function public.set_fund_icon(uuid, text, text) to authenticated;
