-- =====================================================================
-- S1 migration 03 — Plaid vault: hide the token ciphertext from clients
-- Deploy order: THIRD of the five S1 files (01..05).
-- Depends on: schema.sql, plaid-token-column.sql, fix-grants.sql
--   (plaid_items + access_token_encrypted + the two RPCs exist).
--
-- What this fixes (audit):
--   P0-4  Any member could SELECT access_token_encrypted (fix-grants
--         SELECT grant + "members read own plaid items" policy covered
--         ALL columns), and could call get_plaid_ciphertext() with a
--         mere membership check.
--   P1-16 (grant half) get_plaid_ciphertext / update_plaid_sync were
--         member-granted, so a member could overwrite the sync cursor
--         and silently skip syncs. Both are restricted here to the
--         service-role path (see DEPLOY DEPENDENCY — this breaks the
--         current caller-JWT sync calls until sync is re-keyed).
--
-- How the view enforces membership WITHOUT a base-table grant:
--   Postgres views run as the view OWNER by default (not the caller),
--   so RLS on plaid_items is bypassed inside the view. The view
--   therefore carries its own membership predicate
--   (household_id IN (SELECT ... WHERE user_id = auth.uid())).
--   Revoking base-table SELECT from authenticated plus granting
--   SELECT on the view gives members exactly the non-secret columns
--   of their own household's items — and no path to the ciphertext
--   through PostgREST. (A security_invoker view was NOT used: it
--   would require the caller to hold SELECT on the base table,
--   which is precisely the grant being revoked.)
--
-- DEPLOY DEPENDENCY — read before deploying:
--   plaid-sync and plaid-webhook-register currently call
--   get_plaid_ciphertext / update_plaid_sync with the CALLER's JWT
--   (anon key + Authorization header). After the revokes in §3,
--   those calls FAIL for every member, including admins. Before
--   deploying §3, plaid-sync must be re-keyed to call these RPCs
--   with the service-role key (the brief states the sync Edge
--   Function uses the service-role key). Note the tension the
--   parent must resolve: the repo's Nov 1 notes record the legacy
--   service-role key as broken/deprecated for this project
--   ("Use SUPABASE_SECRET_KEYS issued through JWT Signing Keys
--   instead" — see create-household-rpc.sql). If no working
--   service-role credential exists, §3 must NOT deploy until that
--   credential path is proven, or Plaid sync stops entirely.
--   This migration does NOT invent or store any key.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Revoke base-table SELECT from clients. From here on, no
--    authenticated caller can SELECT plaid_items at all — including
--    its non-secret columns. All client reads go via the view in §2.
--    (The table owner and service role are unaffected by REVOKEs
--    from authenticated; SECURITY DEFINER functions likewise run
--    as the owner.)
-- ---------------------------------------------------------------------
revoke select on plaid_items from authenticated;

-- The old read policy now has no grant behind it, but leaving a
-- policy that names a column set it no longer effectively exposes
-- would be misleading. It is dropped; the view's own predicate in
-- §2 replaces it. (If any other code path relied on direct
-- plaid_items SELECT with a member JWT, it must move to the view —
-- flagged in INTERFACE.md.)
drop policy if exists "members read own plaid items" on plaid_items;

-- ---------------------------------------------------------------------
-- 2. Public view: every plaid_items column EXCEPT
--    access_token_encrypted. Column list is explicit (never SELECT
--    *) so a future column added to plaid_items is NOT silently
--    exposed — a new sensitive column would need a deliberate view
--    change to appear.
-- ---------------------------------------------------------------------
create or replace view public.plaid_items_public as
  select
    id,
    household_id,
    plaid_item_id,
    institution_name,
    institution_id,
    status,
    sync_cursor,
    last_sync_at,
    created_at
  from plaid_items
  where household_id in (select household_id from household_members
                         where user_id = auth.uid());

grant select on public.plaid_items_public to authenticated;
revoke all on public.plaid_items_public from public;

-- ---------------------------------------------------------------------
-- 3. Restrict the two Plaid RPCs to the service-role path.
--    The function BODIES are intentionally untouched (they live in
--    plaid-token-column.sql); only the grants change. After this:
--      * authenticated: NO execute on either function.
--      * public / anon: NO execute (already revoked; repeated here
--        so the state is explicit and re-runnable).
--      * NOBODY is granted execute in this file — not even a named
--        role. In Supabase/Postgres, the service-role key bypasses
--        RLS and holds broad privileges by design; the brief's rule
--        is "only the service-role key may call it", which is
--        achieved by granting it to NO member role. Do NOT add a
--        grant to authenticated, admin, or any client role here.
--    See DEPLOY DEPENDENCY at the top: plaid-sync must be re-keyed
--    before this deploys, or sync breaks.
-- ---------------------------------------------------------------------
revoke execute on function public.get_plaid_ciphertext(uuid, text) from public;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from authenticated;
revoke execute on function public.get_plaid_ciphertext(uuid, text) from anon;

revoke execute on function public.update_plaid_sync(uuid, text, text) from public;
revoke execute on function public.update_plaid_sync(uuid, text, text) from authenticated;
revoke execute on function public.update_plaid_sync(uuid, text, text) from anon;

-- NOTE — residual, flagged not hidden: plaid_items INSERT/UPDATE
-- grants and the "members insert own plaid items" / "members update
-- own plaid items" policies are LEFT in place because plaid-exchange
-- currently upserts items with the caller's JWT. A member therefore
-- still cannot READ the ciphertext (revoked above) but could
-- OVERWRITE a row's ciphertext with garbage and break that item's
-- sync. Closing that needs plaid-exchange on the service-role path
-- too — owed work for the parent, listed in INTERFACE.md. Do not
-- revoke those grants here without that path, or Link/exchange
-- breaks at the same deploy.

-- =====================================================================
-- VERIFICATION (commented — run manually after deploy):
--   -- View exposes no ciphertext column:
--   select column_name from information_schema.columns
--     where table_name = 'plaid_items_public' order by ordinal_position;
--     -- must NOT include access_token_encrypted; must include id,
--     -- household_id, plaid_item_id, institution_name, sync_cursor,
--     -- last_sync_at, created_at.
--   -- Base table unreadable by clients:
--   select has_table_privilege('authenticated', 'plaid_items',
--     'SELECT');  -- false
--   select has_table_privilege('authenticated',
--     'plaid_items_public', 'SELECT');  -- true
--   -- RPCs callable by no member role:
--   select has_function_privilege('authenticated',
--     'get_plaid_ciphertext(uuid,text)', 'EXECUTE');  -- false
--   select has_function_privilege('authenticated',
--     'update_plaid_sync(uuid,text,text)', 'EXECUTE');  -- false
--   -- As a household member, reading the view returns only rows of
--   -- households the caller belongs to (membership predicate):
--   select count(*) from plaid_items_public;  -- own households only
-- =====================================================================
