#!/usr/bin/env node
// seed_video_fixtures.mjs — STAGE how-to video v3 (Nov 19, 2026).
//
// Seeds realistic fixtures into the TEST household "Simcha House!"
// ONLY (id 95e1aff3-f664-41bb-be09-70e00f75a141). Never the live
// household. Run on the CI runner with the service-role key; the
// service key bypasses RLS, so this inserts directly via PostgREST.
//
// v3 changes vs the v2 seed (the v2 numbers looked wrong on camera):
//   * Week is Sunday-start: the current week is Sun Nov 15 - Sat
//     Nov 21, 2026. The v2 seed put Costco on Nov 15 thinking it was
//     prior-week; it counted, so the hero showed $372.06 spent /
//     $2.94 left (99% used). Costco moves to Sat Nov 14 (prior week,
//     still visible in the Transactions list).
//   * Current-week charges trimmed to $175.89, so the hero shows
//     $199.11 left of the $375 base (53% left — a healthy mid-week
//     number), not $2.94.
//   * charity_settings row: the test household never had one (the
//     live household got its row when the owner set the 10% rate
//     himself Nov 16), so Funds showed "Loading rules…" forever
//     under the Charity card. Insert the 10% default row if missing.
//     Same for debt_settings (25% default rule) so the Carried Debt
//     rule never sticks on "Loading rules…" either.
//   * Pending Extra Fund top-ups: v2 showed $0 Available / $740
//     Pending because pending top-ups write no ledger row until
//     confirmed. Confirm every pending top-up, mirroring
//     confirm_fund_topup exactly (split against the current
//     shortfall, ledger 'adjustment' row for the added part,
//     shortfall update, audit row) so Savings shows confirmed /
//     available money. If Savings Available is still $0 afterwards
//     (no pending top-ups and no ledger rows at all), insert one
//     confirmed $740 top-up + ledger row as the demo cushion.
//   * Pending surplus releases: the v2 $740 Pending turned out to
//     be two unreleased surplus rows (weeks Nov 1: $365, Nov 8:
//     $375), not top-ups. Release them, mirroring week-close's
//     releaseDue (ledger 'release' row + audit row), so Savings
//     Pending reads $0. Final Savings: Available $1,480 ($740
//     top-up + $740 released surplus), Pending $0.
//
// What it seeds:
//   * 10 spending transactions (charge, verified, source manual) with
//     real merchant names people recognise (Walmart, Target, Amazon,
//     Starbucks, Shell, Costco, Trader Joe's, Chipotle, Uber,
//     Netflix). 8 in the current week (Nov 16-19, $175.89) and 2 in
//     the prior week (Nov 14, $171.50) so the list looks full without
//     pushing the current week over budget. Merchant icons resolve
//     via the app's Google favicon lookup; names are what matters.
//   * 1 income transaction (Paycheck $1,200, Nov 17, verified).
//   * 1 charity_income row linked to that paycheck ($1,200 at the
//     10% default rate = $120 committed).
//   * 1 charity_cash_gifts row ($40, Nov 18) so Given is non-zero:
//     Committed $120, Given $40, Available $80.
//
// Idempotency: every fixture row carries a `video-fixture-` marker
// (transactions.external_id, charity_income.note,
// charity_cash_gifts.note, fund_topups.client_key). The script
// deletes all marked rows first, so re-runs never accumulate
// duplicates. It does NOT touch the pre-existing "Week Close
// Fixture" $10 row (no marker on it) or any other pre-existing row.
// The settings upserts and top-up confirms are idempotent by
// construction (insert-if-missing; re-confirm returns the stored
// split and moves nothing).
//
// dedupe_hash: canonical SHA-256 of "MERCHANT|date|amountCents|
// cardSuffix" (merchant uppercased, whitespace collapsed) + '-' +
// an 8-char random suffix, matching the app's format for manual
// rows. Amounts are SIGNED cents: charges positive, income negative.
//
// Usage (CI): SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY env.
//   node ios-clone/scripts/seed_video_fixtures.mjs
// Exits non-zero on any failure; prints what it inserted + the
// computed figures for verification (including the authoritative
// compute-week hero numbers, exactly as the app reads them).

