# Math decisions N1 + N2 — decision brief for the owner

**Status:** research only. No code changed, no live database touched, no live app loaded.
**Update (Nov 9, 2026 — this file committed to the repo as the decision record):** the owner picked Option A for N1 and Option A for N2 on Nov 5, 2026 ("whatever you recommend"; HANDOFF.md "Math fixes N1 + N2", branch math-fixes-n1-n2). Both fixes are built and tested. Line 57 is corrected below — fund-first is owner-confirmed, not pending. The "policy choice from you" framing in the summary and the "If you pick nothing" section are the brief's original pre-decision wording, kept as history.
**Base checked:** remote main `3ddea38` (the code the deep audit read; the same files are in live main `3f98fe4` — the audit-fixes push did not touch these functions).
**Sources:** `DEEP_AUDIT_2026-11-05.md` (N1, N2), `supabase/functions/compute-week/index.ts`, `supabase/functions/week-close/index.ts`, `supabase/functions/week-close/restoration.mjs`, `supabase/functions/week-close/engine.mjs`, and the FINAL spec (`Household_Budget_Spec_FINAL.pdf`, refund-restoration section). Every number in the worked examples below was re-run through the actual `computeWeek` engine, not hand-computed.

**The one-line summary:** both bugs over-pay a refund. N1 pays a split-purchase refund twice ($90 of benefit from a $50 refund). N2 pays a later refund in the wrong currency — surplus that doesn't exist instead of debt relief — because the simulation starts with the wrong amount of incoming debt. Neither bug touches fully-fund or fully-normal purchases. Both need a policy choice from you, not a guess from the code.

---

## N1 — A split purchase refunded $50 gives $90 of benefit

### Recommendation (read this first)

**Pick Option A — fund-first, counted once.** Keep the existing rule that a refund pays the fund portion back first, and fix the double-count by making the weekly walk count only the *normal* part of a linked refund. In the example below that means: the week's spending stays at $40 (unchanged), and the fund gets its $50 back. Total benefit $50. Nothing else changes, and fully-fund and fully-normal purchases work exactly as they do today.

### The problem in plain language

A purchase can be split: part paid from the weekly budget ("normal"), part paid from the Extra Fund. Say you buy something for $100 — $60 from the fund, $40 from the week's budget. A $50 refund comes back. That $50 is real money, and it should give the household $50 of benefit in total — no more.

Today it gives $90. Two different parts of the code each claim the same $50, in the same week-close run:

1. **The weekly walk** recomputes the purchase week and subtracts the *whole* $50 refund from the week's spending — even though only $40 of that purchase ever counted as weekly spending. The other $60 was fund money and never sat in the week's charges. Spending drops from $40 to $0 (the $10 extra vanishes into the zero floor), so weekly surplus goes up $40.
2. **Refund restoration** separately pays $50 straight back to the fund, because the refund is applied to the fund portion first. The fund goes up $50.

$40 of extra surplus + $50 back to the fund = $90 of benefit from a $50 refund. The extra $40 eventually becomes fund money too (surplus is released to the fund after 7 days), so the Extra Fund ends up $40 richer than it should be.

### Why it happens — the two mechanisms

- `chargeContribution` counts only the normal part of a charge: a $100 purchase with a $60 fund allocation contributes $40 to the week's charges. Correct.
- But the linked-refund netting in `compute-week/index.ts` (open weeks) and in `week-close/index.ts` `linkedPostedToWeek` nets the refund's **full** amount against those charges. A $50 refund nets against $40 of charges. The fund half of the refund is counted here even though it was never in the charges.
- Meanwhile `week-close/index.ts` restoration posts `postedFund = inc.fundCreditCents` **without checking whether the purchase week is locked** (the surplus and debt parts *are* locked-gated, the fund credit is not). `restoration.mjs` computes that fund credit fund-first: `fundCredit = min(refund, fundAllocation)` = $50.
- The restoration *simulation itself* is careful — it adds the refund back into the baseline charges so it doesn't double-count inside the simulation. The walk is not careful in the same way. That inconsistency is the bug.

