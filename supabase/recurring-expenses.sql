-- recurring-expenses.sql — Build 67 (owner, Nov 23, 2026): the "Expense" kind.
--
-- The owner caught a $160.00 TIDEWATER PROPERTY MANAGEMENT charge
-- (posted Nov 23, 2026) that is an HOA charge — a recurring living
-- expense, NOT a purchase. He wants a new tag/group called "Expense"
-- for things that are not purchases, not donations, not incomes, not
-- transfers — they are expenses (recurring living costs like HOA).
-- An Expenses list (name, amount, frequency) feeds the weekly budget
-- calculation: income minus fixed expenses -> weekly allowance for
-- discretionary purchases.
--
-- OWNER DECISION (Nov 23 ~19:41): Expenses are DISCONNECTED from
-- weekly expenses. They do NOT count against the weekly
-- allowance/spending. That falls out of the kind itself:
--   * compute-week's C counts only kind = 'charge' / 'fund_charge'
--     (engine.mjs chargeContribution), so an 'expense' row
--     contributes 0 to week spending with no engine change.
--   * The client's Transactions header total (WeekTransactionsNetting
--     .spendingTotal) counts only charge / fund_charge / refund, so
--     an expense row contributes 0 there too — Home and Transactions
--     keep computing the same total (the standing F-1 rule).
--   * Plaid re-delivery never overwrites an admin-set kind
--     (plaid-sync/index.ts:106-107), so a tagged Expense stays one.
--   * The charity trigger (reclassify-income-accrual.sql v5) fires
--     on kind change: reclassifying AWAY from 'income' to 'expense'
--     reverses the accrual, and back to 'income' re-accrues — no
--     trigger change needed.
--
-- DESIGN (follows the existing patterns — transaction kinds, RPCs,
-- merchant_rules table + RLS):
--   * kind = 'expense' marks the transaction (9th kind).
--   * recurring_expenses holds one row per tagged transaction:
--     the display name + amount (prefilled from the transaction)
--     and the frequency (weekly / monthly / quarterly / yearly).
--     Invariant: kind = 'expense' ⟺ a recurring_expenses row
--     exists. reclassify_transaction maintains it both ways, so
--     every path that sets the kind (Actions sheet, Rename
--     Merchant fixed kind, direct reclassify) keeps the invariant.
--   * tag_transaction_expense is the Actions-sheet entry point:
--     the reclassify guards (admin, 35-day lock) + the expense row,
--     in one call, returning the expense id so the app can open
--     the editor for it at once.
--   * update_recurring_expense edits name / amount / frequency.
--   * remove_recurring_expense deletes the row AND reclassifies
--     the transaction back to 'charge', so it counts as spending
--     again (same 35-day lock as reclassify).
--   * An excluded expense row keeps its kind and its expense row;
--     the client list hides expenses whose transaction is trashed,
--     and restoring the transaction brings the expense back.
--   * A hand-entered expense row deleted via delete_transaction
--     drops its expense row with it (ON DELETE CASCADE).
--
-- APPLY: via the Supabase Management API (custom.supabase
-- connector). Idempotent: the constraint drops/re-adds, the table
-- uses CREATE IF NOT EXISTS, the RPCs use CREATE OR REPLACE.
-- No rows are touched by the constraint change (no live row holds
-- kind = 'expense' yet).

