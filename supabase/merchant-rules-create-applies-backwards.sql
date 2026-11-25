-- Merchant rules apply backwards (build 74, Nov 25, 2026).
--
-- APPLY VIA: the Supabase dashboard SQL editor (same as build 30's SQL).
-- Do NOT apply live yourself from here — the parent applies it.
-- ORDER MATTERS: apply this migration BEFORE uploading the build-74
-- TestFlight build (the client needs no change — the re-apply happens
-- inside the function). SAFE TO RE-RUN: CREATE OR REPLACE.
-- The function definition below is copied verbatim from
-- supabase/merchant-rules.sql (and merchant-rules-includes.sql — the
-- two files carry the same copy; keep all three in step).
--
-- WHAT CHANGES: create_merchant_rule now re-applies the rule to the
-- household's existing rows that match it, before returning the id.
-- STANDING RULE (owner, Nov 25, 2026): whenever a merchant rule is
-- created or changed, it must apply RETROACTIVELY to the existing
-- transactions that match it — not only to new incoming rows.
-- update_merchant_rule and rename_transaction_and_apply_rule already
-- re-applied; create was the gap (the owner's Nov 15 TOIREMORG rule
-- never renamed the Nov 1–11 rows because it was created here).
-- apply_merchant_rule_to_rows is service_role-only for direct calls,
-- but this function is security definer, so the call inside it is
-- allowed — same as the other two functions. Re-applying when the
-- rule already existed (conflict path) is idempotent.
-- NOTE: do NOT change the live TOIREMORG rule or its rows — the owner
-- is changing that rule himself; this only makes the flow retroactive
-- going forward.

create or replace function public.create_merchant_rule(
  p_household_id uuid, p_pattern text, p_match_type text,
  p_display_name text, p_fixed_kind text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_key text := public.merchant_rule_key(p_pattern);
  v_display text := public.merchant_rule_key(p_display_name);
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if v_key = '' then raise exception 'pattern must not be empty'; end if;
  if v_display = '' then raise exception 'display name must not be empty'; end if;
  if p_match_type is null or p_match_type not in ('exact', 'includes') then
    raise exception 'match_type must be exact or includes';
  end if;
  if p_fixed_kind is not null and p_fixed_kind not in
    ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income') then
    raise exception 'invalid fixed kind: %', p_fixed_kind;
  end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  insert into public.merchant_rules
    (household_id, pattern_text, pattern_key, pattern_squash, source_merchant, match_type,
     display_name, fixed_kind, created_by)
  values (p_household_id, btrim(p_pattern), v_key, public.merchant_rule_squash(p_pattern),
          btrim(p_pattern), p_match_type, v_display, p_fixed_kind, auth.uid())
  on conflict (household_id, pattern_key, match_type) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.merchant_rules
     where household_id = p_household_id and pattern_key = v_key and match_type = p_match_type;
  end if;
  perform public.apply_merchant_rule_to_rows(p_household_id, v_id);
  return v_id;
end;
$$;
revoke execute on function public.create_merchant_rule(uuid, text, text, text, text) from public;
grant execute on function public.create_merchant_rule(uuid, text, text, text, text) to authenticated;
