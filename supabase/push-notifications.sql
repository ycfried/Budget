-- OnBudget push notifications (notifications build, Nov 16, 2026).
--
-- Tables:
--   push_tokens            — one row per (user, device token).
--   push_deliveries        — dedupe store: one row per notified event.
--   notification_preferences — one row per (user, household): the
--     per-type toggles from the Settings Notifications card.
-- RPC:
--   set_notification_preferences(...) — upserts the caller's own row.
--
-- APPLY: run this file in the Supabase dashboard SQL Editor AFTER the
-- notifications PR is merged (the Edge Functions reference these tables).
-- It is idempotent (create if not exists / drop policy if exists).
-- Do NOT apply from a task — the parent applies it via the dashboard.
-- This file contains no secret values.

-- ---------------------------------------------------------------------------
-- push_tokens
-- ---------------------------------------------------------------------------
create table if not exists public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  device_token text not null,
  platform text not null default 'ios' check (platform = 'ios'),
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, device_token)
);

alter table public.push_tokens enable row level security;

-- A user may read / insert / update / delete only their own tokens.
-- Admins may NOT read other members' tokens. The service role (Edge
-- Functions) bypasses RLS and reads what it needs to send.
drop policy if exists "users manage own push tokens" on public.push_tokens;
create policy "users manage own push tokens"
  on public.push_tokens for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update, delete on public.push_tokens to authenticated;

-- ---------------------------------------------------------------------------
-- push_deliveries (dedupe store — server only, no client access)
-- ---------------------------------------------------------------------------
create table if not exists public.push_deliveries (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  event_key text not null,
  sent_at timestamptz not null default now(),
  unique (household_id, event_key)
);

alter table public.push_deliveries enable row level security;
-- No policies: only the service role (Edge Functions) touches this table.
-- Rows older than 90 days may be pruned:
--   delete from public.push_deliveries where sent_at < now() - interval '90 days';

-- ---------------------------------------------------------------------------
-- notification_preferences (per-user, per-type toggles)
-- ---------------------------------------------------------------------------
create table if not exists public.notification_preferences (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  notifications_enabled boolean not null default true,
  week_closed boolean not null default true,
  new_week boolean not null default true,
  over_budget boolean not null default true,
  new_purchase boolean not null default true,
  new_income boolean not null default true,
  new_charity boolean not null default true,
  monthly_statement boolean not null default true,
  member_joined boolean not null default true,
  member_left boolean not null default true,
  gmail_expiring boolean not null default true,
  fund_request boolean not null default true,
  needs_review boolean not null default true,
  large_purchase boolean not null default true,
  bank_broken boolean not null default true,
  budget_increased boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, user_id)
);

--- Added after the first apply (Nov 17, 2026): the master on/off
--- (notifications_enabled) and the needs_review toggle. The ALTERs
--- are idempotent so the file stays safe to re-run.
alter table public.notification_preferences
  add column if not exists notifications_enabled boolean not null default true;
alter table public.notification_preferences
  add column if not exists needs_review boolean not null default true;

alter table public.notification_preferences enable row level security;

-- A user may read / insert / update only their own preference row.
drop policy if exists "users manage own notification preferences" on public.notification_preferences;
create policy "users manage own notification preferences"
  on public.notification_preferences for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update on public.notification_preferences to authenticated;

-- ---------------------------------------------------------------------------
-- set_notification_preferences RPC
-- Upserts the caller's own preference row for a household. Any member
-- may set their own toggles (not admin-only — these are per-user).
-- All sixteen flags are required (the client always sends the full set).
-- Returns the saved row.
-- ---------------------------------------------------------------------------
create or replace function public.set_notification_preferences(
  p_household_id uuid,
  p_notifications_enabled boolean,
  p_week_closed boolean,
  p_new_week boolean,
  p_over_budget boolean,
  p_new_purchase boolean,
  p_new_income boolean,
  p_new_charity boolean,
  p_monthly_statement boolean,
  p_member_joined boolean,
  p_member_left boolean,
  p_gmail_expiring boolean,
  p_fund_request boolean,
  p_needs_review boolean,
  p_large_purchase boolean,
  p_bank_broken boolean,
  p_budget_increased boolean)
returns public.notification_preferences
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.notification_preferences;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid()) then
    raise exception 'not a household member';
  end if;

  insert into public.notification_preferences (
    household_id, user_id,
    notifications_enabled,
    week_closed, new_week, over_budget,
    new_purchase, new_income, new_charity,
    monthly_statement, member_joined, member_left, gmail_expiring,
    fund_request, needs_review, large_purchase, bank_broken, budget_increased)
  values (
    p_household_id, auth.uid(),
    p_notifications_enabled,
    p_week_closed, p_new_week, p_over_budget,
    p_new_purchase, p_new_income, p_new_charity,
    p_monthly_statement, p_member_joined, p_member_left, p_gmail_expiring,
    p_fund_request, p_needs_review, p_large_purchase, p_bank_broken, p_budget_increased)
  on conflict (household_id, user_id) do update set
    notifications_enabled = excluded.notifications_enabled,
    week_closed = excluded.week_closed,
    new_week = excluded.new_week,
    over_budget = excluded.over_budget,
    new_purchase = excluded.new_purchase,
    new_income = excluded.new_income,
    new_charity = excluded.new_charity,
    monthly_statement = excluded.monthly_statement,
    member_joined = excluded.member_joined,
    member_left = excluded.member_left,
    gmail_expiring = excluded.gmail_expiring,
    fund_request = excluded.fund_request,
    needs_review = excluded.needs_review,
    large_purchase = excluded.large_purchase,
    bank_broken = excluded.bank_broken,
    budget_increased = excluded.budget_increased,
    updated_at = now()
  returning * into v_row;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- Large-purchase threshold (Spending fund setting, owner Nov 16, 2026)
-- A household-level dollar amount: a purchase at or above it counts
-- as a "large purchase" for the large_purchase notification.
-- Default $100.00 (10000 cents). Changed from the Funds page
-- (Spending fund), admin-only.
-- ---------------------------------------------------------------------------
alter table public.households
  add column if not exists large_purchase_threshold_cents integer not null default 10000
  check (large_purchase_threshold_cents >= 0);

create or replace function public.set_large_purchase_threshold(
  p_household_id uuid, p_threshold_cents integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_threshold_cents is null or p_threshold_cents < 0 then
    raise exception 'threshold must be zero or positive';
  end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  update public.households
     set large_purchase_threshold_cents = p_threshold_cents
   where id = p_household_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- add_to_weekly_budget RPC ("Add to Budget" button, owner Nov 16, 2026)
-- One-time top-up to the CURRENT week's budget only. The caller passes
-- only the amount to add; the server reads the week's current total
-- (the override's allowance, or the base when no override exists),
-- adds the amount, and upserts the override for that week only —
-- reusing the existing weekly_allowance_overrides table and the
-- week-close engine's override semantics (the override IS the week's
-- total). Atomic, so two admins adding at once cannot overwrite each
-- other. Returns the new total allowance for the week (cents).
-- Admin-only, amount must be > 0, week_start must be a Sunday.
-- Writes the audit_log entry ("Added to weekly budget").
-- ---------------------------------------------------------------------------
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
  select display_name into v_name from public.household_members
    where household_id = p_household_id and user_id = auth.uid();
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (p_household_id, auth.uid(), coalesce(v_name, 'admin'), 'Added to weekly budget',
            'Added ' || p_amount_cents || ' cents to the budget for week ' || p_week_start
            || '. New total ' || v_new || ' cents.');
  return v_new;
end;
$$;
