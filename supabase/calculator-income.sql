-- calculator-income.sql — Build 69 (owner, Nov 24, 2026):
-- "Calculator should be per household."
--
-- The Weekly Budget Calculator's Expected Income lived in
-- UserDefaults, per device — so Chaya's iPhone showed "Nothing
-- added yet" and a negative suggested budget (-$35.10) while
-- Shuki's devices had the income entered. The income (and the
-- suggested budget it drives) is household data, not device data:
-- it moves into Supabase, household-scoped, so every member sees
-- the same income and the same suggested budget on every device.
--
-- DESIGN (follows recurring_expenses.sql, build 67):
--   * calculator_income holds one row per income source: the
--     name + amount per occurrence + frequency (weekly / monthly /
--     quarterly / yearly) — the same fields the Calculator's
--     CalculatorItem already carries.
--   * RLS: every household member reads AND writes their
--     household's rows (the Calculator is for all roles — the
--     income is a shared household input, not admin-only). This
--     differs from recurring_expenses, whose writes go through
--     admin-only RPCs because tagging reclassifies a transaction;
--     a calculator income row has no side effects, so direct
--     PostgREST insert/delete is enough (the fund_requests
--     pattern: members insert directly).
--   * The client migrates existing per-device entries once
--     (FundsViewModel.loadCalculatorIncome): on first load, any
--     local UserDefaults income rows are uploaded (skipping ones
--     already present by name + amount + frequency, so two
--     devices migrating the same entries do not duplicate them),
--     then the local key is cleared. A migration flag per device
--     makes it one-time.
--
-- APPLY: via the Supabase Management API (custom.supabase
-- connector). Idempotent: CREATE IF NOT EXISTS, policies dropped
-- and re-created, grants re-issued. NEW table — no existing rows
-- are touched.
--
-- NOT shared (yet): the Calculator's other inputs — charity %,
-- lifestyle, custom holdback, household size — stay per-device
-- UserDefaults. They affect the suggestion too, so the suggestion
-- could still differ slightly across devices if those differ;
-- sharing them is a follow-up, not this build.

create table if not exists public.calculator_income (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null,
  amount_cents integer not null check (amount_cents > 0),
  frequency text not null default 'monthly'
    check (frequency in ('weekly', 'monthly', 'quarterly', 'yearly')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists calculator_income_household_idx
  on public.calculator_income (household_id);

alter table public.calculator_income enable row level security;
drop policy if exists "members read own calculator income" on public.calculator_income;
create policy "members read own calculator income"
  on public.calculator_income for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
drop policy if exists "members write own calculator income" on public.calculator_income;
create policy "members write own calculator income"
  on public.calculator_income for all
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()))
  with check (household_id in (select household_id from public.household_members
                               where user_id = auth.uid()));
grant select, insert, update, delete on public.calculator_income to authenticated;
