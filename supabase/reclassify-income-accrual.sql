-- reclassify-income-accrual.sql — Nov 20, 2026 (CHEDER credits gap).
-- v3 (Nov 22, 2026 — build 55): adds the EXCLUDE / RESTORE
-- directions (owner report, Nov 22 ~7:39 AM) + a one-time repair.
--
-- v3 ROOT CAUSE (owner screenshot, Tzedaka fund page): two
-- EXCLUDED income transactions still counted toward charity —
-- Yehoshua Friedman +$3,000.00 (Nov 22 Zelle from himself) and
-- Avraham Friedman +$1,000.00 (Nov 20 Zelle). The Tzedaka Total
-- read $1,522.37 against the verified committed total of
-- $1,122.37 (Nov 20): a $400.00 gap, exactly 10% of the $4,000 of
-- excluded income. Exclusion is a SEPARATE action from
-- reclassification: exclude_transaction (dedupe-refund-safeguards.sql)
-- sets excluded = true and state = 'excluded' but never changes
-- kind, so this trigger — which fired only AFTER UPDATE OF kind —
-- never ran and the charity_income rows stayed status='active'.
-- The owner's standing invariant: "anything labeled as income
-- generates charity at my set rate.. and anything that came in as
-- income that's gotten changed doesn't.. ALWAYS." Excluded income
-- is not income at all, so its charity must be deducted the same
-- way a reclassification away from income deducts it.
--
-- v3 FIX: the trigger now fires AFTER UPDATE OF kind, excluded,
-- and the function gains two directions:
--   * EXCLUDE: when excluded flips false -> true, any active
--     charity_income row linked to the transaction is set to
--     status='reversed' (same append-only reversal as the
--     reclassify-away direction, same audit row). No kind / state /
--     date guards: the UPDATE only touches an ACTIVE accrual, and
--     such a row exists only if charity was actually accrued.
--   * RESTORE: when excluded flips true -> false and the row is
--     income (verified, dated on/after 2026-11-01), a NEW active
--     accrual is inserted (same formula as the TO-income direction).
--     The old row stays 'reversed'; the partial unique index only
--     covers active rows, so no conflict. This mirrors the
--     income -> transfer -> income round trip.
--   Exclusion wins over a kind change in the same statement:
--   an excluded row accrues nothing regardless of its kind.
--
-- ONE-TIME REPAIR (in this file, after the trigger): the two live
-- rows were ALREADY excluded before v3 existed, so no future UPDATE
-- will fire the trigger for them. The repair reverses every ACTIVE
-- accrual linked to a currently-excluded transaction (any household,
-- any kind — excluded means not counted), with a matching audit row
-- per reversal. Idempotent: only status='active' rows are touched,
-- so re-running it is a no-op. Applying this file live reverses the
-- two rows' accruals ($300 + $100) and the Tzedaka Total returns
-- from $1,522.37 to $1,122.37. The app-side feed filter (build 55,
-- CharityIncome.visibleIncomeRows) hides the rows from the
-- Activity & Transactions list once their transactions are excluded.
--
-- v2 (Nov 20, 2026): adds the REVERSE direction (owner decision
-- Nov 20 ~11:26).
--
-- v2 ROOT CAUSE (SQL-verified, read-only): two income rows
-- (+$415.57 and +$308.06, "ONLINE TRANSFER / PAYMENT: CREDIT",
-- card ••1636) never accrued their 10% charity (~$72.37) because
-- they arrived as transfers and the owner later reclassified them
-- to Income.
--   * At ingest, plaid-sync's accrueCharityForIncomeTx returns early
--     unless kind = 'income' (canonical.ts:471), and both rows arrived
--     already verified (posted), so no pending→posted transition could
--     trigger it later.
--   * reclassify_transaction (05-transaction-mutation-rpcs.sql:166–198)
--     only updates kind + writes an audit row; it never calls any
--     charity accrual. No future sync fixes it (already verified).
--   * The negative stored amount is NOT the cause: the accrual RPC
--     handles the sign with abs() ("Income rows store negative cents;
--     the ledger stores positive").
-- The $3,500 check deposit worked because it was classified income AT
-- INGEST. The gap is reclassification-to-income, and only that.
--
-- v2 FIX: a trigger on transactions AFTER UPDATE OF kind, in BOTH
-- directions (single trigger, single function, branching on
-- direction):
--   * TO income: when kind changes TO 'income' (verified, not
--     excluded, dated on/after 2026-11-01), it inserts the
--     charity_income row with the SAME formula and conventions as
--     accrue_charity_for_transaction (charity-auto-accrue.sql,
--     build 44): amount = abs(amount_cents), rate from
--     charity_settings.default_rate_bp (default 1000 = 10%),
--     committed half-up ((amount * rate + 5000) / 10000), note
--     'Auto-accrued from synced income', transaction_id linked, ON
--     CONFLICT (household_id, transaction_id) WHERE status = 'active'
--     DO NOTHING, plus the matching audit_log row (actor NULL,
--     actor_name 'auto-accrual', action 'Charity income auto-accrued').
--   * AWAY from income (owner decision Nov 20 ~11:26): when kind
--     changes FROM 'income' to anything else, any charity accrued
--     from that income is deducted from the amount owed: the active
--     charity_income row linked to this transaction is set to
--     status='reversed' (append-only; the row stays as a record and
--     no longer counts toward the committed total), plus the matching
--     audit_log row (actor NULL, actor_name 'auto-accrual', action
--     'Charity income reversed'). No replacement row is created, so
--     replaces_id stays NULL — unlike correct_charity_income, which
--     reverses AND replaces. The reversal is scoped to this
--     household + this transaction_id + status='active', so it is
--     idempotent and can never touch another household's rows.
--   * Re-accrual on return to income is intended: income → transfer
--     (accrual reversed) → income again creates a NEW active
--     charity_income row, because the ON CONFLICT partial unique
--     index only covers status='active' rows and the old row is now
--     status='reversed' (so no conflict). The income is real again,
--     so the charity is owed again.
--
-- WHY A TRIGGER (not a call from reclassify_transaction): the RPC
-- raises unless auth.role() = 'service_role', and
-- reclassify_transaction runs as the authenticated admin, so it
-- cannot call the RPC. The trigger function is SECURITY DEFINER, so
-- it runs as the function owner — bypassing the charity_income RLS,
-- which has no INSERT policy for authenticated users — and it catches
-- a kind-change from ANY client/path, not just the app's reclassify.
-- The trigger function duplicates the RPC's insert logic; it does
-- NOT call the RPC, because auth.role() inside a trigger fired by an
-- authenticated session is 'authenticated', not 'service_role'.
-- The same reasoning covers exclude_transaction / restore_transaction:
-- both run as the authenticated admin and cannot call the RPC, and
-- the trigger catches an excluded flip from ANY path (including the
-- dedupe merge paths, which exclude the duplicate row directly).
--
-- WHAT THIS DOES NOT DO:
--   * It does NOT backfill the two CHEDER credits (122d11a3,
--     cbfb3565). Those rows are ALREADY kind='income', so this
--     trigger will never fire for them. Their ~$72.37 is backfilled
--     separately via accrue_charity_for_transaction (the RPC). This
--     trigger covers FUTURE reclassifications only.
--   * It does NOT change the ingest path. Plaid-sync / gmail-poll /
--     ingest-amex-alert accrual is untouched; this trigger only adds
--     the reclassification + exclusion paths.
--   * It does NOT double-accrue an ingest-accrued row. The WHEN
--     clause requires OLD.kind <> 'income', so an income→income
--     update (or any update where the row was already income) never
--     fires, and ON CONFLICT DO NOTHING is a second guard if a row
--     somehow already has an active accrual.
--
-- v1 → v2 NOTE: v1 (TO-income only) was applied live Nov 20, 2026
-- as function accrue_charity_on_reclassify_to_income() + trigger
-- trg_accrue_charity_on_reclassify_to_income. v2 renames both to
-- neutral names (sync_charity_on_reclassify /
-- trg_sync_charity_on_reclassify) because the function now also
-- reverses. Applying this file drops the v1 trigger and function
-- first, so exactly one trigger fires afterwards. The v1 live
-- application used verbatim SQL (not this file), so editing this
-- file does not interfere with it.
--
-- v2 → v3 NOTE: v3 keeps the v2 function and trigger names
-- (sync_charity_on_reclassify / trg_sync_charity_on_reclassify) and
-- only widens the trigger event to UPDATE OF kind, excluded, so
-- re-applying this file is a plain CREATE OR REPLACE + DROP/CREATE
-- TRIGGER. The v2 live application is replaced in place.
--
-- FAIL-OPEN: the trigger function catches any unexpected error,
-- raises a WARNING (visible in the Supabase Postgres logs), and
-- returns NULL so the reclassification / exclusion / restoration
-- itself NEVER fails because of an accrual problem. This matches
-- the build-44 accrual hook's fail-open philosophy (the edge
-- functions log and continue). A missed accrual is detectable: an
-- income row with no active charity_income row (see the detection
-- query at the end). A missed reversal is likewise detectable: an
-- active accrual linked to a transaction that is no longer income
-- or is excluded (see the second query).
--
-- IDEMPOTENT: CREATE OR REPLACE for the function, DROP TRIGGER IF
-- EXISTS before CREATE TRIGGER (for both the new name and the v1
-- name). Re-applying this file is safe. The one-time repair only
-- touches status='active' rows, so re-running it is a no-op.
--
-- PREREQUISITE (verify before applying live): the
-- charity_income.transaction_id column and the partial unique index
-- charity_income_household_transaction_uidx must exist (applied with
-- build 44). Verify:
--   select column_name from information_schema.columns
--     where table_name = 'charity_income' and column_name = 'transaction_id';
--   select indexname from pg_indexes
--     where indexname = 'charity_income_household_transaction_uidx';
--   select proname from pg_proc where proname = 'accrue_charity_for_transaction';
-- Expected: the column exists, the index exists, the RPC exists.
-- APPLY via the Supabase dashboard SQL Editor (project "Budget",
-- ref tnkhvdkmwmwiogiienee). No Edge Function redeploy, no iOS
-- change. Does not block build 55 (server-side only, plus the
-- build-55 app-side feed filter).

