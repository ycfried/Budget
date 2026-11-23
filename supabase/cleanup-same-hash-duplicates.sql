-- cleanup-same-hash-duplicates.sql — Nov 22, 2026 (build 58).
--
-- PURPOSE (owner, Nov 22 ~12:21: "The code/system should
-- automatically pick this up and avoid it from showing up to begin
-- with"): two Amazon pairs in the live household were the SAME
-- alert ingested twice — both rows source amex_alert, state
-- provisional, IDENTICAL dedupe_hash ($44.96 Nov 22, $10.59
-- Nov 21, card ••1005), no bank row. The ingestion guard (build 58,
-- canonical.ts findExistingSameHash, wired into gmail-poll and
-- ingest-amex-alert) stops new ones. This file cleans up any that
-- already exist.
--
-- WHAT IT DOES: cleanup_same_hash_duplicates(p_household_id) finds
-- every dedupe_hash group in the household with MORE THAN ONE live
-- row (excluded = false, state not 'excluded' / 'reversed'), keeps
-- the best row per group, and excludes the rest (state='excluded',
-- excluded=true, with a pre_exclusion_state snapshot so a normal
-- restore works). "Best" = prefer source 'plaid' (the bank row is
-- authoritative), then state 'verified', then earliest created_at.
-- Excluding a row fires the charity trigger
-- (reclassify-income-accrual.sql): if the excluded row had an
-- active charity accrual, it reverses — so the Tzedaka total drops
-- by exactly the duplicate's share. Refund links pointing at an
-- excluded row are re-pointed at the kept row (best-effort, via
-- repoint_refund_links; a missing function never fails the
-- cleanup). One audit_log row is written per excluded row.
--
-- F-3 (build 61 audit, Nov 23, 2026) — RESTRICTED TO REAL
-- DUPLICATES ONLY. Before this fix the cleanup grouped by hash
-- with no source guard: two genuinely identical real purchases
-- (same merchant/date/amount/card) share a hash BY DESIGN, yet the
-- cleanup excluded one of them — and because it excluded via a
-- direct UPDATE with no pre_exclusion_state snapshot, the normal
-- restore refused ("cannot restore: no prior state recorded") and
-- the only path was force_restore_transaction, which flips the row
-- to source='restored' + verified — wrong for a wrongly-excluded
-- duplicate (bank row still live -> double-count if restored).
--   The group is now cleaned ONLY when it is a real duplicate:
--   * a bank row ANCHORS the group (at least one live Plaid row)
--     and every other live row is an email alert (amex_alert /
--     chase_alert) — the alert rows are excluded, the bank row(s)
--     kept. Two Plaid rows + an alert: the alert is excluded, BOTH
--     bank rows are kept (two real purchases);
--   * OR same-alert-twice: no bank row, at least two live email
--     rows — the best email row is kept, the rest excluded.
--   Any group with a manual / csv / restored row in it is SKIPPED
--   entirely (hand-entered and restored rows are never auto-excluded;
--   an admin reviews them). A group of two Plaid rows and no alert
--   is skipped: two real purchases, leave them.
--   Only EMAIL rows are ever excluded by this function — a second
--   Plaid row is never excluded, even inside a cleaned group.
--   Every exclusion now snapshots pre_exclusion_state (like
--   merge_bank_email_pair in auto-merge-bank-email.sql) and stores
--   an exclude_reason, so a wrongly-excluded row restores normally
--   from Trash via restore_transaction.
--
-- SAFETY:
--   * TOIREMORG is untouched: the bank "TOIREMORG" $2 and email
--     "TOIREMORG CHARITY" $2 gifts have DIFFERENT merchants, hence
--     different dedupe_hashes, so they are never in one group.
--     (Owner ruling Nov 3: two separate real gifts, never merge.)
--   * Bank+email pairs are handled the same way the merge does: a
--     group containing a Plaid row keeps the Plaid row and excludes
--     the email row. This does not change the bank+email dedupe
--     rule; it applies the same outcome to groups the merge has
--     not yet processed.
--   * Linked transactions are never stranded: a refund linked to an
--     excluded row is re-pointed at the kept row (same rule as the
--     dedupe safeguards — a refund must never be left linked to an
--     excluded charge).
--   * Append-only: nothing is deleted, only excluded. An excluded
--     row can be restored from Trash.
--   * Idempotent: re-running finds no group with more than one live
--     row, so it returns (0, 0) and changes nothing.
--
-- APPLY: run this file in the Supabase dashboard SQL Editor
-- (project "Budget", ref tnkhvdkmwmwiogiienee) to CREATE the
-- function. Then run it for a household:
--   select * from cleanup_same_hash_duplicates('647d1f23-606f-43af-92e5-1de2f1f34377');
-- (Live household id above; test household "Goldstein" is
-- 95e1aff3-f664-41bb-be09-70e00f75a141.) Run it on the TEST
-- household first and confirm the counts, then live.
-- NOTE: the two known live pairs ($44.96 d38c3916/2a31499d and
-- $10.59 1b7a9ee3/40c5c1c9) were already removed by hand on
-- Nov 22 ~12:28 (the extra row of each pair deleted after a clean
-- link check), so a live run now should report (0, 0) unless new
-- same-hash groups have appeared since.
--
-- VERIFY (after running, test household first):
--   -- No live group still has more than one row:
--   select dedupe_hash, count(*) from transactions
--    where household_id = '<household>' and excluded = false
--      and state not in ('excluded', 'reversed')
--      and dedupe_hash is not null and dedupe_hash <> ''
--    group by dedupe_hash having count(*) > 1;
--   -- Expect 0 rows.
--   -- The excluded rows are visible in Trash and restorable:
--   select id, merchant, amount_cents, state, excluded from transactions
--    where household_id = '<household>' and excluded = true
--    order by created_at desc limit 10;
--
-- REGRESSION TEST (F-3, test household only — two identical REAL
-- purchases must survive, and a same-alert-twice pair must clean up
-- AND restore normally):
--   -- 1. Two identical real purchases: insert two live Plaid rows
--   --    with the SAME dedupe_hash (same merchant/date/amount/card,
--   --    different external_ids), then run the cleanup:
--   select * from cleanup_same_hash_duplicates('<household>');
--     -- expect: (0, 0) — both Plaid rows stay live.
--   select count(*) from transactions
--    where household_id = '<household>' and dedupe_hash = '<hash>'
--      and excluded = false;  -- expect: 2
--   -- 2. Same alert twice: two live amex_alert rows, same hash, no
--   --    bank row. Run the cleanup:
--   select * from cleanup_same_hash_duplicates('<household>');
--     -- expect: (1, 1) — one group cleaned, one row excluded.
--   select pre_exclusion_state, exclude_reason from transactions
--    where id = '<excluded-alert-row>';
--     -- expect: pre_exclusion_state = the row's prior state
--     -- ('provisional'), exclude_reason set — NOT null.
--   -- 3. The excluded alert restores NORMALLY (the old bug made
--   --    this refuse with 'cannot restore: no prior state recorded'):
--   select restore_transaction('<excluded-alert-row>');
--   select state, excluded from transactions
--    where id = '<excluded-alert-row>';
--     -- expect: state = the snapshotted prior state, excluded false.
--   -- Clean the throwaway rows up afterwards (exclude via
--   -- exclude_transaction, or delete the manual ones) so the test
--   -- household does not keep the fixture rows.

create or replace function public.cleanup_same_hash_duplicates(p_household_id uuid)
returns table (groups_cleaned integer, rows_excluded integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group record;
  v_keep_id uuid;
  v_dup record;
  v_groups integer := 0;
  v_excluded integer := 0;
  v_plaid integer;
  v_email integer;
  v_other integer;
begin
  -- One group per (household, dedupe_hash) with more than one live
  -- row. A null/empty hash cannot be a duplicate key: those rows are
  -- never grouped (they keep showing as-is).
  for v_group in
    select dedupe_hash
      from public.transactions
     where household_id = p_household_id
       and excluded = false
       and state not in ('excluded', 'reversed')
       and dedupe_hash is not null
       and dedupe_hash <> ''
     group by dedupe_hash
    having count(*) > 1
  loop
    -- F-3: real duplicates only. Count the group's sources: a group
    -- is cleaned only when every non-keeper row is an email alert —
    -- a bank row anchors it, or it is same-alert-twice. A group
    -- with a manual / csv / restored row is skipped outright, and
    -- a group with no email row at all (e.g. two Plaid rows: two
    -- real purchases) is skipped too — there is nothing safe to
    -- exclude in it.
    select count(*) filter (where source = 'plaid'),
           count(*) filter (where source in ('amex_alert', 'chase_alert')),
           count(*) filter (where source not in ('plaid', 'amex_alert', 'chase_alert'))
      into v_plaid, v_email, v_other
      from public.transactions
     where household_id = p_household_id
       and dedupe_hash = v_group.dedupe_hash
       and excluded = false
       and state not in ('excluded', 'reversed');
    if v_other > 0 or v_email = 0 then
      continue;
    end if;
    v_groups := v_groups + 1;
    -- Keep the best row: the bank row first (authoritative), then a
    -- verified row, then the earliest created. Deterministic
    -- tie-break on id so a re-run picks the same keeper.
    select id into v_keep_id
      from public.transactions
     where household_id = p_household_id
       and dedupe_hash = v_group.dedupe_hash
       and excluded = false
       and state not in ('excluded', 'reversed')
     order by
       case when source = 'plaid' then 0 else 1 end,
       case when state = 'verified' then 0 else 1 end,
       created_at asc,
       id asc
     limit 1;
    -- Exclude every other live EMAIL row in the group. Only email
    -- rows are ever excluded here (F-3): a second Plaid row is a
    -- second real purchase and is kept, even when the group also
    -- has an alert row to exclude.
    for v_dup in
      select id, merchant, amount_cents, kind, state
        from public.transactions
       where household_id = p_household_id
         and dedupe_hash = v_group.dedupe_hash
         and excluded = false
         and state not in ('excluded', 'reversed')
         and source in ('amex_alert', 'chase_alert')
         and id <> v_keep_id
    loop
      -- F-3: snapshot the prior state (like merge_bank_email_pair)
      -- so a normal restore_transaction works, and record why.
      update public.transactions
         set state = 'excluded', excluded = true,
             pre_exclusion_state = case when v_dup.state <> 'excluded' then v_dup.state else pre_exclusion_state end,
             exclude_reason = 'Same-hash duplicate excluded by cleanup_same_hash_duplicates'
       where id = v_dup.id;
      v_excluded := v_excluded + 1;
      -- Re-point any refund linked to this row at the kept row, so
      -- a refund is never left linked to an excluded charge
      -- (dedupe safeguard, Nov 20). Best-effort: a missing
      -- function (or any error) never fails the cleanup.
      begin
        perform public.repoint_refund_links(v_dup.id, v_keep_id);
      exception when others then
        raise warning 'cleanup_same_hash_duplicates: refund re-point failed for %: %', v_dup.id, SQLERRM;
      end;
      begin
        insert into public.audit_log (household_id, actor, actor_name, action, detail)
        values (p_household_id, null, 'auto-dedupe', 'Duplicate transaction excluded',
                'Same-source duplicate ' || v_dup.merchant || ' ' || v_dup.amount_cents::text
                || ' cents (kind ' || v_dup.kind || ') shares dedupe_hash with a kept row; excluded as a duplicate.');
      exception when others then
        raise warning 'cleanup_same_hash_duplicates: audit row failed for %: %', v_dup.id, SQLERRM;
      end;
    end loop;
  end loop;
  return query select v_groups, v_excluded;
end;
$$;
