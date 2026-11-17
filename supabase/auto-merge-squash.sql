-- Auto-merge relatedness: squash-based merchant comparison
-- (build 40, Nov 16, 2026).
--
-- APPLY VIA: the Supabase dashboard SQL editor (same as build 39's
-- SQL). Do NOT apply live yourself from here — the parent applies
-- it. SAFE TO RE-RUN: CREATE OR REPLACE on one function only; no
-- table, column or constraint changes, no data migration. The
-- function definition below is copied verbatim from
-- supabase/auto-merge-bank-email.sql (§1) — keep the two in step.
--
-- WHAT CHANGES (owner, Nov 16, 2026 — STANDING RULE): same date +
-- same amount + similar merchant + one Email + one Bank = the SAME
-- transaction and must auto-merge (bank row kept). Slight spelling
-- differences must NOT prevent the merge. The relatedness check
-- used to compare merchant names by KEY (UPPER + whitespace
-- collapsed, leading artifacts stripped) — the key KEEPS internal
-- punctuation, so "Cocoaccino's" (key "COCOACCINO'S") never
-- equalled or contained "Cocoaccinos" (key "COCOACCINOS"), and the
-- $3.13 Bank+Email pair never merged. Now it compares by SQUASH
-- (UPPER + strip every non-alphanumeric): both squash to
-- "COCOACCINOS", so they compare as the same merchant. No fuzzy
-- matching: squash equality / substring only. The TOIREMORG
-- never-merge rule and the ambiguity-refuses behavior are separate
-- safeguards and are unchanged.
--
-- WHAT DOES NOT CHANGE:
--   * The rest of bank_email_merge_check (same amount, same kind,
--     dates within 2 days, card suffix, one plaid + one amex_alert,
--     TOIREMORG refusal, prior-candidate block) is untouched.
--   * The TypeScript mirror (canonical.ts merchantsRelated +
--     autoMergeEligible) gets the same squash change in the same
--     branch, so ingestion and the SQL RPCs behave identically.

-- 1. Merchant relatedness for merge purposes (SQL mirror of
-- canonical.ts merchantsRelated + alias + rule-display checks).
-- STANDING RULE (owner, Nov 16, 2026 — build 40): same date +
-- same amount + similar merchant + one Email + one Bank = the SAME
-- transaction and must auto-merge (bank row kept). Slight spelling
-- differences — punctuation (apostrophe), case, whitespace, minor
-- variation — must NOT prevent the merge. So the comparison uses
-- the SQUASH (UPPER + strip every non-alphanumeric), not the key
-- (which keeps internal punctuation): "Cocoaccino's" squashes to
-- "COCOACCINOS", same as "Cocoaccinos", but their keys
-- ("COCOACCINO'S" vs "COCOACCINOS") never matched, so the pair
-- never merged. No fuzzy matching: squash equality / substring
-- only. TOIREMORG never merges and ambiguity refuses — those
-- safeguards are separate and unchanged.
create or replace function public.merchants_related_for_merge(
  p_household_id uuid, p_merchant_a text, p_merchant_b text)
returns boolean
language sql
stable
set search_path = public
as $$
  select
    -- identical (squashed) names
    public.merchant_rule_squash(p_merchant_a) = public.merchant_rule_squash(p_merchant_b)
    -- one contains the other (squashed, min length 4, as in canonical.ts)
    or (length(public.merchant_rule_squash(p_merchant_a)) >= 4
        and length(public.merchant_rule_squash(p_merchant_b)) >= 4
        and (position(public.merchant_rule_squash(p_merchant_b) in public.merchant_rule_squash(p_merchant_a)) > 0
             or position(public.merchant_rule_squash(p_merchant_a) in public.merchant_rule_squash(p_merchant_b)) > 0))
    -- confirmed alias pair, either order (squashed)
    or exists (select 1 from public.merchant_aliases a
                where a.household_id = p_household_id
                  and ((public.merchant_rule_squash(a.name_a) = public.merchant_rule_squash(p_merchant_a)
                        and public.merchant_rule_squash(a.name_b) = public.merchant_rule_squash(p_merchant_b))
                       or (public.merchant_rule_squash(a.name_a) = public.merchant_rule_squash(p_merchant_b)
                           and public.merchant_rule_squash(a.name_b) = public.merchant_rule_squash(p_merchant_a))))
    -- both map to the same rule display name
    or exists (select 1
                 from public.merchant_rule_match(p_household_id, p_merchant_a) ma
                 join public.merchant_rule_match(p_household_id, p_merchant_b) mb
                   on ma.display_name = mb.display_name)
$$;
