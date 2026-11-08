-- Household Budget — refund → purchase linking (P0-1, Nov 8, 2026).
--
-- PROBLEM (full audit Nov 8, P0-1): nothing anywhere wrote
-- transactions.original_purchase_id, so linked-refund restoration was
-- unreachable for real refunds — every real refund fell into the
-- unlinked fallback and netted against the CURRENT week's charges
-- instead of restoring the locked week it belongs to. The restoration
-- math itself (restoration.mjs, week-close, compute-week) is verified
-- correct; only the link was missing.
--
-- WHAT THIS FILE ADDS — one conservative matcher, used by every
-- ingestion path, plus admin-only manual link/unlink:
--
-- AUTO-LINK RULES (auto_link_refund / link_refunds_to_purchase):
-- A refund is auto-linked to a purchase ONLY when ALL of these hold:
--   * refund kind = 'refund', purchase kind in ('charge', 'fund_charge');
--   * same household, same card suffix;
--   * normalized merchant equal (UPPER, trimmed, whitespace collapsed —
--     the same normalization as canonical.ts normalizeMerchant);
--   * EXACT amount: purchase.amount_cents = -refund.amount_cents
--     (a full refund only — partial refunds never auto-link);
--   * purchase date on or before the refund date, within 90 days;
--   * the purchase is not already fully refunded (linked refunds so
--     far total less than the purchase amount);
--   * EXACTLY ONE purchase matches. Zero matches or two-or-more
--     matches (e.g. two identical purchases) link NOTHING — the refund
--     stays unlinked for an admin to link by hand. Auto-linking never
--     guesses between lookalikes (same rule as the Nov 3 Amazon case:
--     lookalikes are flagged for admin review, never auto-merged).
-- A charge insert runs the reverse direction (link_refunds_to_purchase)
-- so a refund that arrived BEFORE its purchase still gets linked.
-- Auto-linking is best-effort: ingestion never fails because linking
-- did. A linked provisional refund is harmless — restoration and
-- week math only ever count POSTED refunds.
--
-- MANUAL LINK (link_refund / unlink_refund): admin-only, same
-- household, same card suffix, purchase date on or before the refund
-- date, and the refund must fit in what the purchase has left to
-- refund (|refund| + already-linked total <= purchase amount).
-- Merchant equality and the 90-day window are NOT required here —
-- that is the admin's judgment call. Unlink refuses when a
-- restoration entry already exists for the refund (a posted
-- restoration cannot be undone by unlinking).
--
-- STEP 0 — VERIFY LIVE FIRST (read-only): none of these four functions
-- exists live yet. If any does, stop and reconcile before applying.
--   select proname from pg_proc where proname in
--     ('auto_link_refund', 'link_refunds_to_purchase', 'link_refund', 'unlink_refund');
-- STEP 1 — Apply this file in the SQL editor, in order. No other file.
--   The Edge Function wiring (plaid-sync, ingest-amex-alert, gmail-poll
--   calling auto_link_refund / link_refunds_to_purchase after insert)
--   ships with the same release; until it is deployed, new refunds
--   still arrive unlinked and only the manual link path is live.
-- The transactions.original_purchase_id column itself already exists
-- (restoration-snapshots.sql:109); this file adds no columns.