create or replace function public.sync_charity_on_reclassify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rate integer;
  v_amount integer;
  v_committed bigint;
  v_id uuid;
  v_do_accrue boolean := false;
  v_do_reverse boolean := false;
  v_cause text;
begin
  -- Decide the direction from the transition. Excluded transitions
  -- are checked first: exclusion wins over a kind change in the same
  -- statement, because an excluded row accrues nothing regardless
  -- of its kind.
  if coalesce(NEW.excluded, false) and not coalesce(OLD.excluded, false) then
    -- v3: the row became excluded -> charity no longer owed.
    v_do_reverse := true;
    v_cause := 'excluded';
  elsif coalesce(OLD.excluded, false) and not coalesce(NEW.excluded, false) and NEW.kind = 'income' then
    -- v3: the row was restored and is income -> charity owed again.
    v_do_accrue := true;
  elsif NEW.kind = 'income' and OLD.kind is distinct from 'income' then
    -- v2: kind changed TO income -> accrue.
    v_do_accrue := true;
  elsif OLD.kind = 'income' and NEW.kind is distinct from 'income' then
    -- v2: kind changed AWAY from income -> reverse.
    v_do_reverse := true;
    v_cause := 'reclassified away from income';
  else
    return null;
  end if;

  -- Accrue: TO income, or restored to income. The guards are
  -- re-checked here so a direct invocation cannot accrue wrongly.
  -- Logic unchanged from v2.
  if v_do_accrue then
    if NEW.state <> 'verified' then return null; end if;
    if coalesce(NEW.excluded, false) then return null; end if;
    if NEW.date < date '2026-11-01' then return null; end if;
    select default_rate_bp into v_rate from public.charity_settings where household_id = NEW.household_id;
    v_rate := coalesce(v_rate, 1000);
    -- Income rows store negative cents; the ledger stores positive.
    v_amount := abs(NEW.amount_cents);
    if v_amount <= 0 then return null; end if;
    -- P2-B14: bigint product — the int4 product overflows above ~$21.5k
    -- of income at the 10% default rate (see r13-charity.sql header).
    v_committed := (v_amount::bigint * v_rate + 5000) / 10000;
    begin
      insert into public.charity_income
        (household_id, source_label, amount_cents, income_date, rate_bp, note, transaction_id, created_by)
      values (NEW.household_id,
              coalesce(nullif(btrim(NEW.merchant), ''), 'Income'),
              v_amount, NEW.date, v_rate, 'Auto-accrued from synced income', NEW.id, null)
      on conflict (household_id, transaction_id) where status = 'active' do nothing
      returning id into v_id;
    exception when others then
      -- Fail open: never break the reclassification / restoration
      -- because the accrual failed. The WARNING is visible in the
      -- Postgres logs.
      raise warning 'reclassify-income-accrual: accrual failed for transaction % (%): %', NEW.id, NEW.merchant, SQLERRM;
      return null;
    end;
    if v_id is null then
      -- Already accrued (race, or an ingest-accrued row reclassified
      -- back to income): no duplicate, no second audit row.
      return null;
    end if;
    begin
      insert into public.audit_log (household_id, actor, actor_name, action, detail)
      values (NEW.household_id, null, 'auto-accrual', 'Charity income auto-accrued',
              'Income ' || NEW.merchant || ' ' || v_amount::text || ' cents on ' || NEW.date::text
              || ' at ' || v_rate::text || ' basis points commits ' || v_committed::text || ' cents to charity.');
    exception when others then
      -- The accrual already landed; a failed audit row must not undo
      -- it. The WARNING is visible in the Postgres logs.
      raise warning 'reclassify-income-accrual: audit row failed for transaction %: %', NEW.id, SQLERRM;
    end;
    return null;
  end if;

  -- Reverse: AWAY from income, or excluded. The active
  -- charity_income row linked to this transaction is set to
  -- status='reversed' (append-only; the row stays as a record and
  -- no longer counts toward the committed total). No replacement
  -- row is created, so replaces_id stays NULL — unlike
  -- correct_charity_income, which reverses AND replaces. No state /
  -- excluded / date guards here: the UPDATE only touches an ACTIVE
  -- accrual row if one exists for this transaction, and such a row
  -- exists only if charity was actually accrued from it. If there is
  -- no active row (it never accrued, or it was already reversed),
  -- the UPDATE affects 0 rows and the function no-ops.
  if v_do_reverse then
    begin
      -- At most one row can match: the partial unique index
      -- charity_income_household_transaction_uidx allows only one
      -- ACTIVE accrual per (household_id, transaction_id).
      update public.charity_income
         set status = 'reversed'
       where household_id = NEW.household_id
         and transaction_id = NEW.id
         and status = 'active'
      returning id, amount_cents, rate_bp into v_id, v_amount, v_rate;
    exception when others then
      -- Fail open: never break the reclassification / exclusion
      -- because the reversal failed. The WARNING is visible in the
      -- Postgres logs.
      raise warning 'reclassify-income-accrual: reversal failed for transaction % (%): %', NEW.id, OLD.merchant, SQLERRM;
      return null;
    end;
    if v_id is null then
      -- No active accrual for this transaction (it never accrued:
      -- provisional, excluded, or pre-Nov at ingest — or it was
      -- already reversed). Nothing to deduct, nothing to audit.
      return null;
    end;
    v_committed := (v_amount::bigint * v_rate + 5000) / 10000;
    begin
      insert into public.audit_log (household_id, actor, actor_name, action, detail)
      values (NEW.household_id, null, 'auto-accrual', 'Charity income reversed',
              'Income ' || OLD.merchant || ' ' || v_amount::text || ' cents on ' || OLD.date::text
              || ' at ' || v_rate::text || ' basis points was ' || v_cause || '; '
              || v_committed::text || ' cents deducted from charity owed.');
    exception when others then
      -- The reversal already landed; a failed audit row must not undo
      -- it. The WARNING is visible in the Postgres logs.
      raise warning 'reclassify-income-accrual: audit row failed for reversal of transaction %: %', NEW.id, SQLERRM;
    end;
    return null;
  end if;

  return null;