### When it bites, and when it doesn't

- **Bites only for split purchases** (part fund, part normal) **while the purchase week is still in its 28-day open window** — i.e. the week has finished but hasn't locked yet. That is exactly the window week-close works in, so it bites in the normal case, not an edge case.
- **Does not bite for fully-fund purchases** ($100, all fund): weekly charges are $0, the walk nets the refund to below zero and the floor eats it, restoration credits the fund $50. Total $50. Correct already.
- **Does not bite for fully-normal purchases** ($100, no fund): the walk nets the full $50, restoration credits the fund $0. Total $50. Correct already.
- **Does not bite once the week is locked** (28+ days old): locked weeks never net refunds in the walk, so only restoration pays, once. Correct already.
- **Does not bite for pending refunds:** only posted (verified) refunds enter either path. Pending refunds restore nothing, as the spec requires.

### Worked example (verified against the engine; base allowance $375, no temp, no incoming debt)

| Step | Weekly charges (C) | Weekly surplus | Fund |
|---|---|---|---|
| Purchase $100: $60 fund + $40 normal, no refund | $40 | $335 | fund paid out $60 |
| **Today, with a $50 refund** — walk nets the full $50 | $0 (floored from −$10) | $375 (**+$40**) | — |
| **Today** — restoration also credits the fund $50 | — | — | **+$50** |
| **Today, total benefit** | | | **$90 from a $50 refund** |
| **Correct total benefit** | | | **$50** |

The spec's own rule is on our side here: "Restoration … never exceeds the refund" and "Refunds follow the original transaction's allocation." A $50 refund cannot produce $90.

### The options

All three options pay exactly $50 in total, and all three agree on fully-fund and fully-normal purchases. They differ only in *who bears the net cost* of a split purchase after the refund. The item cost $100, $50 came back, so $50 of net cost has to sit somewhere — fund, weekly budget, or shared. That split is a policy choice; the spec's acceptance cases cover only fully-fund purchases, and fund-first is owner-confirmed (Nov 5, 2026 — N1 Option A, fund-first counted once; HANDOFF.md "Math fixes N1 + N2").

**Option A — Fund-first, counted once (RECOMMENDED).**
Refund pays the fund portion back first; the weekly walk counts only the normal portion.
- Example: walk nets $0 (normal portion of the $50 refund is $0), surplus stays $335, fund gets $50. Net cost: fund bears $10 ($60 − $50), weekly budget bears $40.
- Pros: keeps the fund-first rule already implemented in `restoration.mjs` — the smallest change, and the one the code already believes in. The fund is the household's savings pot: money taken from it comes back first, so a refund can never leave the fund short while the weekly budget gains. Matches "a refund of a fund purchase credits the fund directly," extended to the fund part of a split purchase.
- Cons: the weekly budget shows the $40 as still spent even though $50 came back in cash. If you think of the refund as "money back on this week's shopping," this feels backwards — that is Option B's argument.
- Code change: `compute-week/index.ts` linked-refund loop and `week-close/index.ts` `linkedPostedToWeek` net only the *normal* portion of each linked refund, computed per purchase from cumulative refunds (fund credit first, same arithmetic as `restoration.mjs`). No change to `restoration.mjs` — its fund-first split is already correct. Unlinked refunds (no purchase to split against) keep netting in full, unchanged.

