-- R13 gift idempotency — APPLIED LIVE Nov 3, 2026 (Round 3, bug 8
-- fix; verified: transactions.client_key column, partial unique
-- index transactions_household_client_key_idx, 8-arg
-- record_charity_gift). The "PREPARED ONLY" header this file
-- carried before is stale (R4-BE-2, Nov 9, 2026). Do NOT re-apply
-- blindly: the DROP line below removes the 7-arg overload, which is
-- exactly what a later whole-file re-apply of supabase/r13-charity.sql
-- resurrected live on Nov 9 (R4-BE-1) — that file now carries the
-- same 8-arg copy, so the two files agree and neither can resurrect
-- the 7-arg. Re-apply only if a live probe shows the live body has
-- drifted from this file, and reconcile first.
--
-- WHY (Round 3, bug 8): a double-click on Record gift recorded the
-- same $25 gift twice and inflated Given $25 to $50, because the
-- gift flow had neither a client-side submit lock nor a server
-- idempotency key. The v23 client lock closes the double-click
-- window, but a lock is not a guarantee: a retry after a network
-- failure can still re-submit after the first insert landed. This
-- gives record_charity_gift the same client-key idempotency the
-- top-up RPC already has: the client sends one key per intended
-- gift; a replay with the same key returns the original row
-- instead of a second gift, and writes no second audit row.
--
-- REAL IDENTICAL GIFTS ARE UNAFFECTED: each fresh submit carries
-- a fresh key, and the per-submit nonce in dedupe_hash still keeps
-- two real identical gifts on one day distinct (the Nov 3 $2 case).
-- The key only collapses exact replays of one intended gift.
--
-- BACKWARD COMPATIBLE: the new parameter defaults to null, so
-- calls that do not send a key behave exactly as before (a row is
-- inserted, key null, no conflict possible). Apply this file
-- BEFORE the client that sends p_client_key goes live; the old
-- client keeps working against the new function either way.

alter table public.transactions
  add column if not exists client_key text;
create unique index if not exists transactions_household_client_key_idx
  on public.transactions (household_id, client_key)
  where client_key is not null;

drop function if exists public.record_charity_gift(uuid, text, integer, date, text, text, text);
create or replace function public.record_charity_gift(
  p_household_id uuid, p_merchant text, p_amount_cents integer, p_date date,
  p_card_suffix text, p_note text, p_dedupe_hash text, p_client_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_merchant text;
  v_suffix text;
  v_hash text;
  v_key text;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'amount must be positive'; end if;
  if p_date is null or p_date < date '2026-11-01' then raise exception 'charity starts November 2026'; end if;
  v_merchant := upper(btrim(coalesce(p_merchant, '')));
  if v_merchant = '' then raise exception 'organization is required'; end if;
  v_suffix := nullif(btrim(coalesce(p_card_suffix, '')), '');
  if v_suffix is null then v_suffix := '0000'; end if;
  if v_suffix !~ '^[0-9]{4}$' then raise exception 'card suffix must be exactly 4 digits'; end if;
  if not exists (select 1 from public.household_members
                 where household_id = p_household_id
                   and user_id = auth.uid() and role = 'admin') then
    raise exception 'admin only';
  end if;
  v_key := nullif(btrim(coalesce(p_client_key, '')), '');
  if v_key is not null then
    -- Exact replay of an intended gift: return the original row,
    -- write nothing, and never double-count Given.
    select id into v_id from public.transactions
     where household_id = p_household_id and client_key = v_key;
    if found then
      return jsonb_build_object('transaction_id', v_id, 'replayed', true);
    end if;
  end if;
  -- A gift entered by hand is explicitly confirmed by the admin
  -- entering it, so it posts as verified (Given) at once. It is
  -- kind 'charity', so it never enters weekly spending math.
  v_hash := nullif(btrim(coalesce(p_dedupe_hash, '')), '');
  if v_hash is null then
    -- Fallback only (the client always sends a hash with a per-submit
    -- nonce, so two real identical gifts on one day never collide).
    v_hash := md5('charity|' || p_date::text || '|' || v_merchant || '|' || p_amount_cents::text || '|' || v_suffix || '|' || gen_random_uuid()::text);
  end if;
  insert into public.transactions
    (household_id, date, merchant, amount_cents, card_suffix, source, state, kind, dedupe_hash, client_key)
  values (p_household_id, p_date, v_merchant, p_amount_cents, v_suffix, 'manual', 'verified', 'charity', v_hash, v_key)
  on conflict (household_id, client_key) where client_key is not null do nothing
  returning id into v_id;
  if v_id is null and v_key is not null then
    -- Lost a race with an identical key: return the row that won.
    select id into v_id from public.transactions
     where household_id = p_household_id and client_key = v_key;
    if v_id is null then raise exception 'gift idempotency conflict without a stored row'; end if;
    return jsonb_build_object('transaction_id', v_id, 'replayed', true);
  end if;
  insert into public.audit_log (household_id, actor, actor_name, action, detail)
  values (p_household_id, auth.uid(), 'admin', 'Charity gift recorded',
          'Gift ' || v_merchant || ' ' || p_amount_cents::text || ' cents on ' || p_date::text || '.');
  return jsonb_build_object('transaction_id', v_id, 'replayed', false);
end;
$$;
revoke execute on function public.record_charity_gift(uuid, text, integer, date, text, text, text, text) from public;
grant execute on function public.record_charity_gift(uuid, text, integer, date, text, text, text, text) to authenticated;

-- Verification (read-only): the new column, the partial unique
-- index, and the 8-parameter function must all exist.
select column_name from information_schema.columns
 where table_name = 'transactions' and column_name = 'client_key';
select indexname from pg_indexes
 where tablename = 'transactions' and indexname = 'transactions_household_client_key_idx';
select proname, pg_get_function_identity_arguments(oid) as args
  from pg_proc where proname = 'record_charity_gift';
