-- TOIREMORG correction (build 30, item H) — apply via the
-- Supabase SQL editor. NOT applied from here (no live access).
--
-- WHAT IS WRONG: the Resolved Duplicates list shows
-- "TOIREMORG / TOIREMORG CHARITY — Merged · Nov 12, 2026". That
-- contradicts the owner's ruling (Nov 3, 2026): the bank
-- "TOIREMORG" $2 row and the email "TOIREMORG CHARITY" $2 row are
-- TWO REAL GIFTS, not a duplicate. Both stay counted; no merge, no
-- exclusion. The Nov 12 reconciliation merged the pair and excluded
-- one $2 row to Trash (only the email row stayed visible).
--
-- WHAT THIS FILE DOES (real household only,
-- 647d1f23-606f-43af-92e5-1de2f1f34377):
--   1. Restores the excluded $2 row from Trash via
--      restore_transaction (the proper undo for a merged pair).
--   2. Flips the candidate from 'merged' to 'separate' with a
--      correction note.
--   3. Drops any merchant alias the merge taught for this pair, so
--      the pair is not treated as the same merchant going forward.
--   4. Writes one audit_log row.
--
-- WHY THE BACKFILL: restore_transaction (n4) refuses a row whose
-- pre_exclusion_state is null ('cannot restore: no prior state
-- recorded') — and the merge RPC never snapshotted it (fixed for
-- future merges in dedupe-review-queue.sql and
-- auto-merge-bank-email.sql, build 30). The Nov 12 merge left the
-- snapshot null, so this file backfills it from the date rule
-- (a past-dated row had posted: 'verified') before restoring.
-- The backfill only runs when the snapshot is null.
--
-- HOW TO RUN (parent, SQL editor, project "Budget"):
--   1. Run STEP 1 (read-only) and check the output matches the
--      expectation: one 'merged' candidate, one of its two $2 rows
--      excluded. If the state differs, STOP and look — do not run
--      Step 2 blind.
--   2. Run STEP 2 (the correction). It is idempotent: a second
--      run notices the candidate is already 'separate' and no-ops.
--   3. Run STEP 3 (verify): both $2 rows counted, candidate
--      'separate', no alias left.
-- Run as the owner (JWT simulation, one set_config per run):
--   select set_config('request.jwt.claims',
--     '{"sub":"9f500062-2ade-4021-aa92-9bb47a3d8041","role":"authenticated","aud":"authenticated"}', true);

-- ============ STEP 1 — read-only investigation ============
select id, canonical_transaction_id, duplicate_transaction_id,
       merchant_a, merchant_b, status, resolution_note, resolved_at
from duplicate_candidates
where household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
  and merchant_a ilike '%TOIREMORG%'
  and merchant_b ilike '%TOIREMORG%';

select id, merchant, amount_cents, kind, source, date, state, excluded, pre_exclusion_state
from transactions
where household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
  and merchant ilike '%TOIREMORG%'
order by date;

select household_id, name_a, name_b
from merchant_aliases
where household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
  and (name_a ilike '%TOIREMORG%' or name_b ilike '%TOIREMORG%');

-- ============ STEP 2 — correction (run after Step 1 checks out) ============
do $$
declare
  v_cand duplicate_candidates%rowtype;
  v_dup transactions%rowtype;
  v_state text;
begin
  select * into v_cand from duplicate_candidates
   where household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
     and merchant_a ilike '%TOIREMORG%'
     and merchant_b ilike '%TOIREMORG%';
  if not found then
    raise notice 'No TOIREMORG candidate in the real household — nothing to correct.';
    return;
  end if;
  if v_cand.status = 'separate' then
    raise notice 'TOIREMORG candidate % is already separate — correction already applied.', v_cand.id;
    return;
  end if;
  if v_cand.status <> 'merged' then
    raise exception 'TOIREMORG candidate % has unexpected status % — stop and look, do not correct blind.', v_cand.id, v_cand.status;
  end if;
  select * into v_dup from transactions where id = v_cand.duplicate_transaction_id;
  -- 1. Restore the excluded row from Trash.
  if v_dup.excluded or v_dup.state = 'excluded' then
    if v_dup.pre_exclusion_state is null then
      v_state := case when v_dup.date < (now() at time zone 'America/New_York')::date
                      then 'verified' else 'provisional' end;
      update transactions set pre_exclusion_state = v_state where id = v_dup.id;
    end if;
    perform restore_transaction(v_dup.id);
  end if;
  -- 2. Flip the resolution from merged to separate.
  update duplicate_candidates
     set status = 'separate',
         resolved_at = now(),
         resolved_by = auth.uid(),
         resolution_note = 'Correction Nov 15, 2026: the $2 bank row and $2 email row are two real gifts, not a duplicate (owner ruling Nov 3, 2026). The merged resolution was wrong; the excluded row was restored from Trash.'
   where id = v_cand.id;
  -- 3. Drop any alias the merge taught for this pair.
  delete from merchant_aliases
   where household_id = v_cand.household_id
     and ((upper(name_a) = 'TOIREMORG' and upper(name_b) = 'TOIREMORG CHARITY')
       or (upper(name_a) = 'TOIREMORG CHARITY' and upper(name_b) = 'TOIREMORG'));
  -- 4. Audit.
  insert into audit_log (household_id, actor, actor_name, action, detail)
  values (v_cand.household_id, auth.uid(), 'admin', 'Duplicate resolution corrected',
          'TOIREMORG / TOIREMORG CHARITY $2 pair corrected from merged to separate: two real gifts, not a duplicate (owner ruling Nov 3, 2026). The excluded row (' || v_dup.id::text || ') was restored from Trash.');
  raise notice 'Corrected TOIREMORG candidate %: restored % and marked separate.', v_cand.id, v_dup.id;
end $$;

-- ============ STEP 3 — verify ============
select id, merchant_a, merchant_b, status, resolution_note, resolved_at
from duplicate_candidates
where household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
  and merchant_a ilike '%TOIREMORG%'
  and merchant_b ilike '%TOIREMORG%';

select id, merchant, amount_cents, kind, source, date, state, excluded
from transactions
where household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
  and merchant ilike '%TOIREMORG%'
order by date;
-- Expect: TWO $2 rows, both excluded = false, candidate status = 'separate'.
