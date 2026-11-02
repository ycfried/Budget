-- 07-service-rpc-access.sql — coordinator integration migration (audit-fixes branch)
--
-- WHY THIS FILE EXISTS: S1's vault hardening (03-plaid-vault.sql) revoked
-- get_plaid_ciphertext / update_plaid_sync from every member role, and the
-- original function bodies reject any caller with auth.uid() IS NULL.
-- The Plaid Edge Functions (plaid-sync, plaid-webhook-register,
-- plaid-disconnect) now call these RPCs with the SERVICE-ROLE key
-- (server-side only, never in the browser) after verifying the caller's
-- membership/admin role from their JWT. A service-role JWT has no
-- auth.uid(), so the original bodies would raise 'not authenticated',
-- and without an explicit grant the service role cannot execute them at
-- all. This migration fixes both halves WITHOUT re-opening member access:
--
--   * get_plaid_ciphertext accepts service_role ONLY (reaudit N2, Nov 2,
--     2026: the old membership branch was unreachable but a future
--     re-grant would have silently reopened P0-4, so it is deleted).
--     update_plaid_sync keeps its membership path (sync-state writes).
--   * EXECUTE is granted to service_role ONLY. Authenticated members are
--     NOT re-granted (that would reopen audit P0-4 / P1-16).
--   * log_webhook_event is granted to service_role, and its authenticated
--     grant is removed: only the verified plaid-webhook function (service
--     key, after Plaid JWT verification) may record webhook events.
--
-- DEPLOY ORDER: apply AFTER 01-06 and S2's restoration-snapshots.sql,
-- BEFORE deploying any Edge Function. The functions fail loudly (503
-- 'service key not configured' or RPC errors) if this file is skipped.
--
-- -----------------------------------------------------------------------
-- get_plaid_ciphertext: service_role ONLY (reaudit N2, Nov 2, 2026)
-- -----------------------------------------------------------------------
create or replace function public.get_plaid_ciphertext(p_household_id uuid, p_item_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  ct text;
begin
  -- The old membership branch is deleted, not just unreachable: it let
  -- any authenticated member read any household's Plaid ciphertext if
  -- EXECUTE were ever re-granted. All live callers (plaid-sync,
  -- plaid-webhook-register, plaid-disconnect) use the service-role key.
  if auth.role() <> 'service_role' then raise exception 'service role only'; end if;
  select access_token_encrypted into ct from plaid_items
    where household_id = p_household_id and plaid_item_id = p_item_id;
  return ct;
end;
$$;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from public;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from authenticated;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from anon;
grant execute on function public.get_plaid_ciphertext(uuid, text) to service_role;

-- -----------------------------------------------------------------------
-- update_plaid_sync: service_role path + membership path
-- -----------------------------------------------------------------------
create or replace function public.update_plaid_sync(p_household_id uuid, p_item_id text, p_cursor text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() = 'service_role' then
    update plaid_items
      set sync_cursor = p_cursor, last_sync_at = now()
      where household_id = p_household_id and plaid_item_id = p_item_id;
    return;
  end if;
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
revoke execute on function public.update_plaid_sync(uuid, text, text) from authenticated;
revoke execute on function public.update_plaid_sync(uuid, text, text) from anon;
grant execute on function public.update_plaid_sync(uuid, text, text) to service_role;

-- -----------------------------------------------------------------------
-- log_webhook_event: service_role only (verified webhook function path)
-- -----------------------------------------------------------------------
revoke execute on function public.log_webhook_event(text, text, text) from authenticated;
grant execute on function public.log_webhook_event(text, text, text) to service_role;

-- -----------------------------------------------------------------------
-- plaid_items member writes: revoked (functions now use the service key)
-- -----------------------------------------------------------------------
-- After the coordinator integration patches, every Edge Function that
-- touches plaid_items (plaid-sync, plaid-exchange, plaid-disconnect,
-- plaid-webhook-register) verifies the caller from their JWT and then
-- writes through the service-role client. No client code writes
-- plaid_items directly (verified by grep over live.js/app.js), so the
-- member INSERT/UPDATE grants are dead weight plus a ciphertext-
-- overwrite risk (audit P1-16's remaining half). Revoking them here
-- closes that risk without breaking any function. SELECT on plaid_items
-- stays revoked for members as well (03-plaid-vault); clients read the
-- plaid_items_public view instead.
revoke insert, update on table public.plaid_items from authenticated;

-- Verification (run after applying; all three must return one row each):
--   select proname from pg_proc where proname in
--     ('get_plaid_ciphertext', 'update_plaid_sync', 'log_webhook_event');
--   select grantee, privilege_type from information_schema.routine_privileges
--     where routine_name in ('get_plaid_ciphertext', 'update_plaid_sync',
--                            'log_webhook_event')
--     order by routine_name, grantee;
-- Expected: service_role has EXECUTE on all three; authenticated has
-- EXECUTE on none of the three.
