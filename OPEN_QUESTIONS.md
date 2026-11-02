# Open questions

## FIN-REFUND-001 — SUPERSEDED by the final spec (Nov 1, 2026, ~11:01 PM): the refund-credit model that created this question was removed entirely and replaced by refund restoration, so the old question is moot. Restoration itself is unbuilt; the old-model code (R chaining, held weeks) must be retired in the post-audit build. Original entry below, kept for history:
FIN-REFUND-001 — DEFERRED, UNRESOLVED (do not lose this)

**Status:** OPEN. No policy chosen. No acceptance test for this case is marked passed.

**The inconsistency (spec v2, refund-credit engine cases):**
A $100 excess refund in a week with no debt and no charges is stated to produce
**BOTH** $375 earned surplus **AND** $100 outgoing refund credit.

**Why it matters:**
That combination could double-benefit the household: the $375 surplus would be
released into the Extra Spending Fund after 7 days, while the full $100 credit
also carries forward against future spending. Unless the accounting intent is
that both are genuinely owed, the household would receive the same $100 of
value twice (once as spendable fund money, once as a carried credit).

**What the prototype does about it:**
- The engine (`engine.mjs`) faithfully reports both numbers for that input,
  because that is what the spec text states — it does not silently invent a
  policy (for example, it does not cancel the surplus, consume the credit, or
  convert the credit into fund money).
- The test for this case in `test/engine.test.mjs` is explicitly **skipped**
  with the ambiguity noted. It must NOT be un-skipped or marked passed until
  the owner decides.
- The PWA dashboard carries a visible FIN-REFUND-001 notice: outputs depending
  on this case are not production-certified.
- No automatic fund release may be deployed using an unreviewed interpretation
  of this case.

**Decision needed from the owner before production use of refund-credit /
surplus logic (choose one, or state a third rule explicitly):**
1. Surplus counts and the credit also carries forward (double benefit intended
   — confirm explicitly, in writing).
2. The excess refund first offsets the week's surplus, and only any remainder
   becomes carried credit.
3. The excess refund becomes carried credit only, and no surplus is earned
   from a week whose charges were fully refunded.
4. Some other stated rule.

**Related cases that ARE settled (tested and passing):**
- $40 debt + $100 excess refund → debt $0, credit $60.
- $500 debt + $100 excess refund, no charges → debt $400 cut, base absorbs
  $375, outgoing debt $25, credit $0.
- $100 credit carried in + $475 charges → no debt, credit $0.
- $100 credit carried in + $300 charges → surplus $75, credit $100 remains.
- $100 credit + $100 temp + $500 charges → temp first, credit covers $25,
  credit $75 remains, no debt.

## Other open items (from the spec, not yet verified)
- **Additional-cardholder Amex alerts:** whether the spouse's card purchases
  generate alerts to the same inbox — must be tested with a real purchase;
  not assumed.
- **Plaid Trial eligibility and Amex coverage:** unverified. Check the real
  dashboard (products, live Items, Sync, webhooks, /transactions/refresh,
  rate limits, pricing) before any Plaid work. CSV-first remains the fallback.
- **Free-tier limits:** hosting, database, scheduled jobs, and backups must be
  verified against current terms before choosing production infrastructure.
  Nothing is promised as free forever.
- **Amex alert template:** the exact forwarded-alert format and whether DKIM
  survives forwarding must be proven on a real redacted sample before any
  live email ingestion (spec Phase 2 gate).
