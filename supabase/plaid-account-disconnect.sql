-- plaid-account-disconnect.sql — Connected accounts rework (owner, Nov 4, 2026)
-- Per-account disconnect: each bank account gets its own Disconnect,
-- instead of one Disconnect per Plaid item (which removed the whole
-- bank connection). Plaid has no per-account removal, so this is
-- app-level: plaid_accounts.disconnected_at is set by the
-- plaid-account-disconnect Edge Function, plaid-sync skips that
-- account's transactions, and past transactions stay untouched.
--
-- APPLIED live Nov 4, 2026 (PR #45, verified via information_schema).
-- Re-running is idempotent (add column if not exists).
--   * Adds ONE nullable timestamp column; no rows are changed, no
--     rows are deleted, no grants or RLS policies are changed.
--   * The column is written ONLY by the service-role Edge Function
--     (admin-only, JWT-checked). No client write path is added: the
--     existing member update policy on plaid_accounts predates this
--     column and the client never writes it directly.
--   * The /accounts/get upsert in plaid-sync does not list this
--     column, so a later sync never clears a disconnect flag.
--   * Backfill: none needed — NULL means connected, which is every
--     existing account's current state.

alter table plaid_accounts
  add column if not exists disconnected_at timestamptz;
