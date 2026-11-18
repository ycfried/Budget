-- Household Budget — weekly budget top-ups (build 43, item 21,
-- owner Nov 17, 2026).
--
-- WHY: the expanded Spending card showed "Base $400.00" and
-- "Total $400.00" — the same number twice — whenever a one-time
-- "Top Up Budget" grant was the only thing raising the week above
-- the base. There was no client-only fix: `add_to_weekly_budget`
-- upserts ONE number into `weekly_allowance_overrides`, so the
-- override IS the week's total, folding together the temporary
-- allowance AND all top-ups; the `temp_increases` table holds no
-- rows for current app usage (no client calls that RPC — live.js
-- uses `set_weekly_allowance_override`); and parsing audit_log free
-- text for the amounts would be fragile. So the top-up gets its own
-- server-side record, mirroring the `temp_increases` pattern
-- (`supabase/live-temp-increases.sql`): one row per top-up grant,
-- never edited, and the breakdown's "Top Ups" line sums this table
-- for the current week.
--
-- WHAT CHANGES: one new table plus a one-line addition to the
-- existing `add_to_weekly_budget` RPC (copied verbatim from
-- `supabase/push-notifications.sql:233-278` — the function body is
-- unchanged apart from the new insert after the override upsert).
-- No change to any existing table, column, or function signature.
-- `CREATE OR REPLACE` preserves the function's existing grants.
--
-- LIVE DEPENDENCY: until this file is applied live (Supabase
-- dashboard SQL editor), top-ups keep folding into the override
-- with no separate record, and the client reads $0.00 for Top Ups
-- — the breakdown then reads exactly as it does today (Base +
-- Temporary Increase/Decrease = Total), never an error. Once
-- applied, new top-ups are recorded here; top-ups granted BEFORE
-- this file is applied have no rows and stay folded into the
-- override (their amount shows inside Temporary Increase/Decrease,
-- not on the Top Ups line) — there is no backfill from audit_log.

create table if not exists weekly_budget_topups (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  week_start date not null,
  amount_cents integer not null check (amount_cents > 0),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

alter table weekly_budget_topups enable row level security;

-- Table grants (lesson from Nov 1: RLS policies alone do not grant
-- table access — authenticated needs SELECT here or every read fails
-- with "permission denied for table" before RLS is even consulted).
grant select on weekly_budget_topups to authenticated;

-- R4 (Nov 9, 2026): drop-before-create, so re-applying this file
-- is idempotent — a second apply must not fail with ERROR 42710
-- (policy already exists).
drop policy if exists "members read own weekly budget topups" on weekly_budget_topups;
create policy "members read own weekly budget topups"
  on weekly_budget_topups for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));

-- add_to_weekly_budget RPC ("Top Up Budget" button, owner Nov 16,
-- 2026) — copied VERBATIM from supabase/push-notifications.sql
-- lines 233-278, with ONE addition: after the override upsert, a
-- row is inserted into weekly_budget_topups recording this grant.
-- The override upsert is unchanged (the override is still the
-- week's total, and compute-week still reads it); the new row only
-- lets the client split the total back into Base + Top Ups +
-- Temporary Increase/Decrease. The table is created above, before
-- this function, because the function references it. Atomic with
-- the upsert: a failed top-up writes neither row.
create or replace function public.add_to_weekly_budget(
  p_household_id uuid, p_week_start date, p_amount_cents integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base integer;
  v_current integer;
  v_new integer;
  v_name text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount must be greater than zero';
  end if;
  if p_week_start is null or extract(dow from p_week_start) <> 0 then
    raise exception 'week_start must be a Sunday';
  end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  select base_allowance_cents into v_base from public.households where id = p_household_id;
  if v_base is null then raise exception 'household not found'; end if;
  select allowance_cents into v_current from public.weekly_allowance_overrides
    where household_id = p_household_id and week_start = p_week_start;
  if v_current is null then v_current := v_base; end if;
  v_new := v_current + p_amount_cents;
  insert into public.weekly_allowance_overrides (household_id, week_start, allowance_cents, created_by)
    values (p_household_id, p_week_start, v_new, auth.uid())
    on conflict (household_id, week_start) do update set
      allowance_cents = excluded.allowance_cents,
      created_by = excluded.created_by,
      created_at = now();
  -- Build 43, item 21 (Nov 17, 2026): record this one-time grant
  -- so the Spending breakdown can show it on its own "Top Ups"
  -- line instead of folding it into the override. One row per
  -- grant, never edited.
  insert into public.weekly_budget_topups (household_id, week_start, amount_cents, created_by)
    values (p_household_id, p_week_start, p_amount_cents, auth.uid());
  select display_name into v_name from public.household_members
    where household_id = p_household_id and user_id = auth.uid();
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), coalesce(v_name, 'admin'), 'Added to weekly budget',
            'Added ' || p_amount_cents || ' cents to the budget for week ' || p_week_start
            || '. New total ' || v_new || ' cents.');
  return v_new;
end;
$$;
