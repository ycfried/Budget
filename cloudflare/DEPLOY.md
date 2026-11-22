# Deploy: Supabase Auth reverse proxy on auth.getstag.us

Purpose: serve Supabase Auth from `auth.getstag.us` instead of
`https://tnkhvdkmwmwiogiienee.supabase.co`, so Google's sign-in screen
shows getstag.us rather than the Supabase address. Free bypass for
Supabase Pro's custom domain ($25/mo). Owner-approved Nov 21, 2026.

## Status (Nov 21, 2026)

- Worker code written and syntax-checked: `supabase-auth-proxy.js`
  (in this folder). Node `--check` passes.
- BLOCKED on deploy: the stored Cloudflare API token
  (label "frosty-forest-ef5b") has DNS Edit + Zone Read only.
  It returns 403 on Workers script upload and on listing zone
  Workers routes. It cannot create a Worker or a route.
- Supabase Auth endpoint verified live (baseline): a bare request to
  `https://tnkhvdkmwmwiogiienee.supabase.co/auth/v1/health`
  returns 401 `UNAUTHORIZED_MISSING_API_KEY` with
  `sb-project-ref: tnkhvdkmwmwiogiienee` — the gateway responds.
- DNS: no `auth` record exists yet in getstag.us. Do NOT create it
  until the Worker + route exist (see below).
- App-side change NOT made (needs a build; build 53 already running
  separately). See "App-side change" below.
- Google OAuth callback NOT added (needs Google Cloud Console).
  See "Google OAuth" below.

## Unblock: new Cloudflare API token

The owner must create a new API token in the Cloudflare dashboard
(on their own device — the dashboard blocks the cloud browser) with
these permissions, scoped to the getstag.us zone (and the account
for Workers Scripts):
- Workers Scripts: Edit
- Workers Routes: Edit
- Zone: DNS Edit (already had) + Zone Read (already had)

Then register it via the secure credential flow
(`credentials.request_api_access`, provider `cloudflare`,
reconnect). Once the new token is in place, run the deploy steps
below with the same helpers (the `cf.py` credential exchange picks
up the registered token).

## Deploy steps (once the token has Workers permissions)

All calls use `https://api.cloudflare.com/client/v4` with the
Bearer token. Zone ID `4a58b5fa388a6181fb954f1a6cdd4cba`,
account ID `d5dc2dd2fd8ac689fc619fbf76fc99d0`.

1. Upload the Worker script (ES module, multipart/form-data).
   Script name: `supabase-auth-proxy`.
   - PUT `/accounts/{account_id}/workers/scripts/supabase-auth-proxy`
   - Multipart parts:
     - `metadata` (application/json):
       `{"main_module": "worker.js", "compatibility_date": "2026-11-21"}`
     - `worker.js` (application/javascript+module): the contents of
       `supabase-auth-proxy.js`.
   - Expect `success: true` and the script metadata back.

2. Create the route so `auth.getstag.us/*` hits the Worker.
   - POST `/zones/{zone_id}/workers/routes`
   - Body: `{"pattern": "auth.getstag.us/*", "script": "supabase-auth-proxy"}`
   - Expect `success: true`.

   (Alternative: Workers Custom Domains — attach `auth.getstag.us`
   as a custom domain to the Worker via
   `PUT /accounts/{account_id}/workers/domains`
   `{"hostname": "auth.getstag.us", "service": "supabase-auth-proxy"}`.
   Either routing method works; the zone route above is the
   straightforward one for a hostname in this zone.)

3. Create the DNS record for the Worker route.
   - POST `/zones/{zone_id}/dns_records`
   - Body: `{"type": "AAAA", "name": "auth", "content": "100::",
     "ttl": 1, "proxied": true}`
   - This is the standard placeholder for a Worker-routed hostname.
   - (If using Workers Custom Domains instead, Cloudflare provisions
     the routing automatically; skip this manual record.)

