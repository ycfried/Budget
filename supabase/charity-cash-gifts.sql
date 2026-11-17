-- Charity cash gifts (build 40, Nov 16, 2026).
--
-- APPLY VIA: the Supabase dashboard SQL editor (same as build 39's
-- SQL). Do NOT apply live yourself from here — the parent applies
-- it. SAFE TO RE-RUN: CREATE TABLE IF NOT EXISTS + CREATE OR
-- REPLACE on one function; no column/constraint changes to existing
-- tables, no data migration.
--
-- WHY (owner, Nov 16, 2026): he gives charity in CASH (off-card)
-- and wants to take it off what he owes to charity — Available
-- decreases, Given increases, Total (committed) unchanged — WITHOUT
-- creating a transaction row (cash is not traceable as a bank/email
-- transaction and would confuse the transaction history). The gift
-- IS recorded on the charity fund and appears in the Charity
-- Activity & Transactions feed (audit trail).
--
-- WHY A NEW TABLE (not record_charity_gift): the existing
-- record_charity_gift RPC inserts a `transactions` row (kind
-- 'charity', source 'manual', state 'verified') — that row WOULD
-- appear in the Transactions list, which is exactly what the owner
-- does not want. And record_charity_income ADDS to Available (it
-- records income); this SUBTRACTS from it. So a cash gift needs its
-- own ledger: charity_cash_gifts. Given becomes (verified charity
-- transactions) + (active cash gifts); Available stays
-- committed − given; Total (committed) is unchanged.
--
-- MECHANISM:
--   * Table charity_cash_gifts: one row per cash gift, append-only
--     (status 'active' / 'reversed', mirroring charity_income, so a
--     mistaken gift can be reversed later without a schema change).
--   * RPC record_charity_cash_gift (admin-only, SECURITY DEFINER):
--     validates amount > 0, date >= 2026-11-01, and amount <= the
--     Available balance computed server-side (committed − verified
--     gifts − active cash gifts) — a cash gift can never take
--     Available below $0. Inserts the gift, writes an audit_log
--     entry, returns the gift id + the new Given / Available.
--   * RLS: members read their own household's cash gifts; writes
--     go through the RPC only (no direct insert policy).
--   * Client: loadCharity() fetches the active cash gifts and adds
--     their sum to givenCents; the Charity Activity feed shows cash
--     gifts as their own feed items (no transaction row is created
--     anywhere).

-- 1. Cash-gift ledger.
create table if not exists public.charity_cash_gifts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  amount_cents integer not null check (amount_cents > 0),
  gift_date date not null,
  note text not null default '',
  status text not null default 'active' check (status in ('active', 'reversed')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.charity_cash_gifts enable row level security;
drop policy if exists "members read own charity cash gifts" on public.charity_cash_gifts;
create policy "members read own charity cash gifts"
  on public.charity_cash_gifts for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.charity_cash_gifts to authenticated;

-- 2. Record a cash gift (admin-only).
create or replace function public.record_charity_cash_gift(
  p_household_id uuid, p_amount_cents integer, p_gift_date date, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_committed bigint;
  v_given_tx bigint;
  v_given_cash bigint;
  v_available bigint;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if p_gift_date is null or p_gift_date < date '2026-11-01' then raise exception 'charity starts November 2026'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Available = committed − given. Committed sums each ACTIVE
  -- income row at its own rate (same half-up rounding as
  -- record_charity_income). Given is verified kind='charity'
  -- transactions (not excluded, on/after 2026-11-01) PLUS active
  -- cash gifts. A cash gift can never take Available below $0.
  select coalesce(sum((amount_cents::bigint * rate_bp + 5000) / 10000), 0)
    into v_committed
    from public.charity_income
   where household_id = p_household_id and status = 'active';
  select coalesce(sum(amount_cents), 0)
    into v_given_tx
    from public.transactions
   where household_id = p_household_id
     and kind = 'charity' and state = 'verified' and not excluded
     and date >= date '2026-11-01';
  select coalesce(sum(amount_cents), 0)
    into v_given_cash
    from public.charity_cash_gifts
   where household_id = p_household_id and status = 'active';
  v_available := v_committed - v_given_tx - v_given_cash;
  if p_amount_cents > v_available then
    raise exception 'amount exceeds available charity: % cents available', v_available;
  end if;
  insert into public.charity_cash_gifts
    (household_id, amount_cents, gift_date, note, created_by)
  values (p_household_id, p_amount_cents, p_gift_date,
          left(btrim(coalesce(p_note, '')), 120), auth.uid())
  returning id into v_id;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Charity cash gift recorded',
          'Cash gift ' || p_amount_cents::text || ' cents on ' || p_gift_date::text
          || ' (Available ' || (v_available - p_amount_cents)::text || ' cents after).');
  return jsonb_build_object(
    'gift_id', v_id,
    'given_cents', v_given_tx + v_given_cash + p_amount_cents,
    'remaining_cents', v_available - p_amount_cents);
end;
$$;
revoke execute on function public.record_charity_cash_gift(uuid, integer, date, text) from public;
grant execute on function public.record_charity_cash_gift(uuid, integer, date, text) to authenticated;
