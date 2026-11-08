-- Household Budget — webhook events (Nov 1, 2026).
-- WHY: Plaid webhooks need a durable, replay-protected record so the
-- live app can auto-sync on its next refresh. plaid-webhook verifies
-- the Plaid signature first, then calls log_webhook_event; the RPC is
-- SECURITY DEFINER so the anon-keyed function can append the event
-- without any client ever writing this table directly. Duplicates
-- (Plaid retries) are rejected by the unique hash. No token, secret,
-- or card data is ever stored here — only the Plaid item id, the
-- webhook code, and a dedupe hash.
create table if not exists webhook_events (
  id uuid primary key default gen_random_uuid(),
  plaid_item_id text,
  webhook_code text not null,
  dedupe_hash text not null unique,
  processed boolean not null default false,
  household_id uuid references households(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists webhook_events_household_id_idx
  on webhook_events (household_id);
alter table webhook_events enable row level security;
-- No direct client access: only the log_webhook_event RPC writes, and
-- only household members read their own household's events.
-- (P1-B2, Nov 8, 2026: the policy used to resolve membership through
-- a plaid_items subquery, which 03-plaid-vault.sql made unreadable
-- to members — the client read could never return a row. Direct
-- household_id check now; see webhook-events-household-id.sql for
-- the live migration.)
create policy "members read own webhook events"
  on webhook_events for select
  using (household_id in (select household_id from household_members
                          where user_id = auth.uid()));
grant select on webhook_events to authenticated;

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
grant execute on function log_webhook_event(text, text, text) to anon, authenticated;
