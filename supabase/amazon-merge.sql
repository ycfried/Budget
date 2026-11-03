-- Amazon $10.59 confirmed merge — PREPARED ONLY, DO NOT APPLY
-- without the owner's explicit approval AND the timing decision
-- (merge now vs wait until the charge posts on Amex).
--
-- WHY: the owner's Nov 3 Amex screenshot proves the app's two
-- Pending $10.59 rows are ONE purchase ingested twice, not two:
--   * Plaid row: merchant 'AMAZON', source 'plaid' (canonical —
--     it receives the posted update when Amex posts it)
--   * Email row: merchant 'AMAZON MARKEPLACE NA PA',
--     source 'amex_alert' (linked evidence, excluded, NOT deleted)
-- The week currently counts $10.59 twice; this merge removes the
-- double-count immediately and is reversible (un-exclude the row).
--
-- PREREQUISITE: supabase/dedupe-review-queue.sql must already be
-- applied live (duplicate_candidates + merchant_aliases tables).
-- If it has not been, this whole transaction fails and changes
-- nothing — that is the safe failure, not a partial merge.
--
-- SAFETY: no household UUID and no transaction IDs are hardcoded.
-- The two rows are found by source + merchant + amount + date +
-- card suffix, and the transaction ABORTS unless exactly one row
-- matches each side, both are in the same household, neither is
-- already excluded, and no candidate already links the pair.
-- This file is deliberately specific to this issuer-confirmed
-- pair; it is NOT a general rule for same-date/same-amount pairs
-- (two genuinely identical purchases must stay separate).

-- Step 0 (read-only): show the two rows this file will act on.
select id, household_id, merchant, amount_cents, date, card_suffix, source, state, kind, excluded
  from transactions
 where amount_cents = 1059 and date = '2026-11-02' and card_suffix = '1005'
   and ((source = 'plaid' and merchant = 'AMAZON')
     or (source = 'amex_alert' and merchant = 'AMAZON MARKEPLACE NA PA'))
 order by source;

begin;
do $$
declare
  v_canon uuid;
  v_dup uuid;
  v_hh uuid;
  v_canon_hh uuid;
  v_dup_hh uuid;
  v_canon_count int;
  v_dup_count int;
begin
  select count(*) into v_canon_count from transactions
   where source = 'plaid' and merchant = 'AMAZON'
     and amount_cents = 1059 and date = '2026-11-02' and card_suffix = '1005'
     and kind = 'charge' and excluded = false;
  if v_canon_count <> 1 then
    raise exception 'Amazon merge aborted: expected exactly 1 Plaid AMAZON $10.59 row, found %', v_canon_count;
  end if;
  select count(*) into v_dup_count from transactions
   where source = 'amex_alert' and merchant = 'AMAZON MARKEPLACE NA PA'
     and amount_cents = 1059 and date = '2026-11-02' and card_suffix = '1005'
     and kind = 'charge' and excluded = false;
  if v_dup_count <> 1 then
    raise exception 'Amazon merge aborted: expected exactly 1 email AMAZON MARKEPLACE NA PA $10.59 row, found %', v_dup_count;
  end if;
  select id, household_id into v_canon, v_canon_hh from transactions
   where source = 'plaid' and merchant = 'AMAZON'
     and amount_cents = 1059 and date = '2026-11-02' and card_suffix = '1005'
     and kind = 'charge' and excluded = false;
  select id, household_id into v_dup, v_dup_hh from transactions
   where source = 'amex_alert' and merchant = 'AMAZON MARKEPLACE NA PA'
     and amount_cents = 1059 and date = '2026-11-02' and card_suffix = '1005'
     and kind = 'charge' and excluded = false;
  if v_canon_hh <> v_dup_hh then
    raise exception 'Amazon merge aborted: the two rows are in different households';
  end if;
  v_hh := v_canon_hh;
  if exists (select 1 from duplicate_candidates
              where (canonical_transaction_id = v_canon and duplicate_transaction_id = v_dup)
                 or (canonical_transaction_id = v_dup and duplicate_transaction_id = v_canon)) then
    raise exception 'Amazon merge aborted: a candidate already links this pair';
  end if;
  -- Merge = link + exclude, never delete (same semantics as the
  -- resolve_duplicate_candidate RPC, which cannot be used here
  -- because no pending candidate exists for this pre-detection pair).
  update transactions
     set excluded = true,
         exclude_reason = 'Duplicate of Plaid AMAZON row; issuer-confirmed single purchase (Amex screenshot Nov 3, 2026). Email row kept as evidence, not deleted.'
   where id = v_dup;
  insert into duplicate_candidates
    (household_id, canonical_transaction_id, duplicate_transaction_id, reason,
     merchant_a, merchant_b, status, resolution_note, resolved_at)
  values
    (v_hh, v_canon, v_dup, 'issuer-confirmed',
     'AMAZON', 'AMAZON MARKEPLACE NA PA', 'merged',
     'Issuer-confirmed single purchase (Amex screenshot Nov 3, 2026): Plaid canonical, email row excluded as evidence, not deleted.', now());
  insert into merchant_aliases (household_id, name_a, name_b)
  values (v_hh, 'AMAZON', 'AMAZON MARKEPLACE NA PA')
  on conflict (household_id, name_a, name_b) do nothing;
  insert into audit_log (household_id, actor, actor_name, action, detail)
  values (v_hh, null, 'admin (dashboard merge)', 'Duplicate merged',
          'Merged duplicate email row ' || v_dup::text || ' (AMAZON MARKEPLACE NA PA 1059 cents) into canonical Plaid row '
          || v_canon::text || ' (AMAZON 1059 cents). Duplicate excluded, not deleted. Issuer-confirmed (Amex screenshot Nov 3, 2026).');
end $$;
commit;

-- Step 3 (read-only): confirm exactly one $10.59 row still counts.
select id, merchant, source, excluded
  from transactions
 where amount_cents = 1059 and date = '2026-11-02' and card_suffix = '1005'
   and ((source = 'plaid' and merchant = 'AMAZON')
     or (source = 'amex_alert' and merchant = 'AMAZON MARKEPLACE NA PA'))
 order by source;
