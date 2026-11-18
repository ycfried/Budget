-- =====================================================================
-- P1-B2 migration — webhook_events gains household_id (Nov 8, 2026).
-- WHY: the "members read own webhook events" policy resolved
-- membership through a plaid_items subquery, but
-- supabase/03-plaid-vault.sql revoked member SELECT on plaid_items —
-- so the client read in live.js autoSyncIfWebhookPending() could
-- never return a row and the webhook-triggered refresh sync was
-- dead (only the hourly cron recovered, up to 1h late). The fix is
-- a direct household_id column, populated by log_webhook_event via
-- an item lookup (the RPC is SECURITY DEFINER, so the lookup works),
-- with a direct membership policy that touches no other table.
--
-- APPLY: run this whole file in the Supabase SQL editor, once.
-- Idempotent: column/index/policy/RPC are all guarded. The backfill
-- covers events logged before this migration. Keep in sync with
-- supabase/webhook-events.sql, which is the canonical definition
-- for a fresh setup.
-- =====================================================================

alter table webhook_events
  add column if not exists household_id uuid references households(id) on delete cascade;

create index if not exists webhook_events_household_id_idx
  on webhook_events (household_id);

-- Backfill events logged before the column existed.
update webhook_events w
  set household_id = p.household_id
  from plaid_items p
  where w.household_id is null
    and p.plaid_item_id = w.plaid_item_id;

-- The old policy resolved membership via plaid_items, which members
-- can no longer read (03-plaid-vault.sql). Replace it with a direct
-- household membership check.
drop policy if exists "members read own webhook events" on webhook_events;
create policy "members read own webhook events"
  on webhook_events for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));

-- log_webhook_event now stamps the household_id at insert time, from
-- the item lookup. Signature unchanged (3 args), so the plaid-webhook
-- Edge Function needs no change. An event for an unknown item_id
-- still inserts (household_id NULL) and stays invisible to clients
-- rather than failing the webhook.
create or replace function log_webhook_event(p_item_id text, p_webhook_code text, p_dedupe_hash text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into webhook_events (plaid_item_id, webhook_code, dedupe_hash, household_id)
  values (p_item_id, p_webhook_code, p_dedupe_hash,
          (select household_id from plaid_items where plaid_item_id = p_item_id limit 1));
$$;
revoke all on function log_webhook_event(text, text, text) from public;
revoke execute on function log_webhook_event(text, text, text) from authenticated;
revoke execute on function log_webhook_event(text, text, text) from anon;
-- P1-B8 (Nov 8, 2026): service_role ONLY. The only caller is the
-- plaid-webhook Edge Function, which uses the service-role key
-- (plaid-webhook/index.ts:110-112) after verifying the Plaid JWT.
-- The old anon/authenticated grant (copied from the original file)
-- would have let any client record fake webhook events; 07-service-
-- rpc-access.sql already revoked it — this migration must not
-- re-grant it. If this file is applied before 07, 07's grants still
-- win on its own apply; if applied after, this line keeps them.
grant execute on function log_webhook_event(text, text, text) to service_role;

-- VERIFICATION (run after applying, read-only):
--   select column_name from information_schema.columns
--    where table_name = 'webhook_events' and column_name = 'household_id';  -- 1 row
--   select polname, pg_get_expr(polqual, 'webhook_events'::regclass)
--    from pg_policy where polrelid = 'webhook_events'::regclass;
--     -- the select policy must mention household_id, NOT plaid_items
--   select count(*) from webhook_events where household_id is null;  -- 0 for known items
