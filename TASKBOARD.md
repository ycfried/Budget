# Household Budget — Task board (Milestone A prototype)

Status as of 2026-11-01. This prototype is a DEMO: local demo auth, fake data,
no live Gmail/Plaid, no deployment. See README.md for the PASS/FAIL/BLOCKED table.

## Done (this prototype)
- [x] Read the 19-page spec (v2) and the Nov 1 addendum; engine rules taken from Part A2/A4.
- [x] Shared pure budget engine (`engine.mjs`) — one formula for browser and server.
- [x] Engine tests (`test/engine.test.mjs`): 15 passing, 1 skipped (FIN-REFUND-001).
- [x] Mobile-first installable PWA: Dashboard, Transactions, Extra Fund, Savings,
      Settings (admin only), Audit; demo sign-in switching Admin/Member.
- [x] Manual provisional entry, Extra Fund request queue (member requests, admin
      approves/declines/splits, insufficient-fund block), savings ledger (4 numbers,
      manual attestation only, never a transfer action).
- [x] CSV import with stable-hash dedupe (re-import adds nothing); synthetic
      Amex-alert parser that fails closed into quarantine.
- [x] Server (`server.mjs`, zero dependencies) with server-side role enforcement:
      member calls to /api/admin/* return 403.
- [x] Seeded fake demo transactions spanning weeks 2026-10-11 → 2026-11-01.
- [x] OPEN_QUESTIONS.md with FIN-REFUND-001 preserved as unresolved.

## Next (not in this prototype — needs owner approval before any live step)
- [ ] Real persistent auth + database (replace localStorage demo state and the
      `x-demo-role` header) — owner approval for hosting/accounts required.
- [ ] Free HTTPS hosting on a platform subdomain — deploy only with approval.
- [ ] Live Gmail forwarding + dedicated-inbox Apps Script poller — owner performs
      forwarding setup and verification; parser must be proven on a real redacted
      forwarded alert first (spec Phase 2 gate).
- [ ] Plaid viability check (Trial eligibility, Amex coverage, Sync, webhooks,
      refresh, pricing) — CSV-first remains the fallback if Plaid is not viable.
- [ ] Week-close scheduled job (Sunday 00:00 America/New_York), nightly backup
      export + one restore test.
- [ ] Native SwiftUI / WidgetKit client (Milestone B) — only after the PWA is reliable.

## Explicitly NOT started (do not start without owner approval)
- [ ] No Gmail/Amex/Plaid/Apple account changes, no OAuth grants, no paid services.
- [ ] No public signup, billing, marketing, or multi-tenant admin UI.
- [ ] No production use of refund-credit/surplus logic until FIN-REFUND-001 is decided.
