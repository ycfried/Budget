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
-- excluded=true). "Best" = prefer source 'plaid' (the bank row is
-- authoritative), then state 'verified', then earliest created_at.
-- Excluding a row fires the charity trigger
-- (reclassify-income-accrual.sql): if the excluded row had an
-- active charity accrual, it reverses — so the Tzedaka total drops
-- by exactly the duplicate's share. Refund links pointing at an
-- excluded row are re-pointed at the kept row (best-effort, via
-- repoint_refund_links; a missing function never fails the
-- cleanup). One audit_log row is written per excluded row.
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
    -- Exclude every other live row in the group.
    for v_dup in
      select id, merchant, amount_cents, kind
        from public.transactions
       where household_id = p_household_id
         and dedupe_hash = v_group.dedupe_hash
         and excluded = false
         and state not in ('excluded', 'reversed')
         and id <> v_keep_id
    loop
      update public.transactions
         set state = 'excluded', excluded = true
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