end;
$$;

-- Replace the v1 (TO-income-only) trigger and function, and widen
-- the v2 trigger to also fire on excluded flips. The v1 names are
-- dropped first so exactly one trigger fires after this file is
-- applied. The old function is dropped after its trigger, because a
-- function with a dependent trigger cannot be dropped.
drop trigger if exists trg_accrue_charity_on_reclassify_to_income on public.transactions;
drop function if exists public.accrue_charity_on_reclassify_to_income();
drop trigger if exists trg_sync_charity_on_reclassify on public.transactions;
create trigger trg_sync_charity_on_reclassify
  after update of kind, excluded on public.transactions
  for each row
  when (
    -- TO income: kind changes to income (verified, not excluded,
    -- dated on/after 2026-11-01). The guards are re-checked inside
    -- the function; repeating them here keeps the trigger from firing
    -- at all for rows that can never accrue.
    (NEW.kind = 'income'
      and OLD.kind is distinct from 'income'
      and NEW.state = 'verified'
      and not coalesce(NEW.excluded, false)
      and NEW.date >= date '2026-11-01')
    -- FROM income: kind changes away from income. No state /
    -- excluded / date guards: the reversal only touches an ACTIVE
    -- accrual row linked to this transaction, and such a row exists
    -- only if charity was actually accrued from it.
    or (OLD.kind = 'income' and NEW.kind is distinct from 'income')
    -- v3: excluded flips either way (exclude -> reverse, restore
    -- -> re-accrue for income rows). The function decides which.
    or (NEW.excluded is distinct from OLD.excluded)
  )
  execute function public.sync_charity_on_reclassify();