-- ---------------------------------------------------------------------
-- Shared match test: normalized merchant equality, as in canonical.ts.
-- ---------------------------------------------------------------------
create or replace function public._same_normalized_merchant(a text, b text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select upper(regexp_replace(btrim(coalesce(a, '')), '\s+', ' ', 'g'))
       = upper(regexp_replace(btrim(coalesce(b, '')), '\s+', ' ', 'g'));
$$;
revoke execute on function public._same_normalized_merchant(text, text) from public;
grant execute on function public._same_normalized_merchant(text, text) to service_role;

-- ---------------------------------------------------------------------
-- auto_link_refund(p_refund_id) — link one refund to its purchase.
-- Returns the purchase id, or NULL when nothing was linked (not a
-- refund, already linked, excluded/reversed, zero or several matches).
-- Never raises for a non-match: ingestion calls it best-effort.
-- ---------------------------------------------------------------------
create or replace function public.auto_link_refund(p_refund_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref transactions%rowtype;
  v_cand_id uuid;
  v_cand_count integer;
begin
  select * into v_ref from transactions where id = p_refund_id;
  if not found then return null; end if;
  if v_ref.kind <> 'refund' then return null; end if;
  if v_ref.excluded is true or v_ref.state in ('excluded', 'reversed') then return null; end if;
  if v_ref.original_purchase_id is not null then return null; end if;

  select count(*), max(c.id) into v_cand_count, v_cand_id
  from transactions c
  where c.household_id = v_ref.household_id
    and c.kind in ('charge', 'fund_charge')
    and c.excluded is not true
    and c.state not in ('excluded', 'reversed')
    and c.card_suffix = v_ref.card_suffix
    and public._same_normalized_merchant(c.merchant, v_ref.merchant)
    and c.amount_cents = -v_ref.amount_cents
    and c.date <= v_ref.date
    and c.date >= v_ref.date - interval '90 days'
    and (select coalesce(sum(abs(r.amount_cents)), 0) from transactions r
         where r.original_purchase_id = c.id) < c.amount_cents;

  if v_cand_count <> 1 then return null; end if;
  update transactions set original_purchase_id = v_cand_id where id = p_refund_id;
  return v_cand_id;
end;
$$;
revoke execute on function public.auto_link_refund(uuid) from public;
grant execute on function public.auto_link_refund(uuid) to service_role;

-- ---------------------------------------------------------------------
-- link_refunds_to_purchase(p_purchase_id) — reverse direction: a charge
-- that has just been inserted links one earlier unlinked refund to it.
-- Returns the refund id, or NULL when nothing was linked.
-- ---------------------------------------------------------------------
create or replace function public.link_refunds_to_purchase(p_purchase_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pur transactions%rowtype;
  v_cand_id uuid;
  v_cand_count integer;
begin
  select * into v_pur from transactions where id = p_purchase_id;
  if not found then return null; end if;
  if v_pur.kind not in ('charge', 'fund_charge') then return null; end if;
  if v_pur.excluded is true or v_pur.state in ('excluded', 'reversed') then return null; end if;

  select count(*), max(r.id) into v_cand_count, v_cand_id
  from transactions r
  where r.household_id = v_pur.household_id
    and r.kind = 'refund'
    and r.excluded is not true
    and r.state not in ('excluded', 'reversed')
    and r.original_purchase_id is null
    and r.card_suffix = v_pur.card_suffix
    and public._same_normalized_merchant(r.merchant, v_pur.merchant)
    and r.amount_cents = -v_pur.amount_cents
    and r.date >= v_pur.date
    and r.date <= v_pur.date + interval '90 days'
    and (select coalesce(sum(abs(x.amount_cents)), 0) from transactions x
         where x.original_purchase_id = v_pur.id) < v_pur.amount_cents;

  if v_cand_count <> 1 then return null; end if;
  update transactions set original_purchase_id = p_purchase_id where id = v_cand_id;
  return v_cand_id;
end;
$$;
revoke execute on function public.link_refunds_to_purchase(uuid) from public;
grant execute on function public.link_refunds_to_purchase(uuid) to service_role;

-- ---------------------------------------------------------------------
-- link_refund(p_refund_id, p_purchase_id) — admin-only manual link.
-- Same household, same card suffix, purchase on or before the refund,
-- refund fits in what the purchase has left to refund. Merchant
-- equality and the 90-day window are the admin's judgment, not checked.
-- Returns the purchase id. Raises on any failed check.
-- ---------------------------------------------------------------------
create or replace function public.link_refund(p_refund_id uuid, p_purchase_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref transactions%rowtype;
  v_pur transactions%rowtype;
  v_linked_total integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_ref from transactions where id = p_refund_id;
  if not found then raise exception 'refund not found'; end if;
  select * into v_pur from transactions where id = p_purchase_id;
  if not found then raise exception 'purchase not found'; end if;
  if v_ref.household_id <> v_pur.household_id then raise exception 'refund and purchase are in different households'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_ref.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if v_ref.kind <> 'refund' then raise exception 'not a refund'; end if;
  if v_pur.kind not in ('charge', 'fund_charge') then raise exception 'not a purchase'; end if;
  if v_ref.excluded is true or v_ref.state in ('excluded', 'reversed') then raise exception 'refund is excluded or reversed'; end if;
  if v_pur.excluded is true or v_pur.state in ('excluded', 'reversed') then raise exception 'purchase is excluded or reversed'; end if;
  if v_ref.original_purchase_id is not null then
    if v_ref.original_purchase_id = p_purchase_id then return p_purchase_id; end if;
    raise exception 'refund is already linked — unlink it first';
  end if;
  if v_ref.card_suffix <> v_pur.card_suffix then raise exception 'refund and purchase are on different cards'; end if;
  if v_pur.date > v_ref.date then raise exception 'purchase is after the refund'; end if;
  select coalesce(sum(abs(amount_cents)), 0) into v_linked_total from transactions
    where original_purchase_id = p_purchase_id;
  if abs(v_ref.amount_cents) + v_linked_total > v_pur.amount_cents then
    raise exception 'refund is more than the purchase has left to refund';
  end if;
  update transactions set original_purchase_id = p_purchase_id where id = p_refund_id;
  return p_purchase_id;
end;
$$;
revoke execute on function public.link_refund(uuid, uuid) from public;
grant execute on function public.link_refund(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- unlink_refund(p_refund_id) — admin-only manual unlink. Refuses when
-- a restoration entry already exists for the refund: a posted
-- restoration cannot be undone by unlinking.
-- ---------------------------------------------------------------------
create or replace function public.unlink_refund(p_refund_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref transactions%rowtype;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into v_ref from transactions where id = p_refund_id;
  if not found then raise exception 'refund not found'; end if;
  if not exists (select 1 from household_members
                 where household_id = v_ref.household_id and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  if v_ref.kind <> 'refund' then raise exception 'not a refund'; end if;
  if v_ref.original_purchase_id is null then raise exception 'refund is not linked'; end if;
  if exists (select 1 from restoration_entries where refund_transaction_id = p_refund_id) then
    raise exception 'this refund already restored a week — it cannot be unlinked';
  end if;
  update transactions set original_purchase_id = null where id = p_refund_id;
end;
$$;
revoke execute on function public.unlink_refund(uuid) from public;
grant execute on function public.unlink_refund(uuid) to authenticated;
