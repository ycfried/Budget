-- Merchant rules: 'prefix' -> 'includes' + editable pattern (build 34, Nov 15, 2026).
--
-- APPLY VIA: the Supabase dashboard SQL editor (same as build 30's SQL).
-- Do NOT apply live yourself from here — the parent applies it.
-- ORDER MATTERS: apply this migration BEFORE uploading the build-34
-- TestFlight build. The new native client calls update_merchant_rule
-- with 5 arguments (p_pattern) and sends match_type 'includes'; the
-- old 4-arg function and the old 'prefix' check constraint would
-- reject those calls.
-- SAFE TO RE-RUN: every step is guarded (IF NOT EXISTS / DO-block
-- existence checks / updates that touch 0 rows on a second run).
-- The function definitions below are copied verbatim from
-- supabase/merchant-rules.sql (the record for fresh installs) —
-- keep the two in step.
--
-- WHAT CHANGES:
--  1. Table gains source_merchant (the original merchant name, for
--     reference in the editor); backfilled from pattern_text.
--  2. match_type 'prefix' becomes 'includes': the name must CONTAIN
--     the pattern anywhere (substring), not only start with it.
--     Existing 'prefix' rows are migrated to 'includes'; the check
--     constraint is updated to ('exact', 'includes').
--  3. update_merchant_rule gains p_pattern (editable pattern, blank
--     keeps the existing one) and re-applies the rule to matching
--     rows on save. The old 4-arg overload is dropped so PostgREST
--     sees exactly one update_merchant_rule.
--  4. create_merchant_rule and rename_transaction_and_apply_rule
--     record source_merchant and accept 'includes'.
-- Matching stays strict (never fuzzy): exact > includes > squash,
-- longest pattern wins within a tier.
-- BUILD 39 (Nov 16, 2026): Includes is case- and
-- whitespace-insensitive — the predicate squashes both sides
-- before the substring check; see
-- supabase/merchant-rules-includes-squash.sql for the live apply.

-- 0. pgcrypto (already there from build 30; harmless if present).
create extension if not exists pgcrypto;

-- 1. source_merchant column + backfill (the pattern was always the
-- original merchant name until now).
alter table public.merchant_rules add column if not exists source_merchant text;
update public.merchant_rules set source_merchant = pattern_text where source_merchant is null;

-- 2. Migrate 'prefix' rows to 'includes', then update the check
-- constraint. The old inline check would reject 'includes', so it
-- is dropped first (found dynamically — its name is auto-generated).
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'public.merchant_rules'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) like '%prefix%';
  if c is not null then
    execute 'alter table public.merchant_rules drop constraint ' || quote_ident(c);
  end if;
end $$;
update public.merchant_rules set match_type = 'includes' where match_type = 'prefix';
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.merchant_rules'::regclass
                    and conname = 'merchant_rules_match_type_check') then
    alter table public.merchant_rules
      add constraint merchant_rules_match_type_check
      check (match_type in ('exact', 'includes'));
  end if;
end $$;

-- 3. Best matching rule for one merchant name in one household.
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

-- 4. Apply ONE rule to every matching row in the household:
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

-- Create a rule. Returns the rule id. A rule with the same
-- (pattern, match_type) already in the household is returned
-- unchanged (same pattern taught twice is one rule, not two).
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
  -- Build 74 (owner, Nov 25, 2026 — STANDING RULE: rules apply
  -- backwards): a rule created here re-applies to the existing
  -- rows that match it, the same as update_merchant_rule and
  -- rename_transaction_and_apply_rule already do. Without this a
  -- rule created in Merchant Names only applied going forward
  -- (the owner's Nov 15 TOIREMORG rule never renamed the Nov 1–11
  -- rows). apply_merchant_rule_to_rows is service_role-only for
  -- direct calls, but this function is security definer, so the
  -- call inside it is allowed — same as the other two functions.
  -- Re-applying when the rule already existed (conflict path) is
  -- idempotent: it just re-applies the existing rule to any rows
  -- that missed it.
  perform public.apply_merchant_rule_to_rows(p_household_id, v_id);
  return v_id;