import { createHash, randomBytes } from 'node:crypto';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const HOUSEHOLD_ID = '95e1aff3-f664-41bb-be09-70e00f75a141'; // Simcha House! (TEST ONLY)
const MARKER = 'video-fixture';
const WEEK_START = '2026-11-15'; // Sunday; current week Nov 15-21, 2026
const EXPECTED_CURRENT_WEEK_CHARGES = 17589; // $175.89 -> $199.11 left of $375

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error('BLOCKED: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.');
  process.exit(2);
}

const headers = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  'Content-Type': 'application/json',
  Prefer: 'return=representation',
};

async function rest(method, table, query, body) {
  const url = `${SUPABASE_URL}/rest/v1/${table}${query ? `?${query}` : ''}`;
  const res = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`${method} ${table}${query ? `?${query}` : ''} -> HTTP ${res.status}: ${text.slice(0, 500)}`);
  }
  return text ? JSON.parse(text) : null;
}

const money = (c) => `$${(c / 100).toFixed(2)}`;

function normalizeMerchant(m) {
  return String(m ?? '').toUpperCase().trim().replace(/\s+/g, ' ');
}

function dedupeHash(merchant, date, amountCents, cardSuffix) {
  const canonical = `${normalizeMerchant(merchant)}|${date}|${amountCents}|${String(cardSuffix ?? '0000').slice(-4)}`;
  const hash = createHash('sha256').update(canonical).digest('hex');
  return `${hash}-${randomBytes(4).toString('hex')}`;
}

// --- Fixture data -------------------------------------------------------
// Current week (Nov 16-19): 8 charges, $175.89 total. Base $375, so
// Spending available lands at $199.11 (53% left — healthy).
const CHARGES_CURRENT_WEEK = [
  { merchant: 'Walmart', amount: 5240, date: '2026-11-18', suffix: '1005', slug: 'walmart' },
  { merchant: 'Target', amount: 3185, date: '2026-11-18', suffix: '1005', slug: 'target' },
  { merchant: 'Shell', amount: 2760, date: '2026-11-17', suffix: '1005', slug: 'shell' },
  { merchant: 'Amazon', amount: 2145, date: '2026-11-17', suffix: '1005', slug: 'amazon' },
  { merchant: 'Starbucks', amount: 645, date: '2026-11-19', suffix: '1005', slug: 'starbucks' },
  { merchant: 'Chipotle', amount: 995, date: '2026-11-19', suffix: '1005', slug: 'chipotle' },
  { merchant: 'Uber', amount: 1420, date: '2026-11-19', suffix: '1005', slug: 'uber' },
  { merchant: 'Netflix', amount: 1199, date: '2026-11-16', suffix: '1005', slug: 'netflix' },
];
// Prior week (Sat Nov 14): 2 charges, $171.50. Shows in the list but
// does not touch the current week's available (week starts Sunday).
const CHARGES_PRIOR_WEEK = [
  { merchant: 'Costco', amount: 11287, date: '2026-11-14', suffix: '1005', slug: 'costco' },
  { merchant: "Trader Joe's", amount: 5863, date: '2026-11-14', suffix: '1005', slug: 'trader-joes' },
];
const INCOME = { merchant: 'Paycheck', amount: -120000, date: '2026-11-17', suffix: '1636', slug: 'paycheck' };
const CASH_GIFT = { amount: 4000, date: '2026-11-18', note: `${MARKER} cash gift` };
// Fallback demo cushion, only if Savings Available is still $0 after
// confirming pending top-ups (see step 8).
const FALLBACK_TOPUP_CENTS = 74000;

