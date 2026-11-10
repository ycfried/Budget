# Native Gmail OAuth redirect — ready-to-review diff (NOT deployed)

Branch: `gmail-callback-native-redirect` (off main). Do NOT merge or
deploy from this branch without the review + steps below.

## What it changes

Two Edge Functions, and only them:

### `gmail-oauth-start/index.ts`

- Reads the request body's `client` field (the body was already
  parsed for `household_id`). The native iOS app sends
  `client: "native"`; the web sends nothing.
- For native flows the OAuth `state` sent to Google becomes
  `native:<nonce>` instead of the bare `<nonce>`. The full string
  is stored verbatim as the `nonce` in `gmail_oauth_states`
  (`nonce` is plain `text`, no format constraint), so the callback's
  lookup needs no parsing.
- The `client` marker is NOT a trust decision: the household still
  comes from the caller's verified admin membership (or the named
  one of their own admin households, as before). It only picks the
  redirect target.

### `gmail-oauth-callback/index.ts`

- New `NATIVE_APP_URL = 'onbudget://gmail-callback'` and helper
  `redirectBaseFor(state)`: a `native:`-prefixed state redirects
  to the app scheme; anything else redirects to live.html.
- `page()` takes the redirect base as a third argument (default
  live.html) and every exit path passes it — success, Google-error,
  missing code/state, invalid/expired state, unconfigured server,
  token-exchange failure, profile failure, upsert failure, and the
  catch-all. `redirectBase` is declared outside the `try` so the
  catch-all still redirects to the right client.
- Nothing else in the flow changes: state verification (single-use
  delete, 10-minute TTL), token exchange, refresh-token encryption,
  `email_connections` upsert, audit row.

## What it does NOT change

- The web flow. No `client` field → bare nonce → redirect to
  `https://ycfried.github.io/Budget/live.html?gmail=…`, exactly as
  today.
- The Google Cloud Console redirect URI (still the callback
  function URL) and the `redirect_uri` sent in the token exchange.
- Scopes (`gmail.readonly` only), `gmail_oauth_states` schema, any
  other function, any SQL, any app code (the app side lives on
  `ios-clone`, merged separately).

## To ship (parent)

1. Review this diff.
2. Merge to main.
3. Deploy both functions:
   `supabase functions deploy gmail-oauth-start gmail-oauth-callback`
   (or deploy from the dashboard).
4. Supabase dashboard → Auth → URL Configuration → Redirect URLs →
   add `onbudget://reset-password` and `onbudget://gmail-callback`.
5. Test a real native connect from a device (admin, test
   household): Connect Email → Google consent → app returns with
   the "Email connected" toast; verify in `email_connections`.
   Also re-test the web connect to confirm live.html still works.

## Verification done here

- Read-only review of both files against main; no deploy, no
  production Supabase access, no live Gmail flow attempted.
- The redirect logic is deliberately boring: one prefix check,
  one default, threaded everywhere. The risky part (a native
  failure redirecting to live.html, or vice versa) is covered by
  the every-exit-path threading + the catch-all fallback.
