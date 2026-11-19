-- Reverse a charity cash gift / a charity income row (build 46, Nov 18, 2026).
--
-- APPLY VIA: the Supabase dashboard SQL editor (same as build 44's
-- SQL). Do NOT apply live yourself from here — the parent applies
-- it. SAFE TO RE-RUN: CREATE OR REPLACE on two functions only; no
-- table/constraint changes, no data migration.
--
-- WHY (owner, Nov 18, 2026): "when adding a transaction on charity
-- you can't delete it once it was added.. even when you go to
-- correct it.. you can't delete it." Two hand-added charity records
-- had NO delete path at all:
--   * Cash gifts ("Record a Transaction" on the Tzedaka card) live
--     in charity_cash_gifts, not the transactions table — the feed
--     row showed date + note only, with no Delete and no Correct.
--     The table was built append-only with a status column
--     ('active' / 'reversed', charity-cash-gifts.sql) precisely so a
--     mistaken gift could be reversed later without a schema change.
--   * Charity income rows have a Correct flow (reverse + replace)
--     but no delete — the Correct form is where the owner looked.
-- Both reversals are status flips, never hard deletes: the old row
-- stays, marked reversed, in the audit trail (same append-only rule
-- as correct_charity_income). The client fetch for cash gifts
-- already filters status = 'active', so a reversed gift drops out
-- of the feed AND out of Given (Available rises back) with no
-- client change; the same holds for the charity summary, which sums
-- ACTIVE income rows only.
--
-- MECHANISM:
--   * RPC reverse_charity_cash_gift (admin-only, SECURITY DEFINER):
--     the gift must exist and still be active; flips status to
--     'reversed', writes an audit_log entry, returns the gift id +
--     the new Given / Available (same shape as
--     record_charity_cash_gift, so the client reuses
--     CharityCashGiftResult).
--   * RPC reverse_charity_income (admin-only, SECURITY DEFINER):
--     the income must exist and still be active; flips status to
--     'reversed', writes an audit_log entry, returns the reversed
--     row's id + rate + committed cents (same shape as
--     correct_charity_income, so the client reuses
--     CharityIncomeResult) — the committed figure is what the
--     reversal REMOVES from Total.
--   * RLS: no direct update policy exists on either table (writes
--     go through the RPCs only), so nothing else can flip a status.
--
-- NOTE: until this file is applied live neither RPC exists and the
-- native delete buttons fail with a plain-language error; nothing
-- is changed. (Same precedent as remove-weekly-allowance-override.)

-- 1. Reverse a cash gift.
create or replace function public.reverse_charity_cash_gift(p_gift_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gift charity_cash_gifts%rowtype;
  v_committed bigint;
  v_given_tx bigint;
  v_given_cash bigint;
  v_available bigint;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_gift from public.charity_cash_gifts where id = p_gift_id;
  if not found then raise exception 'gift not found'; end if;
  if v_gift.status <> 'active' then raise exception 'gift is not active'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_gift.household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Append-only reversal: the gift stays, marked reversed.
  update public.charity_cash_gifts set status = 'reversed' where id = p_gift_id;
  -- Given / Available AFTER the reversal (same arithmetic as
  -- record_charity_cash_gift: committed sums each ACTIVE income row
  -- at its own rate; Given is verified kind='charity' transactions
  -- plus ACTIVE cash gifts — the reversed gift is out of both).
  select coalesce(sum((amount_cents::bigint * rate_bp + 5000) / 10000), 0)
    into v_committed
    from public.charity_income
   where household_id = v_gift.household_id and status = 'active';
  select coalesce(sum(amount_cents), 0)
    into v_given_tx
    from public.transactions
   where household_id = v_gift.household_id
     and kind = 'charity' and state = 'verified' and not excluded
     and date >= date '2026-11-01';
  select coalesce(sum(amount_cents), 0)
    into v_given_cash
    from public.charity_cash_gifts
   where household_id = v_gift.household_id and status = 'active';
  v_available := v_committed - v_given_tx - v_given_cash;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_gift.household_id, auth.uid(), 'admin', 'Charity cash gift reversed',
          'Cash gift ' || v_gift.amount_cents::text || ' cents on ' || v_gift.gift_date::text
          || ' reversed (Available ' || v_available::text || ' cents after).');
  return jsonb_build_object(
    'gift_id', v_gift.id,
    'given_cents', v_given_tx + v_given_cash,
    'remaining_cents', v_available);
end;
$$;
revoke execute on function public.reverse_charity_cash_gift(uuid) from public;
grant execute on function public.reverse_charity_cash_gift(uuid) to authenticated;

-- 2. Reverse (delete) a charity income row, with no replacement.
create or replace function public.reverse_charity_income(p_income_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old charity_income%rowtype;
  v_committed bigint;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_old from public.charity_income where id = p_income_id;
  if not found then raise exception 'income not found'; end if;
  if v_old.status <> 'active' then raise exception 'income is not active'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_old.household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- Append-only reversal: the income stays, marked reversed.
  update public.charity_income set status = 'reversed' where id = p_income_id;
  v_committed := (v_old.amount_cents::bigint * v_old.rate_bp + 5000) / 10000;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_old.household_id, auth.uid(), 'admin', 'Charity income reversed',
          'Income ' || v_old.source_label || ' ' || v_old.amount_cents::text || ' cents on '
          || v_old.income_date::text || ' reversed, removing '
          || v_committed::text || ' cents committed to charity.');
  return jsonb_build_object(
    'income_id', v_old.id,
    'rate_bp', v_old.rate_bp,
    'committed_cents', v_committed);
end;
$$;
revoke execute on function public.reverse_charity_income(uuid) from public;
grant execute on function public.reverse_charity_income(uuid) to authenticated;
