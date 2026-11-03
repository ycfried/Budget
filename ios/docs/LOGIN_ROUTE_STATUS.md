# Owner login route and network prerequisite status

November 3, 2026. Existing Auth/read-only window is **approved**, subject to the
owner's explicit preconditions. Approval persists; do not request that same window
again. **No live connection has occurred. The secure login route is not ready.**

## Verification results

| Required prerequisite | Actual status / evidence |
|---|---|
| Exact existing project origin and public key through approved configuration | **NOT VERIFIED.** HANDOFF documents the intended project, but no owner-confirmed runtime configuration has been supplied to the native app. No key has been copied from web code, terminal, secret file or provider. Public configuration authenticity cannot be established by checking key syntax or an anon JWT role alone. No probe request was made. |
| Secure owner-controlled password entry | **NOT READY.** The native sign-in UI remains locked with no destination/client. Owner has not been given an interactive Apple build of this revision; Keychain/session/UI behavior has not been validated with Xcode. Cloud CI does not provide an owner-controlled interactive login session on an iPhone. |
| Final network review | **OFFLINE SOURCE/CONTRACT CHECKS PASS, NOT LIVE PROOF.** GuardedReadTransport permits only approved Auth grants, identity/membership reads, compute-week and explicit selected-column table reads to one exact origin. Financial table writes, RPCs, provider functions, signup/recovery/revocation/deletion and week-close are rejected before dispatch. Redirects, other origins/ports/schemes and extra request fields/queries are rejected. App still has no enabled executor. |
| Request limits and stop conditions | **OFFLINE ENFORCED.** ReadValidationWindow consumes limits before dispatch: one password grant, one refresh, one week read, one initial Range 0–99 page per relation, at most 15 identity and 15 membership reads: 45 requests plus one optional refresh. Duplicate collection/week/Auth attempts and concurrent replay stop the window. No pagination loop/reset. Non-2xx, transport error/cancellation, decoder failure and store-level validation failure stop further use. No automatic retries. |
| New Apple compilation/execution | **NOT AUTHORIZED / NOT RUN.** Historical simulator PASS at 1d66a0f predates current authentication code. Linux fixture tests are not Apple, Keychain or secure-login validation. |

A user token has the user's actual backend privileges. The client guard prevents
financial-write routes in this composition; it does not revoke those server
privileges or prove deployed RLS/function behavior. The existing compute-week source
is read-only. No permission to call week-close to refresh summaries is implied.
There is no approved live server identity/configuration evidence yet, so it would
be inaccurate to claim the complete live network setup is verified or ready.

## Configuration method to use before connection

Proposed owner-controlled method, still to be executed:

1. Owner or explicitly trusted friend opens the existing project's own dashboard
   on their controlled device and verifies project identity against HANDOFF. Read
   project URL and **publishable/anon key only**; do not change settings or read/use
   service/admin/provider secrets. If this dashboard/config retrieval route is not
   available, stop and agree an equivalent trusted method; don't scrape production
   web configuration or substitute a different project.
2. Supply only that public project configuration directly to the local reviewed
   native execution environment, outside the repository/cloud logs. Compare exact
   scheme/host/port, key type and project association locally. No runtime config
   values, password, access/refresh token or financial record go into a commit,
   terminal command, chat, screenshot, uploaded diagnostic or CI artifact.
3. Review the exact candidate build SHA, guarded transport/composition and private
   Keychain service namespace. No URLSession executor is enabled just because the
   code compiles or the owner approved read access. Keep sample and real stores
   separate; restore no real session automatically.
4. Only after the Apple execution route is validated and the owner is told it is
   ready, the owner enters their own login directly in that local native screen.
   Observer/agent recording must be off for password entry and authenticated
   responses. The owner controls credential entry, not a cloud terminal. Run the
   already-approved bounded inspection; stop on its documented failures.

No runtime configuration form/import mechanism is enabled in the current shipped
composition. Its exact owner-device configuration loading and activation must be
reviewed with the chosen execution route, not silently replaced by cloud vars or
hardcoded project values. This avoids presenting a public-key syntax check as
verification of the real project/key pair.

## Execution routes and approvals still needed

- **Owner-controlled Mac + Xcode simulator:** an interactive session on the owner's
  or trusted friend's Mac permits the owner to enter credentials directly; a
  simulator does not require distribution signing. First validate with fixtures,
  inspect Keychain/local cleanup and confirm recording/logging protections before
  real configuration/login. Need access to such a Mac and explicit approval for
  the necessary simulator compilation/test. None is run in this cloud task.
- **GitHub-hosted unsigned simulator build:** can validate compilation and fixture
  UI/core tests, with no project configuration/real credentials/live requests. It
  cannot be used as an interactive owner login route or install an unsigned app on
  the owner's iPhone. A separate build approval is required. Existing workflow may
  be used unchanged only if the exact one-run build request is approved.
- **iPhone/iPad only:** requires a separately approved native signed/device
  distribution route through the friend. Signing, provisioning, deployment,
  TestFlight/App Store and spending remain unapproved. Do not manufacture a web
  login bridge, send credentials to an agent, or bypass Apple signing restrictions.

The owner has been asked which interactive route is available. No response is
assumed. Cloud CI is optional compilation evidence, not a solution to secure
password entry. A new cloud build alone cannot make the route ready.

## Concrete optional cloud validation request (not activated)

One unsigned fixture-only simulator build/test on the existing standard
GitHub-hosted macOS workflow, branch ios-native-rebuild, max 25 minutes, no workflow
changes, no automatic retries, no real configuration/secrets/Auth requests,
no signing/deployment/artifact uploads/provider services or spending. Use the
existing required commit prefix only **after separate approval**; no such commit
is created now. Report its URL, tested SHA, compilation/UI/core/Keychain coverage
and errors; stop before any further run. If included public-runner usage cannot
be established within the approved zero-charge boundary, do not run it.

This build would check the new locked-login UI test and current Apple code. It
does not grant production access from CI, enable the app's live executor, or
validate an owner-device Keychain/session interaction. Any resulting errors need
review and separate approval before a replacement run.

## Explicit exclusions carried forward

No financial writes/imports/request approvals/reversals, bank synchronization,
Gmail operations, account deletion, releases, close jobs or provider/account changes.
No modifications outside ios/, main, web, Supabase, workflows or deployment settings.
No production connection while any prerequisite above is unresolved. No request
for the owner's password/tokens in chat or a cloud terminal.