end;
$$;
revoke execute on function public.create_merchant_rule(uuid, text, text, text, text) from public;
grant execute on function public.create_merchant_rule(uuid, text, text, text, text) to authenticated;

-- Update a rule's display name, fixed kind, match type and/or
-- pattern. The pattern is editable (owner, Nov 15, 2026 — build
-- 34): pass a new pattern to set it, normalized the same way
-- create does (uppercase, trimmed, whitespace collapsed); pass
-- null or blank to keep the existing pattern — the server never
-- saves a blank pattern. Saving re-applies the rule to matching
-- rows, so existing transactions get renamed by the new pattern.
-- A pattern that would collide with another rule's (pattern,
-- match_type) in the household is rejected. Returns void.
-- (The old 4-arg signature is dropped first — CREATE OR REPLACE
-- with a new parameter list would leave the old overload behind,
-- and PostgREST would see two update_merchant_rule functions.)
drop function if exists public.update_merchant_rule(uuid, text, text, text);
create or replace function public.update_merchant_rule(
  p_rule_id uuid, p_display_name text, p_fixed_kind text, p_match_type text,
  p_pattern text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.merchant_rules%rowtype;
  v_display text;
  v_key text;
  v_new_key text;
  v_new_match text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_rule from public.merchant_rules where id = p_rule_id for update;
  if not found then raise exception 'merchant rule not found'; end if;
  if p_display_name is not null then
    v_display := public.merchant_rule_key(p_display_name);
    if v_display = '' then raise exception 'display name must not be empty'; end if;
  end if;
  if p_fixed_kind is not null and p_fixed_kind not in
    ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income') then
    raise exception 'invalid fixed kind: %', p_fixed_kind;
  end if;
  if p_match_type is not null and p_match_type not in ('exact', 'includes') then
    raise exception 'match_type must be exact or includes';
  end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_rule.household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  -- A blank pattern keeps the existing one (the client sends null
  -- for it, but a blank string must not save a blank pattern).
  if p_pattern is not null then
    v_key := public.merchant_rule_key(p_pattern);
    if v_key = '' then v_key := null; end if;
  end if;
  v_new_key := coalesce(v_key, v_rule.pattern_key);
  v_new_match := coalesce(p_match_type, v_rule.match_type);
  if (v_new_key, v_new_match) <> (v_rule.pattern_key, v_rule.match_type) then
    if exists (select 1 from public.merchant_rules
                where household_id = v_rule.household_id
                  and id <> p_rule_id
                  and pattern_key = v_new_key
                  and match_type = v_new_match) then
      raise exception 'a rule with that pattern already exists';
    end if;
  end if;
  update public.merchant_rules
     set display_name = coalesce(v_display, display_name),
         fixed_kind = p_fixed_kind,
         match_type = coalesce(p_match_type, match_type),
         pattern_text = case when v_key is not null then btrim(p_pattern) else pattern_text end,
         pattern_key = case when v_key is not null then v_key else pattern_key end,
         pattern_squash = case when v_key is not null then public.merchant_rule_squash(p_pattern) else pattern_squash end,
         updated_at = now()
   where id = p_rule_id;
  -- Re-apply the rule to matching rows, the same re-apply the
  -- rename path does — a changed pattern renames the rows it now
  -- matches, and a changed display name / match type takes effect
  -- on old rows too.
  perform public.apply_merchant_rule_to_rows(v_rule.household_id, p_rule_id);
end;
$$;
revoke execute on function public.update_merchant_rule(uuid, text, text, text, text) from public;
grant execute on function public.update_merchant_rule(uuid, text, text, text, text) to authenticated;

-- Rename one transaction AND teach the rule: creates (or reuses)
-- the rule for that transaction's merchant spelling, then applies
-- it to ALL matching rows, old and new (new rows pick it up at
-- ingestion). Returns the number of rows renamed. The rule's
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
