-- Merchant rules: Includes match becomes case- and
-- whitespace-insensitive (build 39, Nov 16, 2026).
--
-- APPLY VIA: the Supabase dashboard SQL editor (same as build 30's
-- SQL). Do NOT apply live yourself from here — the parent applies
-- it. ORDER: apply BEFORE uploading the build-39 TestFlight build
-- only if the new matching must be live first — the app degrades
-- gracefully without it (the old key-substring Includes still
-- matches; the new lenient matches only arrive after this lands).
-- SAFE TO RE-RUN: CREATE OR REPLACE on both functions only; no
-- table, column or constraint changes, no data migration.
-- The function definitions below are copied verbatim from
-- supabase/merchant-rules-includes.sql (§3–4, build 34) with ONLY
-- the Includes predicate changed — keep the three files in step.
--
-- WHAT CHANGES (owner, Nov 16, 2026): "anything including that
-- pattern (meaning letters in that order, even if there's extra
-- spaces or less spaces in between it should be counted, it
-- shouldn't be caps lower case sensitive..)"
--   The Includes predicate used to compare the whitespace-collapsed
--   UPPER keys: strpos(key(merchant), key(pattern)) > 0. That is
--   already case-insensitive, but NOT whitespace-insensitive:
--   pattern "baltimore gas" (key "BALTIMORE GAS") did NOT match
--   merchant "BaltimoreGas" (key "BALTIMOREGAS"), and "B G E"
--   did NOT match "BGE".
--   Now Includes squashes BOTH sides before comparing — lowercase
--   + remove ALL whitespace (the existing merchant_rule_squash:
--   UPPER then strip every non-alphanumeric, so case and spacing
--   both vanish) — then checks substring:
--     strpos(squash(merchant), squash(pattern)) > 0
--   One normalization gives case-insensitivity,
--   whitespace-insensitivity, and order preservation together:
--   pattern "baltimore gas" matches "BaltimoreGas",
--   "BALTIMORE  GAS", "Baltimore Gas and Electric" and
--   "baltimoregas"; "B G E" matches "BGE" and vice versa.
--   The letters must still appear IN ORDER (substring, not fuzzy).
--
-- WHAT DOES NOT CHANGE:
--   * Exact match is untouched (exact-key tier 0 + squash-exact
--     tier 2 are exactly as before).
--   * Priority is untouched: exact-key (0) > includes (1) >
--     squash-exact (2); longest pattern wins within a tier.
--     For an Includes rule the squash-exact tier is now subsumed
--     by tier 1 (an equal squash is trivially a substring), but
--     the tier stays for Exact-type rules.
--   * The rule editor UI is untouched (pattern field, Includes
--     option) — only the matching behavior of Includes changes.
--   * The existing 9 seed rules keep matching: squashing only
--     makes matching MORE LENIENT, never stricter — any pair that
--     matched under key-substring still matches, because deleting
--     characters distributes over concatenation (if key(pattern)
--     is a substring of key(merchant), squash(pattern) is a
--     substring of squash(merchant)). Verified by hand for the
--     seeds: GOODYEAR / AMAZON / TOIREMORG (includes) still match
--     their merchants; INTERNAL TRANSFER CREDIT: SAVINGS still
--     matches "Internal Transfer Credit: Savings -5939" (squash
--     "INTERNALTRANSFERCREDITSAVINGS" is a substring of
--     "INTERNALTRANSFERCREDITSAVINGS5939"); the five exact rules
--     are untouched by this change.
--   * The TypeScript ingestion matcher
--     (supabase/functions/_shared/canonical.ts +
--     gmail-poll / ingest-amex-alert / plaid-sync copies) gets
--     the same change in the same branch — the three per-function
--     copies were still on the pre-build-34 prefix/startsWith
--     logic; they are brought to squash-includes here too, so
--     ingestion and the SQL RPCs behave identically.

-- 1. Best matching rule for one merchant name in one household.
-- Returns the rule id, display name and fixed kind, or no row when
-- nothing matches. Priority: exact-key (0) > includes (1) >
-- squash-exact (2); within a tier the longest pattern wins, then
-- the earliest-created rule.
create or replace function public.merchant_rule_match(
  p_household_id uuid, p_merchant text)
returns table (rule_id uuid, display_name text, fixed_kind text)
language sql
stable
set search_path = public
as $$
  select r.id, r.display_name, r.fixed_kind
    from public.merchant_rules r
   where r.household_id = p_household_id
     and (public.merchant_rule_key(r.pattern_text) = public.merchant_rule_key(p_merchant)
       or (r.match_type = 'includes'
           and strpos(public.merchant_rule_squash(p_merchant),
                      public.merchant_rule_squash(r.pattern_text)) > 0)
       or public.merchant_rule_squash(r.pattern_text) = public.merchant_rule_squash(p_merchant))
   order by
     case when public.merchant_rule_key(r.pattern_text) = public.merchant_rule_key(p_merchant) then 0
          when r.match_type = 'includes'
           and strpos(public.merchant_rule_squash(p_merchant),
                      public.merchant_rule_squash(r.pattern_text)) > 0 then 1
          else 2 end,
     length(public.merchant_rule_key(r.pattern_text)) desc,
     r.created_at asc
   limit 1
$$;

-- 2. Apply ONE rule to every matching row in the household:
-- rename the merchant, recompute dedupe_hash (the hash is built
-- from the merchant, so a renamed row must re-hash or later bank
-- rows can never match it), and apply the fixed kind under the
-- sign guard. Returns the number of rows changed. Internal helper
-- used by the rename RPC and the bulk-apply RPC below.
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
         -- extensions.digest: pgcrypto lives in schema 'extensions'
         -- and this function sets search_path = public, so the
         -- unqualified digest() does not resolve (live bug, Nov 15).
         dedupe_hash = encode(
           extensions.digest(v_rule.display_name || '|' || t.date::text || '|' ||
                  t.amount_cents::text || '|' || t.card_suffix, 'sha256'), 'hex'),
         kind = case
           when v_rule.fixed_kind is null then t.kind
           when v_rule.fixed_kind in ('charge', 'charity', 'fund_charge')
             and t.amount_cents <= 0 then t.kind
           when v_rule.fixed_kind in ('refund', 'payment', 'cashback', 'income')
             and t.amount_cents >= 0 then t.kind
           else v_rule.fixed_kind end
    from matched m
   where t.id = m.id
     and (t.merchant <> v_rule.display_name
       or (v_rule.fixed_kind is not null and t.kind <> v_rule.fixed_kind
           and not (v_rule.fixed_kind in ('charge', 'charity', 'fund_charge') and t.amount_cents <= 0)
           and not (v_rule.fixed_kind in ('refund', 'payment', 'cashback', 'income') and t.amount_cents >= 0)));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
-- Service-role / dashboard only: the admin-only RPCs below are the
-- client entry points. (Dashboard SQL runs as postgres and bypasses
-- grants; Edge Functions run as service_role.)
revoke execute on function public.apply_merchant_rule_to_rows(uuid, uuid) from public;
revoke execute on function public.apply_merchant_rule_to_rows(uuid, uuid) from authenticated;
revoke execute on function public.apply_merchant_rule_to_rows(uuid, uuid) from anon;
grant execute on function public.apply_merchant_rule_to_rows(uuid, uuid) to service_role;
