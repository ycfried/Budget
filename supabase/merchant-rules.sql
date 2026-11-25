-- Merchant name rules (build 30, task E — teachable rename + saved
-- list). Applied via the Supabase SQL editor. Additive only;
-- re-running is safe (IF NOT EXISTS / ON CONFLICT guards; the RPCs
-- are CREATE OR REPLACE).
--
-- WHAT IT IS: a household-scoped `merchant_rules` table: one rule
-- maps a merchant-name pattern to a clean display name plus an
-- optional fixed kind (charity/income/transfer/payment/etc.). Rules
-- apply (a) at ingestion for NEW transactions — plaid-sync,
-- gmail-poll and ingest-amex-alert apply the best rule BEFORE the
-- dedupe hash is computed, so a bank row and its email alert hash
-- identically — and (b) to EXISTING rows via the rename RPC below,
-- which also recomputes dedupe_hash for every renamed row.
-- Rules apply to EVERY transaction kind, everywhere names render
-- (the stored merchant IS the display name; clients title-case it
-- on render, as they already do — display names are stored UPPER
-- like every other transactions.merchant value).
--
-- MATCHING (mirrored in supabase/functions/_shared/canonical.ts —
-- keep the two in step): strict only, never fuzzy.
--   key    = UPPER, trimmed, whitespace collapsed, leading
--            non-alphanumeric bank artifacts stripped ('=TENYAD...'
--            -> 'TENYAD...').
--   squash = key with ALL non-alphanumerics removed, so
--            'TENYADKALLAHGEMACH' matches 'TENYAD KALLAH GEMACH'.
--   A rule matches when: exact-key equal (any match_type), or
--   match_type='includes' and the SQUASH contains the pattern
--   squash anywhere (build 39: case- and whitespace-insensitive
--   — the key-substring check could not match across different
--   spacing), or squash equal. Priority: exact > includes >
--   squash; within a
--   tier the longest pattern wins, then the earliest rule.
-- Fixed kind: auto-applies to matching NEW transactions (and to
-- rows a rename applies to) with one sign guard — a money-out kind
-- (charge/charity/fund_charge) never overrides a money-in
-- (negative) row, and a money-in kind (refund/payment/cashback/
-- income) never overrides a money-out row; 'transfer' applies to
-- either sign. So a refund of a gift keeps the classifier's kind.
--
-- RELATION TO merchant_aliases (dedupe-review-queue.sql): aliases
-- stay exactly as they are — admin-confirmed evidence that two
-- spellings are the same merchant, used by duplicate review. Rules
-- are the NEW rename system (pattern -> display name); aliases
-- carry no display name, so they cannot rename. The two tables do
-- not duplicate each other: resolving a duplicate with
-- "Remember as same merchant" still writes an alias; renaming a
-- transaction writes a rule. flagLookalikes treats both as
-- relatedness evidence.
--
-- BACKWARDS COMPATIBILITY: new table + new RPCs only. No existing
-- column is renamed, dropped or retyped; no existing RPC changes.
--
-- BUILD 34 (Nov 15, 2026): 'prefix' becomes 'includes' (substring:
-- the name must CONTAIN the pattern anywhere, not only start with
-- it); the pattern is editable via update_merchant_rule; and the
-- table gains source_merchant (the original spelling, for
-- reference). Existing 'prefix' rows are migrated by
-- merchant-rules-includes.sql; this file is the record for fresh
-- installs.
-- BUILD 39 (Nov 16, 2026): Includes is case- and
-- whitespace-insensitive — the predicate squashes both sides
-- (merchant_rule_squash) before the substring check, so
-- "baltimore gas" matches "BaltimoreGas" and "B G E" matches
-- "BGE". See supabase/merchant-rules-includes-squash.sql, which
-- carries the same two function definitions for the live apply.
--
-- The frozen web app (v69) reads transactions.merchant as before
-- and simply shows the cleaner names once rules have renamed rows.

