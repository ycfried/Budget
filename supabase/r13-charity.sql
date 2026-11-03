-- R13 Charity — PREPARED ONLY, DO NOT APPLY without owner approval.
--
-- Basis (owner decisions, Nov 3, 2026): charity is 10% of money
-- actually received plus manually entered amounts, starting November
-- 1, 2026. Per-income overrides REPLACE the default (they never
-- stack); a global default change applies to future incomes only,
-- unless an old income is explicitly corrected. Transfers, refunds,
-- reimbursements, loans, and Extra Fund top-ups never auto-accrue:
-- income reaches this ledger only through record_charity_income,
-- which the admin calls deliberately. Nothing here classifies a bank
-- row by name similarity, and nothing here touches weekly math:
--   * 'charity' is a new transactions kind. compute-week and the
--     client week panel only count kind charge/fund_charge (charges)
--     and kind refund (refunds), so a charity row automatically sits
--     OUTSIDE weekly spending, allowance, and debt math.
--   * Given counts only kind='charity' rows with state='verified',
--     not excluded, dated on/after 2026-11-01. A pending (provisional)
--     donation counts in nothing until it posts AND an admin
--     confirms it with mark_transaction_charity.
--   * Locked weeks are never rewritten: mark_transaction_charity
--     refuses a row whose Sunday week ended more than 28 days before
--     the current Sunday week (the engine's lock rule). Locked-week
--     reclassification via the restoration pattern is a later slice,
--     not invented here.
--   * Splits are not in this slice: a bank charge is marked as a
--     gift whole, or not at all. Splitting one charge into a gift
--     part and a spending part needs a server week-math change and
--     is deliberately left out.
-- Corrections are append-only: correct_charity_income marks the old
-- income row 'reversed' and inserts a replacement (replaces_id set);
-- no income row is ever edited or deleted. Rates are integer basis
-- points (1000 = 10%); committed per income is half-up rounded:
-- (amount_cents * rate_bp + 5000) / 10000 in integer arithmetic.
begin;
-- 1. Extend the transactions kind check with 'charity', following the
-- payment-kind.sql pattern (look the constraint up, drop it, re-add).
do $$
declare
  c text;
begin
  select conname into c
    from pg_constraint
   where conrelid = 'transactions'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) like '%fund_charge%';
  if c is not null then
    execute 'alter table transactions drop constraint ' || quote_ident(c);
  end if;
