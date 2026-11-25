-- Merchant rules: rename gains an editable match pattern (build 74, Nov 25, 2026).
--
-- APPLY VIA: the Supabase dashboard SQL editor (same as build 30's SQL).
-- Do NOT apply live yourself from here — the parent applies it.
-- ORDER MATTERS: apply this migration BEFORE uploading the build-74
-- TestFlight build. The new native client calls
-- rename_transaction_and_apply_rule with 5 arguments (p_pattern);
-- the old 4-arg function is dropped below so PostgREST sees exactly
-- one rename_transaction_and_apply_rule. (The new 5-arg function
-- defaults p_pattern to null, so an older 4-arg call still resolves
-- to it — but apply first anyway, per the build-34 precedent.)
-- SAFE TO RE-RUN: the drop is guarded (IF EXISTS) and the create is
-- CREATE OR REPLACE. The function definition below is copied verbatim
-- from supabase/merchant-rules.sql (the record for fresh installs) —
-- keep the two in step.
--
-- WHAT CHANGES:
--  1. rename_transaction_and_apply_rule gains p_pattern (the words an
--     'includes' rule matches on, editable in the Rename Merchant
--     sheet — blank keeps the transaction's own bank name, the
--     previous behaviour). Only used when match_type is 'includes';
--     an 'exact' rename always matches the bank name itself.
--     source_merchant stays the bank name, for reference.
--  2. The old 4-arg overload is dropped so PostgREST sees exactly
--     one rename_transaction_and_apply_rule (same as build 34 did
--     for update_merchant_rule).
--  3. The audit detail notes the pattern when it differs from the
--     bank name.
-- NOTE: editing the words to a shorter stem can leave the old
-- bank-name-pattern rule in place (same display name in the normal
-- case, so nothing shows wrong); the owner can remove a stale rule
-- in Merchant Names.

-- 0. Drop the old 4-arg overload (PostgREST must see exactly one).
drop function if exists public.rename_transaction_and_apply_rule(uuid, text, text, text);

-- 1. The rename function, with the editable pattern.
-- match_type defaults to 'exact' — a rename teaches that spelling
-- only; pass 'includes' when the spelling is a stem (e.g. 'AMAZON'
-- should also catch 'AMAZON MARKEPLACE NA PA').
-- p_pattern (build 74, owner Nov 25, 2026): the words an
-- 'includes' rule matches on, editable in the Rename Merchant
-- sheet — blank keeps the transaction's own bank name (the
-- previous behaviour). Only used when match_type is 'includes';
-- an 'exact' rename always matches the bank name itself.
-- NOTE: a rename with a fixed kind reclassifies matching rows
-- under the sign guard (§4); a name-only rename never changes kind.
-- NOTE: editing the words to a shorter stem can leave the old
-- bank-name-pattern rule in place (same display name in the
-- normal case, so nothing shows wrong); the owner can remove a
-- stale rule in Merchant Names.
create or replace function public.rename_transaction_and_apply_rule(
  p_transaction_id uuid, p_display_name text, p_fixed_kind text,
  p_match_type text default 'exact', p_pattern text default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_txn public.transactions%rowtype;
  v_rule_id uuid;
  v_count integer := 0;
  v_display text := public.merchant_rule_key(p_display_name);
  v_pattern text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if v_display = '' then raise exception 'display name must not be empty'; end if;
  if p_match_type is null or p_match_type not in ('exact', 'includes') then
    raise exception 'match_type must be exact or includes';
  end if;
  if p_fixed_kind is not null and p_fixed_kind not in
    ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income') then
    raise exception 'invalid fixed kind: %', p_fixed_kind;
  end if;
  select * into v_txn from public.transactions where id = p_transaction_id;
  if not found then raise exception 'transaction not found'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_txn.household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  perform 1 from public.households where id = v_txn.household_id for update;
  -- The match value (build 74): the owner's edited words for an
  -- 'includes' rule, else the transaction's own bank name.
  -- source_merchant stays the bank name, for reference.
  v_pattern := case when p_match_type = 'includes'
    then coalesce(nullif(btrim(p_pattern), ''), v_txn.merchant)
    else v_txn.merchant end;
  -- Teach (or reuse) the rule for this transaction's spelling.
  insert into public.merchant_rules
    (household_id, pattern_text, pattern_key, pattern_squash, source_merchant, match_type,
     display_name, fixed_kind, created_by)
  values (v_txn.household_id, v_pattern,
          public.merchant_rule_key(v_pattern),
          public.merchant_rule_squash(v_pattern),
          v_txn.merchant,
          p_match_type, v_display, p_fixed_kind, auth.uid())
  on conflict (household_id, pattern_key, match_type) do update
    set display_name = excluded.display_name,
        fixed_kind = excluded.fixed_kind,
        updated_at = now()
  returning id into v_rule_id;
  -- Apply it to every matching row, old included.
  v_count := public.apply_merchant_rule_to_rows(v_txn.household_id, v_rule_id);
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (v_txn.household_id, auth.uid(), 'admin', 'Merchant renamed',
          'Renamed "' || v_txn.merchant || '" to "' || v_display || '"'
          || case when p_fixed_kind is null then '' else ' (kind ' || p_fixed_kind || ')' end
          || case when v_pattern <> v_txn.merchant then ' (matches "' || v_pattern || '")' else '' end
          || ' — ' || v_count::text || ' row(s) updated, rule applies to new rows too.');
  return v_count;
end;
$$;
revoke execute on function public.rename_transaction_and_apply_rule(uuid, text, text, text, text) from public;
grant execute on function public.rename_transaction_and_apply_rule(uuid, text, text, text, text) to authenticated;
