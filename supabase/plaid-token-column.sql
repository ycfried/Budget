-- Household Budget — encrypted Plaid token storage (run after schema.sql).
--
-- DO NOT RE-APPLY THIS FILE (P1-B8, Nov 8, 2026). Its two RPC
-- definitions grant EXECUTE to authenticated with member-level
-- bodies — re-applying it reopens member access to the Plaid vault
-- (any household member could read any household's Plaid
-- ciphertext, audit P0-4). The CANONICAL vault state is
-- supabase/07-service-rpc-access.sql (service_role-only bodies and
-- grants, applied after this file). If a future probe shows the old
-- bodies/grants live, apply 07-service-rpc-access.sql immediately —
-- that is a P0 escalation, not a routine apply. The column + policy
-- section above the RPCs is also superseded: 03-plaid-vault.sql
-- revoked member SELECT on plaid_items and 07 revoked member
-- INSERT/UPDATE; do not re-add them.
-- WHY: plaid-exchange was blocked because there was nowhere safe to put
-- the Plaid access token. This is the vault that can be built today
-- with no new service: the token is stored AES-GCM-encrypted, with the
-- key held ONLY in Edge Function secrets (PLAID_TOKEN_KEY, never in
-- the repo, chat, or database). Only service-role functions can read
-- this column (there is deliberately NO select policy granting it to
-- authenticated users — the client must never see a token, encrypted
-- or not), and plaid-sync decrypts it in memory only, never logs it,
-- never returns it.
-- Plaintext tokens are NEVER stored. If this column ever needs to move
-- to a dedicated vault later, only the two functions change; the app's
-- Link flow does not.

alter table plaid_items
  add column if not exists access_token_encrypted text;

-- No client INSERT/UPDATE grant games here: the exchange function runs
-- with the caller's own JWT (anon client), so it needs an insert policy
-- for plaid_items, restricted to the caller's own household. The
-- ciphertext itself is useless without PLAID_TOKEN_KEY, which lives
-- only in Edge Function secrets.
create policy "members insert own plaid items"
  on plaid_items for insert
  with check (household_id in (select household_id from household_members
                               where user_id = auth.uid()));

-- RPCs for plaid-sync, so no function ever needs the legacy service
-- role key (which proved broken in this project on Nov 1 — see
-- bootstrap-household). Both run SECURITY DEFINER, act only for a
-- caller who belongs to the household, and touch nothing else.
create or replace function public.get_plaid_ciphertext(p_household_id uuid, p_item_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  ct text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid()) then
    raise exception 'not a household member';
  end if;
  select access_token_encrypted into ct from plaid_items
    where household_id = p_household_id and plaid_item_id = p_item_id;
  return ct;
end;
$$;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from public;
grant execute on function public.get_plaid_ciphertext(uuid, text) to authenticated;

create or replace function public.update_plaid_sync(p_household_id uuid, p_item_id text, p_cursor text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from household_members
                 where household_id = p_household_id and user_id = auth.uid()) then
    raise exception 'not a household member';
  end if;
  update plaid_items
    set sync_cursor = p_cursor, last_sync_at = now()
    where household_id = p_household_id and plaid_item_id = p_item_id;
end;
$$;
revoke execute on function public.update_plaid_sync(uuid, text, text) from public;
grant execute on function public.update_plaid_sync(uuid, text, text) to authenticated;
