# Next steps — researched Nov 1, 2026 (no accounts created, nothing connected)

## 1. Do we need Supabase? Short answer: not yet — yes, later, for sharing

- **Right now, no.** The live Pages site works without any backend. It is a
  preview: each phone stores its own copy in its own browser.
- **For one shared household budget (owner + spouse seeing the same numbers),
  yes, a backend is required.** Supabase is the natural fit from the spec:
  managed Postgres + Auth + Row Level Security, with `household_id` on every
  row so one household can never see another's data. The engine (engine.mjs)
  stays the same; it just runs against server-side data instead of
  per-device localStorage, and role checks move to the server / RLS policies.
- **Cost check (third-party summaries of Supabase's published rates, Sep–Oct
  2026):** Free plan is $0 — 500 MB Postgres, 50,000 monthly active users,
  5 GB egress, 1 GB file storage, up to 2 active projects — but **free
  projects pause after 1 week of inactivity** and must be restored before
  they serve again. That pause alone makes Free a poor fit for a household
  app people rely on weekly. Pro is $25/month per project (8 GB database,
  100,000 MAU, 250 GB egress, $10 compute credit covering one Micro
  instance). For 2 users and a few hundred transactions a month, usage
  would sit far inside Pro's included allowances — the bill would be the
  $25 base, not usage.
- **Decision needed from the owner before any Supabase work:** create the
  project under whose account, and approve the possible $25/month Pro cost
  (vs. accepting Free's pause behaviour for a trial). No Supabase account
  or project has been created by this work.

## 2. Plaid — what the docs actually say (read-only research, no signup)

- **Trial plan exists and is free for new US/Canada teams** (created on or
  after Apr 15, 2026): real production data, capped at **10 Items**
  (connected accounts). One Amex account for this household is well inside
  that cap. Source: Plaid's own billing docs,
  https://plaid.com/docs/account/billing/
- **Sandbox is always free** but uses fake data only — useful for building
  the matcher, not for real spending.
- **Paid pricing is not published:** Plaid says per-product rates appear
  only on the last page of a Production application. Transactions is a
  **subscription-fee product** (recurring monthly fee per Item while it
  exists), so leaving an Amex Item connected is an ongoing cost, not a
  one-time fee. Third-party estimates put Transactions around
  $0.30–$0.60 per connection, but that is a ballpark, not a quote.
- **Amex coverage:** Plaid's Transactions product covers credit-card
  accounts, and Plaid's July 2026 update notes near-100% fill rates for
  balance/limit/statement fields across major issuers including American
  Express. One implementation trap from Plaid's own troubleshooting docs:
  do **not** request Auth/Transfer alongside Transactions in the same Link
  flow, or credit-card accounts get excluded — Transactions must be
  requested on its own.
- **Still unverified (needs the owner's own dashboard check):** Trial
  eligibility for this team, whether this specific Amex Blue Cash Everyday
  account (and its second card number) surfaces as one Item or two, and
  the actual Production rate once the application page is reached. Until
  those are checked, **CSV import + Gmail alerts remain the supported
  modes**; nothing here should be read as "Plaid is free forever."

## 3. Gmail alerts — exact setup for later (owner performs this, not the agent)

1. Create a dedicated free Gmail account for ingestion only (never the
   owner's personal Gmail as the destination).
2. In the owner's personal Gmail: Settings → Forwarding → add that
   dedicated address as a forwarding address and confirm it (Gmail sends
   a verification code to the dedicated inbox).
3. Create a filter matching Amex Large Purchase alerts only (e.g. from the
   Amex alert sender, subject containing the alert wording) → Forward it
   to the dedicated address. Do **not** forward all mail.
4. Only then does the ingestion side (Apps Script poller → signed HTTPS
   events) get built, and only against real forwarded headers — the
   parser must be re-tested against a real alert before any alert is
   trusted, and the app must keep treating alerts as provisional.

## 4. CSV import — tested Nov 1, 2026

The app's real `parseCsv` (extracted from app.js, run in Node) was fed an
Amex-style file with quoted commas, MM/DD/YYYY dates, `$123.45` amounts,
a `(15.00)` refund, a duplicate row, and one bad row. Result: **2 added,
1 duplicate skipped, 1 bad row reported (not a crash)**; a full re-import
added **0**. Dedupe works as specified.

## 5. What is still blocked on owner decisions

- FIN-REFUND-001 (refund-credit/surplus policy) — open, test skipped.
- Supabase account + Pro-vs-Free call (above).
- Gmail forwarding setup (owner's step, section 3).
- Plaid dashboard verification (owner's step, section 2).
- Native iOS app — Milestone B, only after the web product is reliable,
  built by the owner's friend under their Apple Developer account.