end $$;
alter table transactions
  add constraint transactions_kind_check
  check (kind in ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity'));

-- 2. Charity settings + income ledger. Writes go through the RPCs
-- only (admin-only, SECURITY DEFINER); members read their household.
create table if not exists public.charity_settings (
  household_id uuid primary key references public.households(id) on delete cascade,
  default_rate_bp integer not null default 1000 check (default_rate_bp between 0 and 10000),
  updated_at timestamptz not null default now()
);
create table if not exists public.charity_income (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  source_label text not null default 'Income',
  amount_cents integer not null check (amount_cents > 0),
  income_date date not null,
  rate_bp integer not null check (rate_bp between 0 and 10000),
  status text not null default 'active' check (status in ('active', 'reversed')),
  replaces_id uuid references public.charity_income(id) on delete set null,
  note text not null default '',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.charity_settings enable row level security;
alter table public.charity_income enable row level security;
drop policy if exists "members read own charity settings" on public.charity_settings;
create policy "members read own charity settings"
  on public.charity_settings for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
drop policy if exists "members read own charity income" on public.charity_income;
create policy "members read own charity income"
  on public.charity_income for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.charity_settings to authenticated;
grant select on public.charity_income to authenticated;

-- Shared admin guard, kept inline per RPC (no helper function to
-- keep the approval surface exactly these five RPCs).
create or replace function public.set_charity_default_rate(
  p_household_id uuid, p_rate_bp integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_rate_bp is null or p_rate_bp < 0 or p_rate_bp > 10000 then raise exception 'rate must be between 0 and 10000 basis points'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  insert into public.charity_settings (household_id, default_rate_bp, updated_at)
  values (p_household_id, p_rate_bp, now())
  on conflict (household_id)
  do update set default_rate_bp = excluded.default_rate_bp, updated_at = now();
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Charity default rate changed',
          'Default charity rate set to ' || p_rate_bp::text || ' basis points (applies to future incomes only).');
end;
$$;

create or replace function public.record_charity_income(
  p_household_id uuid, p_amount_cents integer, p_income_date date,
  p_source_label text, p_rate_bp integer, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rate integer;
  v_label text;
  v_id uuid;
  v_committed integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if p_income_date is null or p_income_date < date '2026-11-01' then raise exception 'charity starts November 2026'; end if;
  if p_rate_bp is not null and (p_rate_bp < 0 or p_rate_bp > 10000) then raise exception 'rate must be between 0 and 10000 basis points'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  select default_rate_bp into v_rate from public.charity_settings where household_id = p_household_id;
  v_rate := coalesce(p_rate_bp, v_rate, 1000);
  v_label := nullif(btrim(coalesce(p_source_label, '')), '');
  if v_label is null then v_label := 'Income'; end if;
  v_committed := (p_amount_cents * v_rate + 5000) / 10000;
  insert into public.charity_income
    (household_id, source_label, amount_cents, income_date, rate_bp, note, created_by)
  values (p_household_id, v_label, p_amount_cents, p_income_date, v_rate,
          left(btrim(coalesce(p_note, '')), 120), auth.uid())
  returning id into v_id;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Charity income recorded',
          'Income ' || v_label || ' ' || p_amount_cents::text || ' cents on ' || p_income_date::text
          || ' at ' || v_rate::text || ' basis points commits ' || v_committed::text || ' cents to charity.');
  return jsonb_build_object('income_id', v_id, 'rate_bp', v_rate, 'committed_cents', v_committed);
end;
$$;

create or replace function public.correct_charity_income(
  p_income_id uuid, p_amount_cents integer, p_income_date date,
  p_source_label text, p_rate_bp integer, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old charity_income%rowtype;
  v_rate integer;
  v_label text;
  v_id uuid;
  v_committed integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_old from public.charity_income where id = p_income_id;
  if not found then raise exception 'income not found'; end if;
  if v_old.status <> 'active' then raise exception 'income is not active'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if p_income_date is null or p_income_date < date '2026-11-01' then raise exception 'charity starts November 2026'; end if;
  if p_rate_bp is not null and (p_rate_bp < 0 or p_rate_bp > 10000) then raise exception 'rate must be between 0 and 10000 basis points'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_old.household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Append-only correction: the old row stays, marked reversed.
  update public.charity_income set status = 'reversed' where id = p_income_id;
  v_rate := coalesce(p_rate_bp, v_old.rate_bp);
  v_label := nullif(btrim(coalesce(p_source_label, '')), '');
  if v_label is null then v_label := v_old.source_label; end if;
  v_committed := (p_amount_cents * v_rate + 5000) / 10000;
  insert into public.charity_income
    (household_id, source_label, amount_cents, income_date, rate_bp, replaces_id, note, created_by)
  values (v_old.household_id, v_label, p_amount_cents, p_income_date, v_rate, p_income_id,
          left(btrim(coalesce(p_note, '')), 120), auth.uid())
  returning id into v_id;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_old.household_id, auth.uid(), 'admin', 'Charity income corrected',
          'Income ' || v_old.source_label || ' ' || v_old.amount_cents::text || ' cents reversed and replaced by '
          || v_label || ' ' || p_amount_cents::text || ' cents at ' || v_rate::text
          || ' basis points, committing ' || v_committed::text || ' cents.');
  return jsonb_build_object('income_id', v_id, 'rate_bp', v_rate, 'committed_cents', v_committed);
end;
$$;

create or replace function public.record_charity_gift(
  p_household_id uuid, p_merchant text, p_amount_cents integer, p_date date,
  p_card_suffix text, p_note text, p_dedupe_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_merchant text;
  v_suffix text;
  v_hash text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if p_date is null or p_date < date '2026-11-01' then raise exception 'charity starts November 2026'; end if;
  v_merchant := upper(btrim(coalesce(p_merchant, '')));
  if v_merchant = '' then raise exception 'organization is required'; end if;
  v_suffix := nullif(btrim(coalesce(p_card_suffix, '')), '');
  if v_suffix is null then v_suffix := '0000'; end if;
  if v_suffix !~ '^[0-9]{4}$' then raise exception 'card suffix must be exactly 4 digits'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- A gift entered by hand is explicitly confirmed by the admin
  -- entering it, so it posts as verified (Given) at once. It is
  -- kind 'charity', so it never enters weekly spending math.
  v_hash := nullif(btrim(coalesce(p_dedupe_hash, '')), '');
  if v_hash is null then
    -- Fallback only (the client always sends a hash with a per-submit
    -- nonce, so two real identical gifts on one day never collide).
    v_hash := md5('charity|' || p_date::text || '|' || v_merchant || '|' || p_amount_cents::text || '|' || v_suffix || '|' || gen_random_uuid()::text);
  end if;
  insert into public.transactions
    (household_id, date, merchant, amount_cents, card_suffix, source, state, kind, dedupe_hash)
  values (p_household_id, p_date, v_merchant, p_amount_cents, v_suffix, 'manual', 'verified', 'charity', v_hash)
  returning id into v_id;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Charity gift recorded',
          'Gift ' || v_merchant || ' ' || p_amount_cents::text || ' cents on ' || p_date::text || '.');
  return jsonb_build_object('transaction_id', v_id);
end;
$$;

create or replace function public.mark_transaction_charity(p_transaction_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from public.transactions where id = p_transaction_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_row.household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if v_row.kind <> 'charge' then raise exception 'only a charge can be marked as a charity gift'; end if;
  if v_row.state <> 'verified' then raise exception 'only a posted transaction can be marked as a charity gift'; end if;
  if v_row.excluded then raise exception 'an excluded transaction cannot be marked as a charity gift'; end if;
  if coalesce(v_row.fund_allocation_cents, 0) <> 0 then raise exception 'a transaction partly paid from the fund cannot be marked as a charity gift'; end if;
  if v_row.date < date '2026-11-01' then raise exception 'charity starts November 2026'; end if;
  -- Engine lock rule, in NY Sunday weeks: locked once the current
  -- Sunday week is more than 35 days after the transaction's Sunday
  -- week (week end + 28 days). Locked weeks are never rewritten.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then raise exception 'week is locked: a locked-week gift cannot be marked here'; end if;
  update public.transactions set kind = 'charity' where id = p_transaction_id;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_row.household_id, auth.uid(), 'admin', 'Transaction marked as charity gift',
          v_row.merchant || ' ' || v_row.amount_cents::text || ' cents on ' || v_row.date::text
          || ' marked as a charity gift (now outside weekly spending).');
end;
$$;
revoke execute on function public.set_charity_default_rate(uuid, integer) from public;
grant execute on function public.set_charity_default_rate(uuid, integer) to authenticated;
revoke execute on function public.record_charity_income(uuid, integer, date, text, integer, text) from public;
grant execute on function public.record_charity_income(uuid, integer, date, text, integer, text) to authenticated;
revoke execute on function public.correct_charity_income(uuid, integer, date, text, integer, text) from public;
grant execute on function public.correct_charity_income(uuid, integer, date, text, integer, text) to authenticated;
revoke execute on function public.record_charity_gift(uuid, text, integer, date, text, text, text) from public;
grant execute on function public.record_charity_gift(uuid, text, integer, date, text, text, text) to authenticated;
revoke execute on function public.mark_transaction_charity(uuid) from public;
grant execute on function public.mark_transaction_charity(uuid) to authenticated;
commit;