**Option B — Normal-first, counted once.**
Refund pays the weekly-budget portion back first; the fund gets what's left.
- Example: walk nets $40, surplus rises to $375 (+$40), fund gets $10. Net cost: fund bears $50, weekly budget bears $0.
- Pros: matches the everyday intuition — "I spent $40 of this week's money, the refund gives it back first." The weekly numbers visibly improve when a refund arrives.
- Cons: the fund bears most of the net cost of a split purchase, so the Extra Fund stays depleted after refunds while weekly surplus looks healthy. Contradicts the fund-first interpretation already in `restoration.mjs` and the "fund refunds credit the fund directly" rule. Bigger change: `restoration.mjs` fund-credit ordering flips *and* the walk netting changes to the same ordering.
- Code change: `restoration.mjs` `computeRestorationTotal` (fund credit becomes the remainder after the normal portion), plus the same walk-netting change as Option A but with the normal-first split.

**Option C — Pro-rata, counted once.**
Refund splits in the same proportion as the purchase (here 60% fund / 40% normal).
- Example: walk nets $20, surplus rises to $355 (+$20), fund gets $30. Net cost: fund bears $30, weekly budget bears $20.
- Pros: neither pot is privileged; the net cost is shared exactly as the purchase was shared. Feels fair on paper.
- Cons: no spec support and no existing code support — a brand-new rule. The fund is never fully repaid even when the refund is smaller than the fund portion (here the fund paid $60, gets $30 back), and the weekly budget is never fully repaid either. Changes both `restoration.mjs` and the walk.
- Code change: same two places as Option B, with a proportional split instead of an ordering.