-- pgcrypto supplies digest() for the dedupe_hash recompute (§4).
create extension if not exists pgcrypto;

-- 1. Normalization helpers (immutable, so they can be used in
-- generated columns / indexes if a later migration wants them).
create or replace function public.merchant_rule_key(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select regexp_replace(
    regexp_replace(upper(btrim(coalesce(p_name, ''))), '\s+', ' ', 'g'),
    '^[^A-Z0-9]+', '')
$$;

create or replace function public.merchant_rule_squash(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select regexp_replace(public.merchant_rule_key(p_name), '[^A-Z0-9]', '', 'g')
$$;

-- 2. The rules table. pattern_text is the pattern as entered (for
-- the UI); pattern_key / pattern_squash are the normalized forms
-- matching uses. display_name is stored normalized UPPER, exactly
-- as transactions.merchant is stored. fixed_kind is null for
-- name-only rules and must be one of the live 8 transaction kinds
-- (refund-classification-income-kind.sql) when set.
create table if not exists public.merchant_rules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  pattern_text text not null,
  pattern_key text not null,
  pattern_squash text not null,
  -- The merchant name as it originally appeared (build 34): the
  -- pattern can be shortened for an Includes rule, but the original
  -- spelling stays visible in the editor for reference.
  source_merchant text,
  match_type text not null default 'exact' check (match_type in ('exact', 'includes')),
  display_name text not null,
  fixed_kind text check (fixed_kind is null or fixed_kind in
    ('charge', 'refund', 'fund_charge', 'payment', 'cashback', 'charity', 'transfer', 'income')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, pattern_key, match_type)
);
-- Build 34: the column for existing tables (the CREATE above only
-- covers fresh installs) + backfill from the pattern, which until
-- now always was the original merchant name.
alter table public.merchant_rules add column if not exists source_merchant text;
update public.merchant_rules set source_merchant = pattern_text where source_merchant is null;
create index if not exists merchant_rules_household_idx
  on public.merchant_rules (household_id);

alter table public.merchant_rules enable row level security;
drop policy if exists "members read own merchant rules" on public.merchant_rules;
create policy "members read own merchant rules"
  on public.merchant_rules for select
  using (household_id in (select household_id from public.household_members
                          where user_id = auth.uid()));
grant select on public.merchant_rules to authenticated;

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

-- 5. Admin-only RPCs the native client calls.
-- Common guard: caller must be an admin member of the household.

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

-- Delete a rule. Already-renamed rows are NOT reverted: the rule
-- only taught future rows and past renames; deleting it stops
-- future application. Returns void.
create or replace function public.delete_merchant_rule(p_rule_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hh uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select household_id into v_hh from public.merchant_rules where id = p_rule_id;
  if not found then raise exception 'merchant rule not found'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = v_hh
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  delete from public.merchant_rules where id = p_rule_id;
end;
$$;
revoke execute on function public.delete_merchant_rule(uuid) from public;
grant execute on function public.delete_merchant_rule(uuid) to authenticated;

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

-- Re-apply ALL of a household's rules to all of its rows (admin
-- only). Used after the seed rules below are inserted, or after
-- rules are edited in bulk. Returns the total rows changed. Rules
-- are applied longest-pattern-first so a specific rule wins over a
-- broader one (e.g. 'WIRE TRANSFER FEE DOMESTIC OUTGOING' before
-- 'WIRE TRANSFER DOMESTIC OUTGOING' — though those two are exact,
-- the order is harmless and keeps the general case safe).
create or replace function public.apply_merchant_rules_to_household(
  p_household_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.merchant_rules%rowtype;
  v_total integer := 0;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  for v_rule in
    select * from public.merchant_rules
     where household_id = p_household_id
     order by length(pattern_key) desc, created_at asc
  loop
    v_total := v_total + public.apply_merchant_rule_to_rows(p_household_id, v_rule.id);
  end loop;
  return v_total;
end;
$$;
revoke execute on function public.apply_merchant_rules_to_household(uuid) from public;
grant execute on function public.apply_merchant_rules_to_household(uuid) to authenticated;

-- 6. Seed rules for the owner's named examples, for EVERY existing
-- household (household-scoped rules cannot be global — each
-- household gets its own copy). New households start with no rules
-- and teach their own; the native client can copy these defaults
-- on demand, but this migration does not invent a household.
--   * BALTIMORE GAS AND ELECTRIC COMPANY -> BGE (exact, name only)
--   * GOODYEAR (includes) -> GOODYEAR — catches 'GOODYEAR TIRERUBBER'
--   * AMAZON (includes) -> AMAZON — catches 'AMAZON MARKEPLACE NA PA'
--   * TOIREMORG (includes) -> TOIREMORG — unifies the spellings to one
--     display name. Name only, NO fixed kind: the $2 bank TOIREMORG
--     row and the $2 email TOIREMORG CHARITY row are different kinds
--     and must stay two separate gifts (owner ruling Nov 3).
--   * TENYAD KALLAH GEMACH (exact) -> TENYAD KALLAH GEMACH — the
--     squash match catches the bank artifact '=TENYADKALLAHGEMACH'.
--     Name only, NO fixed kind (kind is the owner's call, not ours).
--   * INTERNAL TRANSFER CREDIT: SAVINGS (includes) -> TRANSFER TO
--     SAVINGS, kind transfer — catches '... Savings -5939' (the
--     account suffix varies). classifyKind already returns transfer
--     for INTERNAL TRANSFER; the fixed kind only reinforces it.
--   * WIRE TRANSFER DOMESTIC OUTGOING (exact) -> WIRE TRANSFER,
--     name only (a wire out is a payment to someone else, not an
--     internal transfer — kind stays as classified).
--   * WIRE TRANSFER FEE DOMESTIC OUTGOING (exact) -> WIRE TRANSFER
--     FEE, name only.
--   * ONLINE TRANSFER / PAYMENT: DEBIT (exact) -> TRANSFER, kind
--     transfer (the owner's own label for this row).
insert into public.merchant_rules
  (household_id, pattern_text, pattern_key, pattern_squash, source_merchant, match_type, display_name, fixed_kind)
select h.id, s.pattern_text,
       public.merchant_rule_key(s.pattern_text),
       public.merchant_rule_squash(s.pattern_text),
       s.pattern_text,
       s.match_type,
       public.merchant_rule_key(s.display_name),
       s.fixed_kind
  from public.households h
  cross join (values
    ('BALTIMORE GAS AND ELECTRIC COMPANY', 'exact', 'BGE', null),
    ('GOODYEAR', 'includes', 'GOODYEAR', null),
    ('AMAZON', 'includes', 'AMAZON', null),
    ('TOIREMORG', 'includes', 'TOIREMORG', null),
    ('TENYAD KALLAH GEMACH', 'exact', 'TENYAD KALLAH GEMACH', null),
    ('INTERNAL TRANSFER CREDIT: SAVINGS', 'includes', 'TRANSFER TO SAVINGS', 'transfer'),
    ('WIRE TRANSFER DOMESTIC OUTGOING', 'exact', 'WIRE TRANSFER', null),
    ('WIRE TRANSFER FEE DOMESTIC OUTGOING', 'exact', 'WIRE TRANSFER FEE', null),
    ('ONLINE TRANSFER / PAYMENT: DEBIT', 'exact', 'TRANSFER', 'transfer')
  ) as s(pattern_text, match_type, display_name, fixed_kind)
on conflict (household_id, pattern_key, match_type) do nothing;

-- NOTE: the seed rules above only teach future ingestions. To apply
-- them to EXISTING rows, an admin runs
--   select public.apply_merchant_rules_to_household('<household-uuid>');
-- (or the rename RPC per row). That step is deliberately NOT run
-- here: renaming existing rows is a visible data change the parent
-- verifies in the test household first (see BUILD30_SERVER_DEPLOY.md).