4. Verify the proxy (no keys needed for the gateway check).
   - `curl -s -i https://auth.getstag.us/auth/v1/health`
     Expect the same shape as the direct Supabase call: HTTP 401
     with `sb-project-ref: tnkhvdkmwmwiogiienee` and
     `sb-error-code: UNAUTHORIZED_MISSING_API_KEY`. That proves the
     request reached the Supabase gateway through the Worker.
   - `curl -s -o /dev/null -w "%{http_code}\n" https://auth.getstag.us/auth/v1/`
     Expect 401 (same as direct).
   - Confirm a redirect rewrite: request an endpoint that issues a
     Supabase-hosted redirect and confirm the `Location` header
     points at `auth.getstag.us`, not `tnkhvdkmwmwiogiienee.supabase.co`.
   - Only after the above pass, test a real sign-in from the app
     (after the app-side change below ships).

## App-side change (needs a new build — do NOT push a build here)

The Supabase URL is a compile-time constant, so this cannot be done
without a new build.

File: `ios-clone/OnBudgetKit/Sources/OnBudgetKit/Configuration.swift:13`
```swift
public static let supabaseURL = "https://tnkhvdkmwmwiogiienee.supabase.co"
```
It feeds `SupabaseConfiguration.live` (`SupabaseClient.swift:43`),
which derives `authBaseURL` (base + `auth/v1`), `restBaseURL`
(base + `rest/v1`), and `functionsBaseURL` (base + `functions/v1`).
So the single baseURL drives auth, database, and Edge Functions.

Recommended (auth-only, smallest blast radius): add a separate auth
URL constant and use it only for `authBaseURL`, keeping `restBaseURL`
and `functionsBaseURL` on `supabase.co`. Then only sign-in/OAuth
depends on the Worker; data keeps going direct to Supabase.

Simpler one-liner (whole baseURL): change `supabaseURL` to
`"https://auth.getstag.us"`. Then ALL Supabase traffic (auth, rest,
functions) goes through the Worker. The Worker already supports this
(it swaps only the host and keeps the path), but if the Worker ever
fails, the whole app's data path breaks, not just sign-in.

Either way, the change ships in a future build (not build 53,
already running). Do not deploy an app build from this task.

## Google OAuth

Google Cloud project "OnBudget" (onbudget-513504). Add this Authorized
redirect URI to the OAuth 2.0 client (Google Cloud Console → APIs &
Services → Credentials → the OAuth client → Authorized redirect URIs):
- `https://auth.getstag.us/auth/v1/callback`

This is the Supabase Auth Google sign-in callback on the custom
domain. Do NOT change the OAuth consent screen app name here — the
owner is handling that separately.

Note (Nov 22, 2026 — DONE in code, pending deploy + Google registration): the Gmail connect flow does NOT use
Supabase Auth's callback. It uses a custom Edge Function callback,
now set in `supabase/functions/gmail-oauth-start/index.ts` and
`gmail-oauth-callback/index.ts` to the branded URL (the Worker
forwards `/functions/v1/*` unchanged):
- `https://auth.getstag.us/functions/v1/gmail-oauth-callback`
Add this as an Authorized redirect URI in the Google OAuth client
"STAGE" BEFORE the updated Edge Functions deploy — until it is
registered, Google rejects the new redirect_uri and Gmail connect
breaks. Do NOT remove the old supabase.co callback URI until the
new one is verified working:
- `https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/gmail-oauth-callback`

## Risks

- Unofficial: Supabase does not support proxying Auth this way. If
  Supabase changes its auth endpoints, cookie handling, or gateway
  behaviour, sign-in can break until this Worker is updated.
- Blast radius: auth-only routing (recommended) limits a Worker
  outage to sign-in/OAuth. Whole-baseURL routing would take down
  all data access too.
- Test a real Google sign-in from the app after the app-side change
  ships, before treating this as done. Do not call it verified on
  the proxy health check alone.
- No money was spent and Supabase was NOT upgraded to Pro.
- No live household data or database was touched.