async function main() {
  // 0. Household row first: owner id (for created_by / actor on the
  // mirrored confirm writes) + current shortfall (for the split).
  const [household] = await rest('GET', 'households', `id=eq.${HOUSEHOLD_ID}&select=id,owner_id,fund_shortfall_cents,base_allowance_cents`);
  if (!household) throw new Error('Test household not found');
  const ownerId = household.owner_id;
  let shortfall = household.fund_shortfall_cents ?? 0;
  console.log(`Household base=${money(household.base_allowance_cents)} shortfall=${money(shortfall)} owner=${ownerId}`);

  // 1. Clean up any previous run's fixtures (idempotency).
  console.log('Cleaning previous video fixtures...');
  await rest('DELETE', 'charity_cash_gifts', `household_id=eq.${HOUSEHOLD_ID}&note=eq.${encodeURIComponent(MARKER + ' cash gift')}`);
  await rest('DELETE', 'charity_income', `household_id=eq.${HOUSEHOLD_ID}&note=eq.${encodeURIComponent(MARKER + ' paycheck')}`);
  await rest('DELETE', 'transactions', `household_id=eq.${HOUSEHOLD_ID}&external_id=like.${MARKER}-%`);

  // 2. Insert the transactions (10 charges + 1 income).
  const allTx = [...CHARGES_CURRENT_WEEK, ...CHARGES_PRIOR_WEEK, INCOME];
  const inserted = [];
  for (const tx of allTx) {
    const kind = tx.amount < 0 ? 'income' : 'charge';
    const row = {
      household_id: HOUSEHOLD_ID,
      date: tx.date,
      merchant: tx.merchant,
      amount_cents: tx.amount,
      card_suffix: tx.suffix,
      source: 'manual',
      state: 'verified',
      kind,
      fund_allocation_cents: 0,
      excluded: false,
      exclude_reason: '',
      late: false,
      external_id: `${MARKER}-${tx.slug}`,
      dedupe_hash: dedupeHash(tx.merchant, tx.date, tx.amount, tx.suffix),
    };
    const [created] = await rest('POST', 'transactions', null, row);
    inserted.push(created);
    console.log(`  inserted ${tx.merchant} ${tx.amount} (${tx.date}) id=${created.id}`);
  }
  const incomeRow = inserted.find((r) => r.external_id === `${MARKER}-paycheck`);
  if (!incomeRow) throw new Error('Paycheck income row was not created');

  // 3. Charity accrual for the paycheck: $1,200 at 10% = $120 committed.
  const [charityRow] = await rest('POST', 'charity_income', null, {
    household_id: HOUSEHOLD_ID,
    transaction_id: incomeRow.id,
    source_label: 'Paycheck',
    amount_cents: 120000,
    income_date: '2026-11-17',
    rate_bp: 1000,
    status: 'active',
    note: `${MARKER} paycheck`,
  });
  console.log(`  charity_income id=${charityRow.id} ($120.00 committed at 10%)`);

  // 4. Cash gift so Given is non-zero: $40 given, $80 still available.
  const [giftRow] = await rest('POST', 'charity_cash_gifts', null, {
    household_id: HOUSEHOLD_ID,
    amount_cents: CASH_GIFT.amount,
    gift_date: CASH_GIFT.date,
    note: CASH_GIFT.note,
    status: 'active',
  });
  console.log(`  charity_cash_gifts id=${giftRow.id} ($40.00 given)`);

  // 5. Fund settings rows, if missing. Without a charity_settings
  // row the Funds Charity rate section renders "Loading rules…"
  // forever (charitySettings stays nil); same for debt_settings
  // under Carried Debt. The app defaults a missing row to 10% /
  // 25% for the numbers, so these inserts change no figure — they
  // only let the rules sections render.
  const charitySettings = await rest('GET', 'charity_settings', `household_id=eq.${HOUSEHOLD_ID}&select=household_id,default_rate_bp`);
  if (charitySettings.length === 0) {
    await rest('POST', 'charity_settings', null, { household_id: HOUSEHOLD_ID, default_rate_bp: 1000 });
    console.log('  charity_settings inserted (default 10%) — was MISSING');
  } else {
    console.log(`  charity_settings already present (default ${charitySettings[0].default_rate_bp}bp)`);
  }
  const debtSettings = await rest('GET', 'debt_settings', `household_id=eq.${HOUSEHOLD_ID}&select=household_id,mode,percent_bp,fixed_cents`);
  if (debtSettings.length === 0) {
    await rest('POST', 'debt_settings', null, { household_id: HOUSEHOLD_ID, mode: 'percent', percent_bp: 2500, fixed_cents: 0 });
    console.log('  debt_settings inserted (25% rule) — was MISSING');
  } else {
    console.log(`  debt_settings already present (mode=${debtSettings[0].mode} ${debtSettings[0].percent_bp}bp)`);
  }

  // 6. Confirm every pending Extra Fund top-up, mirroring
  // confirm_fund_topup (pending-topups.sql) exactly: split against
  // the CURRENT shortfall, ledger 'adjustment' row for the added
  // part, shortfall update, audit row. A pending top-up writes no
  // ledger row, so until this runs Savings shows $0 Available with
  // the whole amount Pending.
  const pendingTopups = await rest('GET', 'fund_topups', `household_id=eq.${HOUSEHOLD_ID}&status=eq.pending&select=id,amount_cents,note,created_at&order=created_at`);
  console.log(`  pending top-ups: ${pendingTopups.length}`);
  for (const topup of pendingTopups) {
    const covered = Math.min(shortfall, topup.amount_cents);
    const added = topup.amount_cents - covered;
    const after = shortfall - covered;
    await rest('PATCH', 'fund_topups', `id=eq.${topup.id}`, {
      status: 'confirmed',
      confirmed_at: new Date().toISOString(),
      confirmed_by: ownerId,
      shortfall_covered_cents: covered,
      fund_added_cents: added,
      shortfall_after_cents: after,
    });
    if (added > 0) {
      await rest('POST', 'fund_ledger', null, {
        household_id: HOUSEHOLD_ID,
        kind: 'adjustment',
        amount_cents: added,
        note: `Manual top-up confirmed: ${topup.amount_cents} cents total; ${covered} cents covered shortfall; ${added} cents added to fund.${topup.note ? ` Note: ${topup.note}` : ''}`,
        created_by: ownerId,
      });
    }
    if (covered > 0) {
      await rest('PATCH', 'households', `id=eq.${HOUSEHOLD_ID}`, { fund_shortfall_cents: after });
      shortfall = after;
    }
    await rest('POST', 'audit_log', null, {
      household_id: HOUSEHOLD_ID,
      actor: ownerId,
      actor_name: 'admin',
      action: 'Extra Fund top-up confirmed',
      detail: `Manual top-up ${topup.amount_cents} cents confirmed in checking: ${covered} cents covered shortfall, ${added} cents added to fund, ${after} cents owed back after.${topup.note ? ` Note: ${topup.note}` : ''}`,
    });
    console.log(`  confirmed top-up ${money(topup.amount_cents)} (covered ${money(covered)}, added ${money(added)}) note=${JSON.stringify(topup.note)}`);
  }

  // 7. Release pending surplus from closed weeks, mirroring
  // week-close's releaseDue exactly: with shortfall $0 the whole
  // surplus goes to the fund (ledger 'release' row + audit row).
  // The v2 Savings Pending ($740) was NOT pending top-ups — there
  // were none — it was two unreleased surplus rows (weeks Nov 1:
  // $365, Nov 8: $375) from earlier test week-closes. Until these
  // release, the Savings card still shows $740 Pending beside the
  // available money. Releasing them is what the app does when a
  // release comes due; both weeks are well past due.
  const pendingReleases = await rest('GET', 'surplus_releases', `household_id=eq.${HOUSEHOLD_ID}&status=eq.pending&select=week_start,surplus_cents,released_cents&order=week_start`);
  console.log(`  pending surplus releases: ${pendingReleases.length}`);
  for (const rel of pendingReleases) {
    const surplus = rel.surplus_cents ?? 0;
    const applied = Math.min(shortfall, surplus);
    const toFund = surplus - applied;
    const claimed = await rest('PATCH', 'surplus_releases', `household_id=eq.${HOUSEHOLD_ID}&week_start=eq.${rel.week_start}&status=eq.pending`, { status: 'released', released_cents: toFund });
    if (!claimed || claimed.length === 0) {
      console.log(`  release week ${rel.week_start} already claimed; skipping`);
      continue;
    }
    if (toFund > 0) {
      await rest('POST', 'fund_ledger', null, {
        household_id: HOUSEHOLD_ID,
        kind: 'release',
        amount_cents: toFund,
        week_start: rel.week_start,
        note: `Surplus released for week ${rel.week_start}`,
        created_by: ownerId,
      });
    }
    if (applied > 0) {
      shortfall -= applied;
      await rest('PATCH', 'households', `id=eq.${HOUSEHOLD_ID}`, { fund_shortfall_cents: shortfall });
    }
    await rest('POST', 'audit_log', null, {
      household_id: HOUSEHOLD_ID,
      actor: ownerId,
      actor_name: 'admin',
      action: 'Surplus released',
      detail: `Surplus ${surplus} cents for week ${rel.week_start} released to the Extra Fund.`,
    });
    console.log(`  released surplus ${money(surplus)} for week ${rel.week_start} (to fund ${money(toFund)})`);
  }

  // 8. Fallback cushion: if Savings Available is still $0 after the
  // confirms (no pending top-ups and no ledger rows at all), insert
  // one confirmed $740 top-up + ledger row so the Savings card shows
  // real available money, not $0 Available / $740 Pending.
  const ledgerRows = await rest('GET', 'fund_ledger', `household_id=eq.${HOUSEHOLD_ID}&select=amount_cents`);
  let ledgerSum = ledgerRows.reduce((s, r) => s + r.amount_cents, 0);
  if (ledgerSum === 0) {
    console.log(`  FALLBACK: Savings Available is $0 — inserting confirmed ${money(FALLBACK_TOPUP_CENTS)} top-up`);
    const clientKey = `${MARKER}-savings-topup`;
    const existing = await rest('GET', 'fund_topups', `household_id=eq.${HOUSEHOLD_ID}&client_key=eq.${clientKey}&select=id,status`);
    if (existing.length === 0) {
      await rest('POST', 'fund_topups', null, {
        household_id: HOUSEHOLD_ID,
        client_key: clientKey,
        amount_cents: FALLBACK_TOPUP_CENTS,
        shortfall_covered_cents: 0,
        fund_added_cents: FALLBACK_TOPUP_CENTS,
        shortfall_after_cents: shortfall,
        note: `${MARKER} savings top-up`,
        created_by: ownerId,
        status: 'confirmed',
        confirmed_at: new Date().toISOString(),
        confirmed_by: ownerId,
      });
      await rest('POST', 'fund_ledger', null, {
        household_id: HOUSEHOLD_ID,
        kind: 'adjustment',
        amount_cents: FALLBACK_TOPUP_CENTS,
        note: `Manual top-up: ${FALLBACK_TOPUP_CENTS} cents total; 0 cents covered shortfall; ${FALLBACK_TOPUP_CENTS} cents added to fund. Note: ${MARKER} savings top-up`,
        created_by: ownerId,
      });
      await rest('POST', 'audit_log', null, {
        household_id: HOUSEHOLD_ID,
        actor: ownerId,
        actor_name: 'admin',
        action: 'Extra Fund top-up recorded',
        detail: `Manual top-up ${FALLBACK_TOPUP_CENTS} cents: 0 cents covered shortfall, ${FALLBACK_TOPUP_CENTS} cents added to fund, ${shortfall} cents owed back after. Note: ${MARKER} savings top-up`,
      });
      ledgerSum = FALLBACK_TOPUP_CENTS;
    } else {
      console.log('  FALLBACK top-up already exists; ledger sum unexpectedly $0 — leaving as-is, see dump');
    }
  }

  // 9. Verify: fixture counts + current-week charges + the
  // authoritative compute-week hero numbers + charity + savings.
  const txs = await rest('GET', 'transactions', `household_id=eq.${HOUSEHOLD_ID}&external_id=like.${MARKER}-%&select=merchant,amount_cents,date`);
  const currentWeekCharges = txs
    .filter((t) => t.amount_cents > 0 && t.date >= WEEK_START)
    .reduce((s, t) => s + t.amount_cents, 0);
  console.log(`VERIFY: ${txs.length} fixture transactions (expected 11). Current-week charges: ${money(currentWeekCharges)} (expected ${money(EXPECTED_CURRENT_WEEK_CHARGES)}).`);
  if (txs.length !== 11) throw new Error(`Expected 11 fixture transactions, found ${txs.length}`);
  if (currentWeekCharges !== EXPECTED_CURRENT_WEEK_CHARGES) throw new Error(`Current-week charges ${currentWeekCharges} != ${EXPECTED_CURRENT_WEEK_CHARGES}`);

  const weekRes = await fetch(`${SUPABASE_URL}/functions/v1/compute-week`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ household_id: HOUSEHOLD_ID, week_start: WEEK_START }),
  });
  const weekText = await weekRes.text();
  if (!weekRes.ok) throw new Error(`compute-week -> HTTP ${weekRes.status}: ${weekText.slice(0, 300)}`);
  const week = JSON.parse(weekText);
  console.log(`VERIFY compute-week ${WEEK_START}: base_available=${money(week.base_available_cents)} charges=${money(week.charges_cents)} available=${money(week.available_cents)} (hero should read ${money(week.available_cents)} left)`);
  const expectedAvailable = 37500 - EXPECTED_CURRENT_WEEK_CHARGES;
  if (week.available_cents !== expectedAvailable) {
    console.log(`VERIFY WARNING: compute-week available ${money(week.available_cents)} != fixture-only ${money(expectedAvailable)} — a non-fixture row (e.g. the pre-existing Week Close Fixture) also counts in this week; check the dump, do not assume a failure.`);
  }

  const incomeRows = await rest('GET', 'charity_income', `household_id=eq.${HOUSEHOLD_ID}&status=eq.active&select=amount_cents,rate_bp`);
  const committed = incomeRows.reduce((s, r) => s + Math.floor((r.amount_cents * r.rate_bp + 5000) / 10000), 0);
  const cashGifts = await rest('GET', 'charity_cash_gifts', `household_id=eq.${HOUSEHOLD_ID}&status=eq.active&select=amount_cents`);
  const given = cashGifts.reduce((s, r) => s + r.amount_cents, 0);
  console.log(`VERIFY charity: committed=${money(committed)} given=${money(given)} available=${money(committed - given)} (expected $120.00 / $40.00 / $80.00).`);

  const stillPending = await rest('GET', 'fund_topups', `household_id=eq.${HOUSEHOLD_ID}&status=eq.pending&select=id,amount_cents`);
  const pendingReleasesNow = await rest('GET', 'surplus_releases', `household_id=eq.${HOUSEHOLD_ID}&status=eq.pending&select=week_start,surplus_cents`);
  const pendingReleaseCents = pendingReleasesNow.reduce((s, r) => s + (r.surplus_cents ?? 0), 0);
  const ledgerNow = await rest('GET', 'fund_ledger', `household_id=eq.${HOUSEHOLD_ID}&select=amount_cents`);
  const savingsAvailable = ledgerNow.reduce((s, r) => s + r.amount_cents, 0);
  console.log(`VERIFY savings: Available=${money(savingsAvailable)} Pending top-ups=${money(stillPending.reduce((s, r) => s + r.amount_cents, 0))} Pending releases=${money(pendingReleaseCents)} (expected Available $1,480.00 — $740 top-up + $740 released surplus — Pending $0.00).`);
  if (stillPending.length !== 0) throw new Error(`Still ${stillPending.length} pending top-up(s)`);
  if (pendingReleasesNow.length !== 0) throw new Error(`Still ${pendingReleasesNow.length} pending surplus release(s)`);
  if (savingsAvailable <= 0) throw new Error('Savings Available is still $0 after confirms + releases + fallback');
  console.log('SEED OK.');
}

main().catch((err) => {
  console.error('SEED FAILED:', err.message);
  process.exit(1);
});