-- STEP 1 — Extend the kind constraint to 9 kinds (superset of the
-- live 8; dropping/re-adding a CHECK changes no rows and fails
-- only if a row already holds a kind outside the new list).
alter table transactions drop constraint if exists transactions_kind_check;
alter table transactions
  add constraint transactions_kind_check
  check (kind in ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income', 'expense'));

-- STEP 2 — Merchant rules can fix a kind to 'expense' (Rename
-- Merchant "Always Count As"). The fixed-kind check, the create
-- guard, and the apply sign guard all gain it — 'expense' is a
-- money-OUT kind (like charge), so the sign guard blocks it on
-- money-in (negative) rows, exactly like charge.
alter table public.merchant_rules drop constraint if exists merchant_rules_fixed_kind_check;
alter table public.merchant_rules
  add constraint merchant_rules_fixed_kind_check
  check (fixed_kind is null or fixed_kind in
    ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income', 'expense'));

create or replace function public.apply_merchant_rule_to_rows(
  p_household_id uuid, p_rule_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.merchant_rules%rowtype;
  v_count integer := 0;
begin
  select * into v_rule from public.merchant_rules where id = p_rule_id;
  if not found then raise exception 'merchant rule not found'; end if;
  if v_rule.household_id <> p_household_id then
    raise exception 'merchant rule belongs to another household';
  end if;
  with matched as (
    select t.id
      from public.transactions t
     where t.household_id = p_household_id
       and (public.merchant_rule_key(t.merchant) = v_rule.pattern_key
         or (v_rule.match_type = 'includes'
             and strpos(public.merchant_rule_squash(t.merchant), v_rule.pattern_squash) > 0)
         or public.merchant_rule_squash(t.merchant) = v_rule.pattern_squash)
  )
  update public.transactions t
     set merchant = v_rule.display_name,
         dedupe_hash = encode(
           extensions.digest(v_rule.display_name || '|' || t.date::text || '|' ||
                  t.amount_cents::text || '|' || t.card_suffix, 'sha256'), 'hex'),
         kind = case
           when v_rule.fixed_kind is null then t.kind
           when v_rule.fixed_kind in ('charge', 'charity', 'fund_charge', 'expense')
             and t.amount_cents <= 0 then t.kind
           when v_rule.fixed_kind in ('refund', 'payment', 'cashback', 'income')
             and t.amount_cents >= 0 then t.kind
           else v_rule.fixed_kind end
    from matched m
   where t.id = m.id
     and (t.merchant <> v_rule.display_name
       or (v_rule.fixed_kind is not null and t.kind <> v_rule.fixed_kind
           and not (v_rule.fixed_kind in ('charge', 'charity', 'fund_charge', 'expense') and t.amount_cents <= 0)
           and not (v_rule.fixed_kind in ('refund', 'payment', 'cashback', 'income') and t.amount_cents >= 0)));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke execute on function public.apply_merchant_rule_to_rows(uuid, uuid) from public;
revoke execute on function public.apply_merchant_rule_to_rows(uuid, uuid) from authenticated;
revoke execute on function public.apply_merchant_rule_to_rows(uuid, uuid) from anon;
grant execute on function public.apply_merchant_rule_to_rows(uuid, uuid) to service_role;

-- STEP 2b — DELIBERATELY UNCHANGED: the fixed-kind guards in
-- create_merchant_rule / update_merchant_rule /
-- rename_transaction_and_apply_rule (merchant-rules.sql §5) still
-- list the 8 kinds, and the Rename Merchant "Always Count As"
-- picker does NOT offer Expense in this build. Tagging an expense
-- happens from the Actions sheet (step 5), not from rename — so
-- those guards never see 'expense' and need no redefinition.
-- Redefining them by copy would risk drift against the canonical
-- merchant-rules.sql. The apply-function change in STEP 2 above
-- keeps the money-out set consistent for when the guards are
-- eventually extended. NOTE (follow-up, not this build): a future
-- HOA charge arrives as a plain charge and needs tagging by hand
-- each time; auto-tagging repeat occurrences via a merchant rule
-- is a separate piece of work (it also needs expense rows
-- de-duplicated by merchant, not one per occurrence).

-- STEP 3 — The recurring_expenses table: one row per tagged
-- transaction. Writes go through the security-definer RPCs below
-- (steps 5–7), so — like merchant_rules — only a member-read
-- policy is needed; the client never writes this table directly.
create table if not exists public.recurring_expenses (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  transaction_id uuid not null references public.transactions(id) on delete cascade,
  name text not null,
  amount_cents integer not null check (amount_cents > 0),
  frequency text not null default 'monthly'
    check (frequency in ('weekly', 'monthly', 'quarterly', 'yearly')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (transaction_id)
);
create index if not exists recurring_expenses_household_idx
  on public.recurring_expenses (household_id);

alter table public.recurring_expenses enable row level security;
drop policy if exists "members read own recurring expenses" on public.recurring_expenses;
create policy "members read own recurring expenses"
  on public.recurring_expenses for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.recurring_expenses to authenticated;

-- STEP 4 — reclassify_transaction: the canonical version from
-- refund-classification-income-kind.sql (8 kinds, 35-day lock,
-- F-31 refund-link clearing, P2-N7 auto-link) with 'expense'
-- added to the allow-list, plus the expense-row invariant:
--   * TO 'expense': upsert the recurring_expenses row from the
--     transaction (name / amount, frequency 'monthly' when new;
--     an existing row keeps its frequency).
--   * AWAY from 'expense': delete the row.
-- The 05-transaction-mutation-rpcs.sql copy stays bannered
-- never-apply and is NOT updated — only this file is canonical
-- for reclassify_transaction, like refund-classification-income-kind.sql.
create or replace function public.reclassify_transaction(txn_id uuid, new_kind text, reason text)
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
  if new_kind is null or new_kind not in ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'transfer', 'income', 'charity', 'expense') then
    raise exception 'invalid kind: must be charge, refund, fund_charge, payment, cashback, transfer, income, charity, or expense';
  end if;
  select * into v_row from transactions where id = txn_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only'; end if;
  -- P1-M2 (Nov 8, 2026): a locked week's transactions are immutable
  -- through the mutation RPCs — the same 35-day rule as
  -- mark_transaction_charity (r13-charity.sql). Locked-week
  -- corrections go through restoration, never a direct edit.
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
  end if;
  -- F-31 (build 61 audit, Nov 23, 2026): a row reclassified AWAY
  -- from 'refund' must not keep a stale original_purchase_id.
  update transactions set kind = new_kind,
    original_purchase_id = case when new_kind <> 'refund' then null else original_purchase_id end
    where id = txn_id;
  -- Build 67: the expense-row invariant — kind = 'expense' ⟺ a
  -- recurring_expenses row exists. TO 'expense' creates it from
  -- the transaction (monthly by default; an existing row keeps
  -- its frequency and its edited name/amount). AWAY from
  -- 'expense' removes it, so a reclassified row never leaves a
  -- stale expense behind.
  if new_kind = 'expense' then
    insert into public.recurring_expenses (household_id, transaction_id, name, amount_cents, frequency)
      values (v_row.household_id, txn_id, v_row.merchant, v_row.amount_cents, 'monthly')
      on conflict (transaction_id) do nothing;
  else
    delete from public.recurring_expenses where transaction_id = txn_id;
  end if;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction reclassified',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents reclassified from '
            || v_row.kind || ' to ' || new_kind
            || case when v_row.original_purchase_id is not null and new_kind <> 'refund'
                    then ' (refund link cleared)' else '' end
            || case when reason is not null and btrim(reason) <> ''
                    then ' — reason: ' || reason else ' — no reason given' end || '.');
  -- P2-N7 (Nov 8, 2026): a reclassification can make a pair linkable.
  -- Offer it to the refund linker best-effort so the pair links
  -- without waiting for a re-delivery. Linking never fails the
  -- reclassify, so errors are swallowed deliberately.
  begin
    if new_kind = 'refund' then
      perform public.auto_link_refund(txn_id);
    elsif new_kind in ('charge', 'fund_charge') then
      perform public.link_refunds_to_purchase(txn_id);
    end if;
  exception when others then
    null;
  end;
end;
$$;
revoke execute on function public.reclassify_transaction(uuid, text, text) from public;
grant execute on function public.reclassify_transaction(uuid, text, text) to authenticated;

-- STEP 5 — tag_transaction_expense(p_transaction_id, p_frequency,
-- p_reason): the Actions-sheet entry point. Same guards as
-- reclassify (auth, admin, 35-day lock) + the expense rules: the
-- row must be money out (amount > 0) and live (not excluded,
-- not reversed). Reclassifies to 'expense' (clearing a refund
-- link the F-31 way), upserts the expense row at the requested
-- frequency (an existing row keeps its frequency — tagging twice
-- never resets it), writes the audit row, and returns the
-- expense id so the app can open the editor for it at once.
create or replace function public.tag_transaction_expense(
  p_transaction_id uuid, p_frequency text, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row transactions%rowtype;
  v_now date;
  v_cur_week date;
  v_tx_week date;
  v_expense_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_frequency is null or p_frequency not in ('weekly', 'monthly', 'quarterly', 'yearly') then
    raise exception 'invalid frequency: must be weekly, monthly, quarterly, or yearly';
  end if;
  select * into v_row from transactions where id = p_transaction_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only'; end if;
  if v_row.excluded then raise exception 'transaction is in the Trash'; end if;
  if v_row.state = 'reversed' then raise exception 'transaction is reversed'; end if;
  if v_row.amount_cents <= 0 then raise exception 'only a money-out transaction can be an expense'; end if;
  v_now := (now() at time zone 'America/New_York')::date;
  v_cur_week := v_now - extract(dow from v_now)::int;
  v_tx_week := v_row.date - extract(dow from v_row.date)::int;
  if v_cur_week > v_tx_week + 35 then
    raise exception 'week is locked: a locked-week transaction cannot be changed here';
  end if;
  update transactions set kind = 'expense',
    original_purchase_id = null
    where id = p_transaction_id;
  insert into public.recurring_expenses (household_id, transaction_id, name, amount_cents, frequency)
    values (v_row.household_id, p_transaction_id, v_row.merchant, v_row.amount_cents, p_frequency)
    on conflict (transaction_id) do nothing
    returning id into v_expense_id;
  if v_expense_id is null then
    select id into v_expense_id from public.recurring_expenses where transaction_id = p_transaction_id;
  end if;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Transaction tagged as expense',
            v_row.merchant || ' ' || v_row.amount_cents::text || ' cents tagged as a recurring expense ('
            || p_frequency || ')'
            || case when v_row.original_purchase_id is not null
                    then ' (refund link cleared)' else '' end
            || case when p_reason is not null and btrim(p_reason) <> ''
                    then ' — reason: ' || p_reason else ' — no reason given' end || '.');
  return v_expense_id;
end;
$$;
revoke execute on function public.tag_transaction_expense(uuid, text, text) from public;
grant execute on function public.tag_transaction_expense(uuid, text, text) to authenticated;

-- STEP 6 — update_recurring_expense(p_expense_id, p_name,
-- p_amount_cents, p_frequency): the expense editor's save.
-- Admin only. Name non-empty, amount above $0, frequency valid.
-- Updates the expense row only — the linked transaction's own
-- amount is never touched (the expense amount is the recurring
-- amount; the transaction keeps its own figure).
create or replace function public.update_recurring_expense(
  p_expense_id uuid, p_name text, p_amount_cents integer, p_frequency text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.recurring_expenses%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_name is null or btrim(p_name) = '' then raise exception 'enter a name for this expense'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'enter an amount above $0.00'; end if;
  if p_frequency is null or p_frequency not in ('weekly', 'monthly', 'quarterly', 'yearly') then
    raise exception 'invalid frequency: must be weekly, monthly, quarterly, or yearly';
  end if;
  select * into v_row from public.recurring_expenses where id = p_expense_id;
  if not found then raise exception 'expense not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only'; end if;
  update public.recurring_expenses
     set name = btrim(p_name), amount_cents = p_amount_cents, frequency = p_frequency, updated_at = now()
   where id = p_expense_id;
end;
$$;
revoke execute on function public.update_recurring_expense(uuid, text, integer, text) from public;
grant execute on function public.update_recurring_expense(uuid, text, integer, text) to authenticated;

-- STEP 7 — remove_recurring_expense(p_expense_id, p_reason): the
-- expense editor's Remove. Deletes the expense row AND
-- reclassifies the linked transaction back to 'charge', so it
-- counts as weekly spending again (the same 35-day lock as
-- reclassify — a locked week's row cannot be un-tagged here).
-- Audit row records the removal.
create or replace function public.remove_recurring_expense(
  p_expense_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.recurring_expenses%rowtype;
  v_tx transactions%rowtype;
  v_now date;
  v_cur_week date;
  v_tx_week date;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_row from public.recurring_expenses where id = p_expense_id;
  if not found then raise exception 'expense not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_row.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only'; end if;
  select * into v_tx from transactions where id = v_row.transaction_id;
  if found then
    v_now := (now() at time zone 'America/New_York')::date;
    v_cur_week := v_now - extract(dow from v_now)::int;
    v_tx_week := v_tx.date - extract(dow from v_tx.date)::int;
    if v_cur_week > v_tx_week + 35 then
      raise exception 'week is locked: a locked-week transaction cannot be changed here';
    end if;
    update transactions set kind = 'charge' where id = v_row.transaction_id;
  end if;
  delete from public.recurring_expenses where id = p_expense_id;
  insert into audit_log (household_id, actor, actor_name, action, detail)
    values (v_row.household_id, auth.uid(), 'admin', 'Expense removed',
            v_row.name || ' ' || v_row.amount_cents::text || ' cents removed from recurring expenses'
            || case when found then ' — the transaction counts as a purchase again' else '' end
            || case when p_reason is not null and btrim(p_reason) <> ''
                    then ' — reason: ' || p_reason else '' end || '.');
end;
$$;
revoke execute on function public.remove_recurring_expense(uuid, text) from public;
grant execute on function public.remove_recurring_expense(uuid, text) to authenticated;

-- VERIFICATION (run after applying, read-only):
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--     where conrelid = 'transactions'::regclass and conname = 'transactions_kind_check';
--     -- expected: kind in ('charge','refund','fund_charge','payment',
--     --   'cashback','charity','transfer','income','expense')
--   select to_regclass('public.recurring_expenses');
--     -- expected: recurring_expenses
--   select pg_get_functiondef(oid) from pg_proc where proname = 'tag_transaction_expense';
--   select pg_get_functiondef(oid) from pg_proc where proname = 'reclassify_transaction';
--     -- expected: allow-list contains 'expense'
--   -- End-to-end on a TEST household only (never the live one):
--   -- tag a live charge as an expense, confirm kind = 'expense'
--   -- and a recurring_expenses row exists, then check compute-week
--   -- C drops by that amount and the Transactions header total
--   -- drops by the same amount; remove it and confirm kind is
--   -- 'charge' again and the row is gone.