**Rejected variant (for completeness, do not pick):** only gate the restoration fund credit behind the week locking, and leave the walk as-is. That pays just $40 (the walk's floored benefit) — $10 of the refund vanishes into the zero floor — and the fund's money is delayed up to 28 days. It fixes the double-count by under-paying instead.

### What to test after the fix (synthetic household only)

A split purchase ($100: $60 fund / $40 normal) refunded $50 while the week is open: total benefit exactly $50, split per the chosen option. Then the same for fully-fund and fully-normal purchases (unchanged), two partial refunds on one split purchase ($30 + $30 — the cumulative split must be order-independent), and a refund larger than the purchase (excess held, never restored).

---

## N2 — The restoration simulation starts with the wrong incoming debt

### Recommendation (read this first)

**Pick Option A — use compute-week's definition of incoming debt.** In week-close's restoration, subtract only the debt cuts posted *after* the prior close's week and *up to and including* the purchase week. That is exactly the rule `compute-week` already uses for the dashboard's carried debt, so the two functions finally agree on what "debt entering a week" means. It fixes both halves of the bug below with a one-line window change.

### The problem in plain language

When a refund arrives for an old purchase, week-close replays history in a simulation: it starts from the debt the household owed going into the purchase week, replays every week up to today with the refund applied, and the difference is what the refund restores — extra surplus, or less debt still owed.

That starting debt is wrong. The code takes the previous week's stored closing debt and subtracts **every** debt cut from **every** earlier restoration, ever. Two mistakes in one subtraction:

1. **Cuts already inside the stored number are subtracted again.** A stored close already reflects the cuts that were applied when that week was computed. Subtracting them a second time counts the same relief twice.
2. **Cuts from the future are subtracted from the past.** A cut posted in a later week — relieving debt that week — is subtracted from the debt going into the *purchase* week, weeks earlier, before that cut existed. Debt is time-travelled backwards.

Both mistakes push the starting debt *down*. A simulation that starts with too little debt thinks the debt was already mostly gone, so it turns the new refund's benefit into surplus (spendable fund money) instead of debt relief (less owed in future weeks). The total is still capped at the refund, so the household doesn't gain money out of thin air — but the money lands in the wrong place: the Extra Fund gets surplus that doesn't exist, and future weeks still carry debt the simulation said was gone.

The intent behind the code was right — a merged-audit comment (B8) says it plainly: "subtract debt cuts already posted by earlier runs, so a debt already relieved by a prior restoration is not relieved a second time." The *window* is wrong, not the idea.

### Why it happens — the exact code

`week-close/index.ts`, restoration phase (audited lines 724–728):

```js
const priorCuts = restorationEntries
  .filter((r) => r.week_start < currentWeekStart)   // every cut ever posted before this run
  .reduce((sum, r) => sum + (r.debt_reduction_cents ?? 0), 0);
const initialDebt = priorClose
  ? Math.max(0, (priorClose.outgoing_debt_cents ?? 0) - priorCuts)
  : 0;
```

Two facts make this wrong:

- **Restoration entries are posted with `week_start` = the week the run happens** (`currentWeekStart`), and the walk applies each cut to the debt entering *that* week (`Dws = max(0, Dchain − cutsByWeek.get(ws))`). So a cut is already inside every stored close from its posting week onward. `priorCuts` subtracts it again.
- **`priorClose` is the latest close *before the purchase week*.** A cut posted in a week after the purchase week cannot possibly have reduced the debt entering the purchase week — but `priorCuts` includes every cut before *today*, including those.

`compute-week/index.ts` does it correctly, and says so in its own comment ("cuts are never subtracted twice because only entries after the latest close week are counted"):

```js
restorationCuts = entries
  .filter((r) => r.week_start > latestCloseBefore.week_start
              && r.week_start <= weekStart)   // only cuts AFTER the close, up to this week
  .reduce((s, r) => s + (r.debt_reduction_cents ?? 0), 0);
D = Math.max(0, latestCloseBefore.outgoing_debt_cents - restorationCuts);
```

The correct definition of **debt entering week W** is therefore: **the latest stored close before W, minus only the debt cuts posted after that close's week and up to and including W.** Cuts posted in or before the close's week are already inside the stored number. Cuts posted after W belong to later weeks, never to W's entering debt.

### Worked example (verified against the engine; base allowance $375, no temp)

Setup — two normal purchases, no fund, charges as booked:

| Week | Charges | Debt in | Surplus | Debt out (close) |
|---|---|---|---|---|
| W1 (Nov 1) | $475 (purchase X) | $0 | $0 | $100 |
| W2 (Nov 8) | $475 (purchase Y) | $100 | $0 | $200 |
| W3 (Nov 15) | $375 | $200 | $0 | $200 |
| W4 (Nov 22) | $375 | $200 | $0 | $200 |
| W5 (Nov 29) | $375 | $200 | $0 | $200 |
| W6 (Dec 13) | $300 | $200 | $0 | $125 |

**First refund — $100 for purchase X, arrives Dec 6 (W1 locked).** Simulation starts with debt $0 into W1 (no prior close, no prior cuts — correct). Baseline ends with $200 debt; with the refund, $100. Posts a **$100 debt cut**, entry dated Dec 6. Correct.

**Second refund — $100 for purchase Y, arrives Dec 20 (W2 locked).** The simulation should start with the debt entering W2, which is **$100** (W1's stored close). Instead:

| | Starting debt into W2 | Baseline (W2–W6) | With refund | Posted |
|---|---|---|---|---|
| **Today (wrong)** — priorCuts subtracts X's $100 cut, posted Dec 6, from W1's $100 close | **$0** | surplus $0, debt $25 | surplus $75, debt $0 | **$75 surplus + $25 debt cut** |
| **Correct** — X's cut was posted after W1, in a week after W2, so it never touched debt entering W2 | **$100** | surplus $0, debt $125 | surplus $0, debt $25 | **$0 surplus + $100 debt cut** |

The wrong run posts **$75 of surplus that doesn't exist** — money that becomes spendable Extra Fund cash after the 7-day release — and only a $25 debt cut instead of $100, so future weeks keep carrying $75 of debt the simulation claimed was gone. Same $100 total, wrong place. And the error compounds: the understated $25 cut is what future walks subtract, so the $75 lives on as phantom fund money against real future debt.

(The "already inside the close" half is the same error in the other direction: a cut posted in a week *at or before* the prior close's week is already inside that close's stored debt — e.g. a $50 cut posted in week W0 is already reflected in W1's close — and `priorCuts` subtracts it a second time. Same fix, same window.)

### The options

**Option A — Adopt compute-week's definition (RECOMMENDED).**
In week-close's restoration, replace the `priorCuts` window with compute-week's: subtract only cuts with `priorClose.week_start < entry.week_start ≤ purchaseWeek`.
- Pros: one shared definition of "debt entering a week" across both functions — the dashboard and the close can no longer disagree. Fixes both halves (double subtraction and time travel) with a one-line window change; no new concepts, no interface changes. The B8 intent is preserved, correctly scoped.
- Cons: a residual gap remains (see below) — cuts posted *inside* the simulation horizon, after the purchase week, are still not applied week-by-week inside the simulation. In practice that can still skew the surplus/debt split of a later refund in the same way, though by less. This is the honest limit of Option A.
- Code change: `week-close/index.ts` only — the `priorCuts` filter in the restoration phase. Plus regression fixtures (the worked example above, as a test) in `restoration.mjs` / week-close tests.

**Option B — Option A plus per-week cuts inside the simulation (most faithful).**
Do Option A, and also apply earlier cuts at their correct weeks *inside* the simulation — pass the walk's `cutsByWeek` map into the simulation so each week's entering debt is reduced by the cuts posted that week, exactly as the walk does.
- Pros: the simulation then reproduces recorded history exactly, including cuts posted mid-horizon. The surplus/debt split of every later refund is right, not just the starting debt. This is the only option that fully closes the gap.
- Cons: touches `restoration.mjs`'s pure interface (it currently takes only an initial debt, not a per-week cut map) and needs new fixtures. A bigger, more careful change — worth doing, but not a one-liner.
- Code change: `week-close/index.ts` (build and pass `cutsByWeek`) + `supabase/functions/week-close/restoration.mjs` (`simulateWeeks` / `computeRestorationTotal` accept per-week cuts) + fixtures.

**Option C — No subtraction at all (NOT recommended).**
`initialDebt = priorClose.outgoing_debt_cents`, always.
- Pros: simplest possible change; can never double-subtract.
- Cons: wrong in the other direction whenever a cut was legitimately posted in the purchase week itself or in a gap week between the prior close and the purchase week — entering debt is then overstated, and the split skews the opposite way (too much debt relief, too little surplus). It throws away the correct half of compute-week's rule along with the wrong half.
- Code change: `week-close/index.ts` only — delete the `priorCuts` subtraction.

### What to test after the fix (synthetic household only)

The worked example above, end to end: two refunds on two purchases in consecutive weeks, second refund's simulation must post $0 surplus + $100 debt cut. Plus: a refund whose purchase week immediately follows a week with a cut posted in it (the `≤ purchaseWeek` bound), and a refund after a cut posted before the prior close (the already-inside half). Existing restoration fixtures (FINAL test 15 cases, including the $475 / $150 surplus-and-debt case) must still pass unchanged.

---

## If you pick nothing

Both bugs stay live. N1 over-pays every split-purchase refund in its open window (up to the normal portion of the refund, here $40 on a $50 refund). N2 misallocates every later refund that follows an earlier debt-cutting restoration (surplus overstated, future debt understated). Neither bug fires on the very first refund a household ever gets, or on fully-fund / fully-normal purchases — which is why they survived this long. They fire on the second refund, and on split purchases, which is exactly normal use over time.

## Suggested order once you decide

1. Say which option for N1 and which for N2 (they are independent — N1 is about *which pot* a refund repays, N2 is about *where the simulation starts*).
2. Both fixes land in one branch with fixtures for the worked examples above, tests green, then a PR and a live push. No database change is needed for either fix — both are Edge Function / shared-logic code.
3. The two SQL items from the audit (merge-restore, fund-shortfall) are separate and still need their live probe + your approval; they are not part of this brief.
