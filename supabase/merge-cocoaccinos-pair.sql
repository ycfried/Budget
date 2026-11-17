-- Merge the owner-flagged Cocoaccinos duplicate pair (build 40).
--
-- Bank "Cocoaccino's" $3.13 (source plaid) + Email "Cocoaccinos"
-- $3.13 (source amex_alert), both Pending, Today (2026-11-16),
-- card ••1005, real household 647d1f23-606f-43af-92e5-1de2f1f34377.
-- The bank row is kept and stays counted; the email row is excluded
-- (never deleted) with a merged candidate record + audit entry, via
-- the proper merge_bank_email_pair mechanism — NOT a hand edit.
--
-- RUN ORDER: apply supabase/auto-merge-squash.sql FIRST (it makes
-- merchants_related_for_merge squash-based, so the $3.13 pair
-- passes the relatedness check), THEN run this script. If the check
-- is not 'ok', this script reports the reason and merges NOTHING.
-- SAFE: finds the rows by household + amount + date + source +
-- card + squash(merchant); if either row is not found, or the check
-- fails, it stops without changing anything. Idempotent: after a
-- successful merge the email row is excluded, so a re-run finds no
-- email row and reports "email row not found — nothing merged".
-- Do NOT run a broad auto-merge pass — this merges ONLY this pair.
-- The Amazon $79.99 / $19.07 reversed bank rows are untouched.
DO $$
DECLARE
  v_bank_id uuid;
  v_email_id uuid;
  v_check text;
  v_merged uuid;
  v_count_before integer;
  v_count_after integer;
BEGIN
  -- Bank row: plaid, Cocoaccino's, $3.13, 2026-11-16, ••1005, counted.
  SELECT id INTO v_bank_id FROM public.transactions
   WHERE household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
     AND source = 'plaid'
     AND amount_cents = 313
     AND kind = 'charge'
     AND date = '2026-11-16'
     AND card_suffix = '1005'
     AND public.merchant_rule_squash(merchant) = 'COCOACCINOS'
     AND NOT excluded
   ORDER BY created_at ASC LIMIT 1;
  -- Email row: amex_alert, Cocoaccinos, $3.13, 2026-11-16, ••1005, counted.
  SELECT id INTO v_email_id FROM public.transactions
   WHERE household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
     AND source = 'amex_alert'
     AND amount_cents = 313
     AND kind = 'charge'
     AND date = '2026-11-16'
     AND card_suffix = '1005'
     AND public.merchant_rule_squash(merchant) = 'COCOACCINOS'
     AND NOT excluded
   ORDER BY created_at ASC LIMIT 1;
  IF v_bank_id IS NULL THEN
    RAISE NOTICE 'bank row not found — nothing merged';
    RETURN;
  END IF;
  IF v_email_id IS NULL THEN
    RAISE NOTICE 'email row not found — nothing merged';
    RETURN;
  END IF;
  RAISE NOTICE 'bank row: %, email row: %', v_bank_id, v_email_id;
  SELECT count(*) INTO v_count_before FROM public.transactions
   WHERE household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
     AND amount_cents = 313 AND kind = 'charge' AND NOT excluded;
  RAISE NOTICE 'counted $3.13 charge rows before merge: %', v_count_before;
  -- Requires auto-merge-squash.sql applied first.
  v_check := public.bank_email_merge_check(v_bank_id, v_email_id, false);
  RAISE NOTICE 'merge check: %', v_check;
  IF v_check <> 'ok' THEN
    RAISE NOTICE 'merge check failed — nothing merged';
    RETURN;
  END IF;
  v_merged := public.merge_bank_email_pair(v_bank_id, v_email_id, 'owner-flagged Cocoaccinos duplicate (build 40)');
  RAISE NOTICE 'merged email row: %', v_merged;
  SELECT count(*) INTO v_count_after FROM public.transactions
   WHERE household_id = '647d1f23-606f-43af-92e5-1de2f1f34377'
     AND amount_cents = 313 AND kind = 'charge' AND NOT excluded;
  RAISE NOTICE 'counted $3.13 charge rows after merge: %', v_count_after;
END $$;
