# Integrations — Plaid + Gmail (started Nov 1, 2026)

Status: owner-approved to pursue both. **No bank connected, no mail
forwarded** — the steps below that need the owner's own logins are the
owner's steps. Everything the agent can prepare without those logins is
prepared here.

## Owner decision, Nov 1, 2026 — Plan B for Gmail (supersedes the dedicated-inbox plan)

The owner chose **Plan B: ingest directly from the personal Gmail
account (ycfried1@gmail.com), no dedicated inbox, no forwarding**, because
it is simpler to set up and use. The dedicated-inbox plan in section B
below is therefore **deferred, not active** — do not create a dedicated
inbox or a forwarding address unless the owner reverses this decision.

Tradeoff the owner accepted with Plan B: the ingestion script runs in
the personal account instead of an isolated inbox. Mitigation, kept in
the template: the script's search query returns **only** threads matching
the Amex Large Purchase alert sender/subject, it labels what it sends
so nothing is re-sent, and the backend still checks
Authentication-Results, dedupes, and marks everything PROVISIONAL.
Nothing else in the mailbox is read, forwarded, or sent anywhere. The
owner may switch back to a dedicated inbox at any time; the matcher and
backend do not depend on which mailbox the alert came from.

## Important architecture note (read first)

GitHub Pages is static hosting. It **cannot** hold a Plaid secret key, and
it cannot safely exchange a Plaid public token for an access token — doing
that in browser code would expose the secret key to anyone who opens the
page. So a real Plaid connection needs a small backend (the Supabase
project from NEXT_STEPS.md, using an Edge Function that holds the secret
key server-side). Plaid Trial being free does not remove that requirement;
it only removes the Plaid-side fee while on Trial.

Practical order:
1. Owner creates the Plaid dashboard account + Trial application (below).
2. Owner creates the Supabase project (Free to start; Pro $25/month if the
   1-week pause behaviour is unacceptable — owner's call, see NEXT_STEPS).
3. Agent builds the Edge Function: create Link token → exchange public
   token → store access token server-side only → `/transactions/sync` →
   run the existing matcher → provisional transactions in the shared DB.
4. Owner connects Amex through Plaid Link (their own Amex login/consent).
   The agent never sees Amex credentials.

Until step 3–4 are done, **CSV import + Gmail alerts remain the supported
modes**. Nothing here claims a live bank connection.

## A. Plaid — owner's phone checklist

Do these on your phone, in order. Stop and tell me the result at any step
that asks for something unexpected (especially anything asking for payment).

1. Go to dashboard.plaid.com and create an account with your own email.
   Verify the email.
2. On the dashboard homepage, open the **Trial plan** application
   (dashboard.plaid.com/trial-plan). Trial is free for new US/Canada
   teams, capped at 10 connected Items (accounts). One Amex account fits.
3. In the application, request the **Transactions** product only for this
   use case. Do **not** add Auth or Transfer to the same Link flow —
   Plaid's own troubleshooting docs say that excludes credit-card
   accounts from the result.
4. Tell me: (a) Trial approved or pending? (b) the exact wording if it
   asks about pricing or a paid plan. If it asks for a card or payment
   method, stop — Trial should not need one, and we check before paying
   anything.
5. Do **not** connect Amex yet. The Link connection happens after the
   backend in step 3 above exists, so the secret key has a safe home.
   Connecting early through a demo page would not feed this app.

What to verify in the dashboard (Phase 0, per spec): Trial eligibility
for your team, Amex coverage for this account type, whether the Amex
account plus its second card number appear as one Item or two, and the
Transactions sync behaviour (pending → posted handling, webhooks).

## B. Gmail — Plan B (active): direct ingestion from the personal account

You do this in your own Gmail; the agent never touches your Gmail
settings. No forwarding address is added and forwarding stays disabled.

1. In your personal Gmail, the Apps Script poller (template in
   `integrations/gmail-apps-script.gs`, Plan B version) is installed
   bound to that account, with its search query tightened to the exact
   Amex Large Purchase alert sender/subject once a real alert has been
   inspected.
2. Add a time-driven trigger (e.g. every 10 minutes). The script sends
   only matching alert fields to the backend, labelled as processed so
   nothing is re-sent.
3. Make one small real purchase (or wait for the next one) and check:
   does the backend receive it, with headers intact? The live parser is
   gated on inspecting a real alert, not a sample.
4. The backend still checks Authentication-Results (SPF/DKIM), dedupes,
   and marks everything PROVISIONAL; anything unparseable is
   quarantined and creates nothing.

## B-old. Gmail forwarding — DEFERRED (dedicated-inbox plan, not active)

You do this in your own Gmail; the agent never touches your Gmail
settings. You need two inboxes: your personal Gmail (unchanged, stays the
primary destination for Amex alerts) and one **new dedicated Gmail**
that receives only forwarded copies.

1. Create the dedicated Gmail account (free). Note its address — that is
   the only address you will ever need to share with me for this step,
   and only if you want me to write the Apps Script for it.
2. In your **personal** Gmail: Settings → See all settings → Forwarding
   and POP/IMAP → Add a forwarding address → enter the dedicated
   address. Gmail sends a verification code to the dedicated inbox.
3. Open the dedicated inbox, confirm the forwarding address (enter the
   code in your personal Gmail). Until this is confirmed, forwarding
   will not work — this is the step most setups get stuck on.
4. In your personal Gmail, create a filter that matches **only** Amex
   Large Purchase alerts (filter on the Amex alert sender and the alert
   subject wording you actually receive) and set its action to Forward
   to the dedicated address. **Do not forward all mail.**
5. Make one small real purchase (or wait for the next one) and check:
   does a copy arrive in the dedicated inbox, with its headers intact?
   Tell me yes/no — the ingestion build is gated on inspecting a real
   forwarded alert's headers, not on a sample I invent.
6. Never trust the From header alone: the ingestion side (below) checks
   Authentication-Results (SPF/DKIM) before accepting anything as an
   Amex alert, and anything unparseable goes to quarantine, creating
   nothing.

## C. What the agent prepared (no secrets, no live connections)

- `integrations/gmail-apps-script.gs` — a template Apps Script poller
  for the dedicated inbox. It is a template only: the webhook URL and
  shared secret are placeholders you fill in when the backend exists.
  It sends signed HTTPS events and never forwards mail content beyond
  the alert fields the matcher needs.
- The existing matcher rules already in the app (dedupe by stable hash,
  provisional ≠ confirmed, pending → posted reconciliation, refunds as
  separate credits, absent alert ≠ no spending) are the rules the live
  ingestion must follow. A real forwarded alert must be inspected before
  the parser is trusted on it.

## D. What is NOT done, and why

- No Plaid dashboard account, Trial application, or Amex Item exists.
  Those need the owner's identity, email verification, and consent.
- No Supabase project exists yet. It is the backend Plaid needs, and
  creating it is an owner-account decision (see NEXT_STEPS.md).
- No Gmail forwarding is configured. That is the owner's Gmail setting.
- No secret keys, tokens, or card numbers are in this repo, in chat, or
  in any file. If a future step ever asks for one in chat, refuse it
  and use the secure flow instead.