-- =====================================================================
-- ONE-TIME REPAIR (v3, Nov 22, 2026) — run once with this file.
--
-- The two live rows (Yehoshua Friedman +$3,000.00, Avraham Friedman
-- +$1,000.00) were ALREADY excluded before v3 existed, so no future
-- UPDATE will fire the trigger for them. This block reverses every
-- ACTIVE accrual linked to a currently-excluded transaction, with a
-- matching audit row per reversal — the same reversal the trigger
-- now does on exclude, applied to the rows that predate it. It
-- enforces the invariant for any household in the database (live +
-- test): an excluded transaction's charity must not count.
-- Idempotent: only status='active' rows are touched, so re-running
-- this block is a no-op. After it runs, the live Tzedaka Total
-- returns from $1,522.37 to $1,122.37 ($300 + $100 deducted).
-- =====================================================================
do $$
declare
  r record;
  v_committed bigint;
begin
  for r in
    select c.id as charity_id, c.household_id, c.amount_cents, c.rate_bp,
           t.merchant, t.date
      from public.charity_income c
      join public.transactions t on t.id = c.transaction_id
     where c.status = 'active'
       and t.excluded = true
  loop
    update public.charity_income
       set status = 'reversed'
     where id = r.charity_id;
    v_committed := (r.amount_cents::bigint * r.rate_bp + 5000) / 10000;
    insert into public.audit_log (household_id, actor, actor_name, action, detail)
    values (r.household_id, null, 'auto-accrual', 'Charity income reversed',
            'Income ' || r.merchant || ' ' || r.amount_cents::text || ' cents on ' || r.date::text
            || ' at ' || r.rate_bp::text || ' basis points was excluded; '
            || v_committed::text || ' cents deducted from charity owed.');
  end loop;
