-- similar-name-review-backstop.sql — build 65 (Nov 23, 2026).
--
-- PURPOSE (owner, Nov 23 — Yaldel case): two $54.00 donation rows
-- ("Yaldel Shluchei Harebbe" vs "Yaldei Shluchei Harebbe Special
-- Needs", same date, same amount, both pending) were THE SAME
-- donation, but the auto-merge AND the Review possible-duplicate
-- flag both missed them — the merchant names hash differently, and
-- one squash does not contain the other (YALDEL vs YALDEI in the
-- middle). The Spending-side duplicate was excluded by hand; this
-- file is the server sweep so the NEXT such pair is caught.
--
-- WHAT IT DOES: backstop_similar_name_duplicates(p_household_id)
-- walks every live same-date + same-amount pair in the household
-- and inserts a duplicate_candidates row (reason 'similar-name',
-- status 'pending') when the merchant names are similar — the SQL
-- mirror of canonical.ts merchantsSimilarForReview: squashes share
-- a common substring of 8+ characters, or share 2+ whole words
-- (length 3+), or one contains the other. Review-flagging ONLY:
-- nothing here merges, excludes, or deletes anything. The Review
-- page reads duplicate_candidates with status='pending', so a
-- flagged pair appears in Possible Duplicates with no app change.
--
-- SAFEGUARDS (same as the TypeScript detector — keep in step):
--   * TOIREMORG NEVER flags: any pair where either merchant
--     contains 'TOIREMORG' is skipped outright — owner ruling
--     Nov 3: the $2 bank "TOIREMORG" and $2 email "TOIREMORG
--     CHARITY" rows are TWO real gifts, never merge, never flag.
--     (The names qualify as similar on their own — "TOIREMORG" is
--     contained in "TOIREMORGCHARITY" — so the guard is explicit.)
--   * DISMISSED PAIRS NEVER RE-FLAG: a pair with ANY
--     duplicate_candidates row (any status, either direction) is
--     skipped. Tapping "Separate" in Review sets status=
--     'separate', so a dismissed pair stays dismissed forever
--     (reopen_duplicate_candidate is the deliberate undo).
--   * Card suffix: equal, or either side '0000' (unknown, not a
--     different card — same rule as plaid-sync step 3b and the
--     auto-merge). Two rows on DIFFERENT known cards are two real
--     purchases and never flag.
--   * Identical names flag ONLY across sources (Bank+Email, the
--     Royal Farms shape). Two identical same-source rows are two
--     real identical purchases and stay unflagged.
--   * Only live rows (excluded=false, state not 'excluded' /
--     'reversed'); only dates >= 2026-11-01 (the app's Nov 1
--     floor); the Nov 22 Amazon $444.84/$13.77 rows are untouched
--     (different merchants/amounts — they match nothing here).
--   * Idempotent: re-running finds the candidate rows it just
--     wrote and flags 0 new pairs.
--
-- WHEN IT RUNS: plaid-sync calls it best-effort after every
-- successful sync (next to backstop_bank_email_pairs), so a pair
-- the ingestion-time flag missed — e.g. both rows arrived before
-- this rule existed — surfaces within a day. A missing SQL apply
-- never fails the sync (the call logs and continues).
--
-- DEPENDS ON: dedupe-review-queue.sql (duplicate_candidates) and
-- merchant-rules.sql (merchant_rule_key / merchant_rule_squash).
--
-- APPLY: run this file in the Supabase dashboard SQL editor
-- (project "Budget"). NOT yet applied live — the plaid-sync call
-- is best-effort until then. Then run once for the household to
-- sweep what is already there:
--   select * from backstop_similar_name_duplicates('647d1f23-606f-43af-92e5-1de2f1f34377');
-- (Live household id above; test household "Goldstein" is
-- 95e1aff3-f664-41bb-be09-70e00f75a141.) The already-excluded
-- Yaldel row is not live, so the live Yaldel pair itself is NOT
-- re-flagged — only genuinely live pairs are.

-- 1. 8+ character common substring between two squashed names.
-- Only the existence of an 8-char window is tested (not the
-- longest substring): any shared 8-char window proves the rule.
create or replace function public.has_common_substring_8(p_a text, p_b text)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  v_short text;
  v_long text;
  v_i integer;
begin
  if length(coalesce(p_a, '')) <= length(coalesce(p_b, '')) then
    v_short := coalesce(p_a, '');
    v_long := coalesce(p_b, '');
  else
    v_short := coalesce(p_b, '');
    v_long := coalesce(p_a, '');
  end if;
  if length(v_short) < 8 then return false; end if;
  for v_i in 1 .. length(v_short) - 7 loop
    if position(substr(v_short, v_i, 8) in v_long) > 0 then return true; end if;
  end loop;
  return false;
end;
$$;

-- 2. Similarity for Review (SQL mirror of canonical.ts
-- merchantsSimilarForReview — keep the two in step). Identical
-- squashes return false here on purpose: identical names are
-- handled by the caller's cross-source branch, and two identical
-- same-source rows are two real identical purchases.
create or replace function public.merchants_similar_for_review(p_merchant_a text, p_merchant_b text)
returns boolean
language sql
stable
set search_path = public
as $$
  select
    public.merchant_rule_squash(p_merchant_a) <> public.merchant_rule_squash(p_merchant_b)
    and length(public.merchant_rule_squash(p_merchant_a)) >= 4
    and length(public.merchant_rule_squash(p_merchant_b)) >= 4
    and (
      -- one contains the other
      position(public.merchant_rule_squash(p_merchant_b) in public.merchant_rule_squash(p_merchant_a)) > 0
      or position(public.merchant_rule_squash(p_merchant_a) in public.merchant_rule_squash(p_merchant_b)) > 0
      -- 2+ shared whole words (length 3+)
      or (select count(*) from (
            select distinct w from unnest(regexp_split_to_array(public.merchant_rule_key(p_merchant_a), ' ')) as w
             where length(w) >= 3
            intersect
            select distinct w from unnest(regexp_split_to_array(public.merchant_rule_key(p_merchant_b), ' ')) as w
             where length(w) >= 3
          ) shared) >= 2
      -- common substring of 8+ characters
      or public.has_common_substring_8(
           public.merchant_rule_squash(p_merchant_a),
           public.merchant_rule_squash(p_merchant_b))
    )
$$;

-- 3. The sweep. Returns how many new pairs were flagged.
create or replace function public.backstop_similar_name_duplicates(p_household_id uuid)
returns table (pairs_flagged integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pair record;
  v_canonical_id uuid;
  v_duplicate_id uuid;
  v_canonical_merchant text;
  v_duplicate_merchant text;
  v_flagged integer := 0;
begin
  for v_pair in
    select t1.id as a_id, t1.merchant as a_merchant, t1.source as a_source, t1.created_at as a_created,
           t2.id as b_id, t2.merchant as b_merchant, t2.source as b_source, t2.created_at as b_created
      from public.transactions t1
      join public.transactions t2
        on t2.household_id = t1.household_id
       and t2.date = t1.date
       and t2.amount_cents = t1.amount_cents
       and t2.id > t1.id
     where t1.household_id = p_household_id
       and t1.date >= '2026-11-01'
       and t1.excluded = false and t1.state not in ('excluded', 'reversed')
       and t2.excluded = false and t2.state not in ('excluded', 'reversed')
       and (coalesce(t1.card_suffix, '0000') = coalesce(t2.card_suffix, '0000')
            or coalesce(t1.card_suffix, '0000') = '0000'
            or coalesce(t2.card_suffix, '0000') = '0000')
       and position('TOIREMORG' in public.merchant_rule_squash(t1.merchant)) = 0
       and position('TOIREMORG' in public.merchant_rule_squash(t2.merchant)) = 0
       and (public.merchants_similar_for_review(t1.merchant, t2.merchant)
            or (public.merchant_rule_squash(t1.merchant) = public.merchant_rule_squash(t2.merchant)
                and ((t1.source = 'plaid' and t2.source in ('amex_alert', 'chase_alert'))
                     or (t2.source = 'plaid' and t1.source in ('amex_alert', 'chase_alert')))))
       and not exists (select 1 from public.duplicate_candidates c
                        where c.household_id = p_household_id
                          and ((c.canonical_transaction_id = t1.id and c.duplicate_transaction_id = t2.id)
                               or (c.canonical_transaction_id = t2.id and c.duplicate_transaction_id = t1.id)))
  loop
    -- Canonical: the Plaid row first (it receives posted updates),
    -- else the earlier-created row — same as pickCanonicalPair.
    if v_pair.a_source = 'plaid' and v_pair.b_source <> 'plaid' then
      v_canonical_id := v_pair.a_id; v_duplicate_id := v_pair.b_id;
      v_canonical_merchant := v_pair.a_merchant; v_duplicate_merchant := v_pair.b_merchant;
    elsif v_pair.b_source = 'plaid' and v_pair.a_source <> 'plaid' then
      v_canonical_id := v_pair.b_id; v_duplicate_id := v_pair.a_id;
      v_canonical_merchant := v_pair.b_merchant; v_duplicate_merchant := v_pair.a_merchant;
    elsif v_pair.a_created <= v_pair.b_created then
      v_canonical_id := v_pair.a_id; v_duplicate_id := v_pair.b_id;
      v_canonical_merchant := v_pair.a_merchant; v_duplicate_merchant := v_pair.b_merchant;
    else
      v_canonical_id := v_pair.b_id; v_duplicate_id := v_pair.a_id;
      v_canonical_merchant := v_pair.b_merchant; v_duplicate_merchant := v_pair.a_merchant;
    end if;
    insert into public.duplicate_candidates
      (household_id, canonical_transaction_id, duplicate_transaction_id,
       reason, merchant_a, merchant_b)
    values
      (p_household_id, v_canonical_id, v_duplicate_id,
       'similar-name',
       upper(regexp_replace(btrim(v_canonical_merchant), '\s+', ' ', 'g')),
       upper(regexp_replace(btrim(v_duplicate_merchant), '\s+', ' ', 'g')))
    on conflict (canonical_transaction_id, duplicate_transaction_id) do nothing;
    if found then
      v_flagged := v_flagged + 1;
    end if;
  end loop;
  return query select v_flagged;
end;
$$;
