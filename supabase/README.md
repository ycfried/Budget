# Supabase backend — plan (Free plan, owner decision Nov 1, 2026)

## What Free gives, and its one catch

Free: $0, 500 MB Postgres, 50,000 monthly active users, 5 GB egress,
1 GB file storage, up to 2 active projects. For 2 users and a few
hundred transactions a month, that is far more than enough capacity.

The catch, from Supabase's published terms: **a free project pauses
after 1 week of inactivity** and must be restored before it serves
again. A household that uses the app weekly will usually stay active,
but a skipped week (holiday, etc.) can pause it — restoring is a
dashboard click, not data loss, but it is a manual step. If that ever
becomes annoying, the upgrade path is Pro at $25/month, which removes
pausing. No upgrade is approved by this plan; it is a future owner call.

## Build order once the project exists

1. Owner creates the project (Free plan) and the two user accounts
   (owner = admin, spouse = member) via Supabase Auth. The owner does
   this in the dashboard; the agent never creates user accounts.
2. Owner runs `supabase/schema.sql` in the SQL editor (or tells the
   agent the project is ready and hands over the SQL-editor step on
   takeover). That creates households, members, transactions, fund
   requests, savings ledger, audit log, and plaid_items, with Row Level
   Security so a user only ever sees their own household's rows.
3. Agent builds the Edge Functions (in this folder, when the project
   exists):
   - `compute-week` — runs engine.mjs server-side; the single source
     of truth for allowance, debt, surplus, and fund numbers.
   - `plaid-link` — creates a Plaid Link token (secret key stays in
     Edge Function secrets, never in the repo or the browser).
   - `plaid-exchange` — exchanges the public token, stores only the
     Plaid item id + sync cursor (never the access token in the DB).
   - `plaid-sync` — calls `/transactions/sync`, runs the existing
     matcher (dedupe, pending → posted, refunds), writes provisional
     transactions.
   - `ingest-amex-alert` — verifies the HMAC signature from the Gmail
     Apps Script (Plan B: personal account, Amex-alerts-only search),
     checks Authentication-Results, quarantines anything unparseable.
4. The Pages PWA is pointed at the Supabase project (URL + anon key
   only — the anon key is safe to ship; RLS + Edge Functions enforce
   roles). The demo localStorage data is replaced by the shared DB,
   so both phones finally see the same budget.
5. Plaid Link connection happens last, by the owner in their own Amex
   login, requesting Transactions only.

## What is NOT in this plan

- No paid Supabase plan, no card, no billing change.
- No Plaid access token in the database, the repo, or the browser.
- No automatic fund release on the FIN-REFUND-001 interpretation.
- No user accounts created by the agent.