end $$;

-- =====================================================================
-- VERIFICATION (commented — run manually after applying, on a TEST
-- household first, then spot-check live). Replace <household> with
-- the test household id (Goldstein, 95e1aff3-f664-41bb-be09-70e00f75a141)
-- and <txn> with a test transaction id.
--
-- Setup (test household, as an admin): pick or create a VERIFIED,
-- non-excluded transfer dated on/after 2026-11-01, e.g. a $100.00
-- credit stored as amount_cents = -10000. Confirm it has no accrual:
--   select id from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--      and status = 'active';  -- expect 0 rows
--
-- TO-INCOME DIRECTION
--
-- 1. Reclassify the transfer to income:
--   select reclassify_transaction('<txn>', 'income', 'trigger test');
--   select source_label, amount_cents, income_date, rate_bp, status, note, transaction_id
--     from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>';
--   -- Expect exactly 1 row: amount_cents 10000, rate_bp 1000,
--   -- status 'active', note 'Auto-accrued from synced income',
--   -- committed (amount_cents * rate_bp + 5000) / 10000 = 1000 cents.
--   select action, detail from audit_log
--    where household_id = '<household>' order by created_at desc limit 2;
--   -- Expect 'Transaction reclassified' AND 'Charity income auto-accrued'.
--
-- 2. No double-accrue on income→income (same kind re-applied):
--   select reclassify_transaction('<txn>', 'income', 'trigger test 2');
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--      and status = 'active';  -- expect 1
--
-- AWAY-FROM-INCOME DIRECTION (owner decision Nov 20, 2026)
--
-- 3. Reclassify the income row away to transfer: the accrual reverses.
--   select reclassify_transaction('<txn>', 'transfer', 'trigger test 3');
--   select id, status, amount_cents, rate_bp, replaces_id from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>';
--   -- Expect exactly 1 row, now status 'reversed' (amount_cents
--   -- 10000, rate_bp 1000, replaces_id NULL — no replacement row).
--   -- The committed total for the household drops by 1000 cents.
--   select action, detail from audit_log
--    where household_id = '<household>' order by created_at desc limit 2;
--   -- Expect 'Transaction reclassified' AND 'Charity income reversed'.
--
-- 4. Reclassify away twice: still exactly one reversed row, no error.
--   select reclassify_transaction('<txn>', 'transfer', 'trigger test 4');
--   -- (The trigger does not fire: OLD.kind is already 'transfer'.)
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--      and status = 'reversed';  -- expect 1
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--      and status = 'active';  -- expect 0
--
-- 5. Round trip income→transfer→income: re-accrual creates a NEW row.
--   select reclassify_transaction('<txn>', 'income', 'trigger test 5');
--   select id, status from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--    order by created_at;
--   -- Expect 2 rows: the first (from step 1) status 'reversed', and
--   -- a NEW row (different id) status 'active', amount_cents 10000,
--   -- rate_bp 1000, committed 1000 cents. The committed total is
--   -- restored to what it was after step 1. This is intended: the
--   -- income is real again, so the charity is owed again.
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--      and status = 'active';  -- expect 1
--
-- 6. Reversing an income row that never accrued is a no-op (no error,
--    no reversal audit row, no reversed row):
--   -- Reclassify a PROVISIONAL transfer to income, then back to
--   -- transfer. The TO-income step accrues nothing (verified-only
--   -- guard), so the away step has no active row to reverse:
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<provisional-txn>'
--      and status = 'active';  -- expect 0
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<provisional-txn>'
--      and status = 'reversed';  -- expect 0
--
-- EXCLUDE / RESTORE DIRECTIONS (v3, owner decision Nov 22, 2026)
--
-- 7. Exclude the income row: the accrual reverses (the v3 fix).
--   -- Start from the active accrual left by step 5 (or re-run step 1
--   -- on a fresh transfer first). Then:
--   select exclude_transaction('<txn>', 'trigger test exclude');
--   select id, status, amount_cents, rate_bp from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--    order by created_at;
--   -- Expect the active row now status 'reversed' (no new row).
--   -- The committed total for the household drops by 1000 cents.
--   select action, detail from audit_log
--    where household_id = '<household>' order by created_at desc limit 2;
--   -- Expect 'Transaction excluded' AND 'Charity income reversed'
--   -- (detail says the income "was excluded").
--
-- 8. Exclude twice: still exactly one reversed row, no error.
--   -- (exclude_transaction is idempotent; the trigger fires again
--   -- on the second call but finds no active row to reverse.)
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--      and status = 'reversed';  -- expect 1
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--      and status = 'active';  -- expect 0
--
-- 9. Restore the excluded income row: a NEW active accrual appears.
--   select restore_transaction('<txn>');
--   select id, status from charity_income
--    where household_id = '<household>' and transaction_id = '<txn>'
--    order by created_at;
--   -- Expect 3 rows now: the step-1 row (reversed), the step-5 row
--   -- (reversed by step 7), and a NEW row (different id) status
--   -- 'active', amount_cents 10000, rate_bp 1000. The committed
--   -- total is restored by 1000 cents. (If the row restores as
--   -- provisional — dated today or later — no accrual appears until
--   -- it posts; that is the verified-only guard, not a failure.)
--   select action, detail from audit_log
--    where household_id = '<household>' order by created_at desc limit 2;
--   -- Expect 'Transaction restored' AND 'Charity income auto-accrued'.
--
-- 10. Exclude a row that never accrued is a no-op (no error, no
--     reversal audit row, no reversed row):
--   -- Exclude a PROVISIONAL transfer (never income, never accrued):
--   select exclude_transaction('<provisional-txn>', 'trigger test 10');
--   select count(*) from charity_income
--    where household_id = '<household>' and transaction_id = '<provisional-txn>'
--      and status = 'reversed';  -- expect 0
--
-- 11. Re-apply is safe (idempotent):
--   -- Run this whole file again in the SQL editor; it must succeed
--   -- with no error, and exactly one trigger must exist:
--   select tgname from pg_trigger
--    where tgname in ('trg_sync_charity_on_reclassify',
--                     'trg_accrue_charity_on_reclassify_to_income');
--   -- Expect 1 row: trg_sync_charity_on_reclassify only. The v1
--   -- trigger must be gone. The repair block must report 0 rows
--   -- affected on the second run (nothing left to reverse).
--
-- BEFORE APPLYING LIVE (in addition to the prerequisite checks in
-- the header): run steps 1–11 on the TEST household (Goldstein,
-- 95e1aff3-f664-41bb-be09-70e00f75a141) and confirm every expected
-- count. Then apply live via the dashboard SQL editor and spot-check
-- that the trigger exists (step 11's query) and that the two live
-- rows' accruals reversed (the repair): 
--   select c.id, c.source_label, c.amount_cents, c.status
--     from charity_income c join transactions t on t.id = c.transaction_id
--    where c.household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
--      and t.merchant in ('Yehoshua Friedman', 'Avraham Friedman');
--   -- Expect both rows status 'reversed'. The Tzedaka Total in the
--   -- app should then read $1,122.37 again. After applying live, a
--   missed accrual (e.g. a trigger WARNING in the Postgres logs) is
--   detectable with:
--   select t.id, t.merchant, t.amount_cents from transactions t
--    where t.household_id = '<household>' and t.kind = 'income'
--      and t.state = 'verified' and not coalesce(t.excluded, false)
--      and t.date >= date '2026-11-01'
--      and not exists (select 1 from charity_income c
--                       where c.household_id = t.household_id
--                         and c.transaction_id = t.id and c.status = 'active');
--   -- Expect 0 rows (every verified, non-excluded income dated
--   -- on/after Nov 1 has an active accrual). Any row returned is a
--   -- missed accrual to backfill via accrue_charity_for_transaction.
--   -- A missed REVERSAL (an income row that left income or was
--   -- excluded but still has an active accrual) is detectable with:
--   select c.id, c.source_label, c.amount_cents from charity_income c
--    where c.household_id = '<household>' and c.status = 'active'
--      and c.transaction_id is not null
--      and exists (select 1 from transactions t
--                   where t.id = c.transaction_id
--                     and (t.kind <> 'income' or t.excluded = true));
--   -- Expect 0 rows (no active accrual is linked to a transaction
--   -- that is no longer income or is excluded). Any row returned is
--   -- a missed reversal to fix by setting status='reversed'.
