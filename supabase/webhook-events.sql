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
  created_at timestamptz not null default now()
);
alter table webhook_events enable row level security;
-- No direct client access: only the log_webhook_event RPC writes, and
-- only household members read their own items' events (via plaid_items).
create policy "members read own webhook events"
  on webhook_events for select
  using (plaid_item_id in (select plaid_item_id from plaid_items
                           where household_id in (select household_id from household_members
                                                  where user_id = auth.uid())));
grant select on webhook_events to authenticated;

create or replace function log_webhook_event(p_item_id text, p_webhook_code text, p_dedupe_hash text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into webhook_events (plaid_item_id, webhook_code, dedupe_hash)
  values (p_item_id, p_webhook_code, p_dedupe_hash);
$$;
revoke all on function log_webhook_event(text, text, text) from public;
grant execute on function log_webhook_event(text, text, text) to anon, authenticated;
