-- Household Budget — weekly allowance overrides — APPLIED LIVE
-- (live since before Nov 9, 2026 — proven by the ERROR 42710
-- "policy already exists" on the Nov 9 step-6 first attempt, which
-- showed the table/policies were already live; the RPC bodies were
-- then repaired by an RPC-definitions-only apply on Nov 9 and
-- verified to contain 'week_start must be a Sunday'. R4-BE-2,
-- Nov 9, 2026 — the "NOT YET APPLIED" header this file carried
-- before is stale.) Do NOT re-apply this file blindly: re-apply
-- only if a live probe shows the live bodies have drifted from it,
-- and reconcile first.
--
-- WHY: the Temporary Increase box now means a NEW TOTAL weekly
-- allowance for that week (owner, Nov 4), repeating for 1-4 weeks.
-- A higher total could be faked as a positive temp increase, but a
-- LOWER total cannot — add_temp_increase rejects non-positive
-- amounts, and there was no per-week allowance override at all.
-- This file adds one: a per-week override that replaces both the
-- household base allowance AND any temp increase for that week.
--
-- SEMANTICS (read before approving):
-- - One row per (household_id, week_start); setting the same week
--   again replaces the previous override (upsert), it does not stack.
-- - For a week with an override, compute-week uses B = override
--   allowance and T = 0. Debt still comes off the top exactly as
--   before: baseAvailable = max(0, B - D), available =
--   baseAvailable - C (T = 0). Nothing else in the engine changes;
--   computeWeek({B, T, D, C}) is untouched.
-- - Setting an override DELETES any temp_increases rows for that
--   household/week, so an old temp increase can never add on top of
--   an override. The override is the whole story for that week.
-- - A week that already has a week_closes snapshot keeps its
--   snapshot: compute-week still prefers a stored snapshot's B/T
--   over any later override, and week-close still stores the
--   snapshot it computed. An override set AFTER a week closed does
--   not rewrite that closed week; it applies to open and future
--   weeks. To change a closed week, the owner must decide that
--   separately — this file deliberately does not rewrite history.
-- - The override does NOT change households.base_allowance_cents.
--   It is per-week only; weeks without an override keep using the
--   household base (plus temp increases, as before).
-- - Setting an override for a week in the past that is still open
--   (not yet closed) takes effect on the next compute-week load.
--
-- WHAT CHANGES: one new table, one new RPC, no changes to any
-- existing table, column, or function. The two Edge Functions
-- (compute-week, week-close) read the new table in this branch;
-- until this file is applied they fall back to the old behaviour
-- (no override rows found), so deploying the functions first is
-- safe and applying this file later is safe.

create table if not exists weekly_allowance_overrides (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  week_start date not null,
  allowance_cents integer not null check (allowance_cents >= 0),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (household_id, week_start)
);

alter table weekly_allowance_overrides enable row level security;

-- Table grants (lesson from Nov 1: RLS policies alone do not grant
-- table access — authenticated needs SELECT here or every read fails
-- with "permission denied for table" before RLS is even consulted).
grant select on weekly_allowance_overrides to authenticated;

-- R4 (Nov 9, 2026): drop-before-create, so re-applying this file
-- is idempotent — the Nov 9 step-6 first attempt failed with
-- ERROR 42710 (policy already exists) because this create had no
-- drop. Dropping and recreating the identical policy changes
-- nothing about the applied-live effect.
drop policy if exists "members read own weekly allowance overrides" on weekly_allowance_overrides;
create policy "members read own weekly allowance overrides"
  on weekly_allowance_overrides for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));

create or replace function public.set_weekly_allowance_override(p_household_id uuid, p_week_start date, p_allowance_cents integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_allowance_cents is null or p_allowance_cents < 0 then raise exception 'allowance must be zero or positive'; end if;
  -- P2-B4 (Nov 8, 2026): week_start must be a Sunday. compute-week
  -- and week-close look overrides up by exact Sunday (weekStartOf),
  -- so a non-Sunday row would silently never match — a no-op the
  -- admin would never notice. The DB CHECK in
  -- supabase/p2-sunday-week-start-checks.sql enforces the same rule
  -- at the table level; this raise gives the admin a readable error
  -- instead of a constraint violation. The client already sends
  -- Sundays (live.js builds the week from the NY Sunday).
  if p_week_start is null or extract(dow from p_week_start) <> 0 then
    raise exception 'week_start must be a Sunday';
  end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  insert into weekly_allowance_overrides (household_id, week_start, allowance_cents, created_by)
    values (p_household_id, p_week_start, p_allowance_cents, auth.uid())
    on conflict (household_id, week_start)
    do update set allowance_cents = excluded.allowance_cents,
                  created_by = excluded.created_by,
                  created_at = now();
  -- The override supersedes any old temp increase for this week:
  -- without this delete, a stale temp row would add on top of the
  -- override in any code path that still sums temp_increases.
  delete from temp_increases
    where household_id = p_household_id and week_start = p_week_start;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), 'admin', 'Weekly allowance set',
            'Weekly allowance set to ' || p_allowance_cents::text || ' cents for week ' || p_week_start::text || '.');
end;
$$;
revoke execute on function public.set_weekly_allowance_override(uuid, date, integer) from public;
grant execute on function public.set_weekly_allowance_override(uuid, date, integer) to authenticated;
