-- ██████████████████████████████████████████████████████████████████████
-- DO NOT APPLY THIS FILE. EVER.
-- ██████████████████████████████████████████████████████████████████████
-- This file renames update_fund_shortfall's parameter to p_household_id.
-- week-close calls the RPC BY NAMED ARGUMENT ({ household_id, shortfall_cents },
-- supabase/functions/week-close/index.ts:382), and PostgREST matches by
-- name — after this rename both call sites fail with a missing-parameter
-- error, mid-run, after closes/releases were already persisted. That is
-- the P0-3 failure this file was written to prevent.
-- The CANONICAL version is supabase/update-fund-shortfall.sql (alias-
-- qualified, parameter name kept as household_id). Apply that instead.
-- This file is kept in the repo only as a record of the rejected fix;
-- its DO-NOT-APPLY name is the quarantine. (P0-3, Nov 8, 2026.)
-- ██████████████████████████████████████████████████████████████████████
--
-- Deep audit Nov 5, 2026 — FIX for update_fund_shortfall ONLY.
-- DO NOT re-apply supabase/04-admin-rpcs.sql in full (its §1 Approve
-- function is outdated and re-applying it would break Approve).
-- Apply ONLY this file, after a live probe confirms the live function
-- still has the unprefixed `household_id` parameter (see DEEP_AUDIT_2026-11-05.md).
-- Bug: the parameter `household_id` shadowed the column of the same
-- name, so under plpgsql.variable_conflict = error every call raised
-- an ambiguous-column error. week-close's persistShortfall is the sole
-- caller, and only fires when the shortfall actually changes — so a
-- later week close with a shortfall move would 500 mid-run after
-- closes/releases were already persisted. This file renames the
-- parameter to p_household_id; the body, grants, and behaviour are
-- otherwise identical to 04-admin-rpcs.sql §3.
create or replace function public.update_fund_shortfall(p_household_id uuid, shortfall_cents integer)
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
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  select fund_shortfall_cents into v_old from households where id = p_household_id for update;
  if not found then raise exception 'household not found'; end if;
  update households set fund_shortfall_cents = shortfall_cents where id = p_household_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Fund shortfall updated',
            'Fund shortfall changed from ' || v_old::text || ' cents to ' || shortfall_cents::text || ' cents.');
end;
$$;
revoke execute on function public.update_fund_shortfall(uuid, integer) from public;
grant execute on function public.update_fund_shortfall(uuid, integer) to authenticated;
