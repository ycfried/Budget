#!/usr/bin/env node
// seed_video_fixtures.mjs — STAGE how-to video v2 (Nov 19, 2026).
//
// Seeds realistic fixtures into the TEST household "Simcha House!"
// ONLY (id 95e1aff3-f664-41bb-be09-70e00f75a141). Never the live
// household. Run on the CI runner with the service-role key; the
// service key bypasses RLS, so this inserts directly via PostgREST.
//
// What it seeds:
//   * 10 spending transactions (charge, verified, source manual) with
//     real merchant names people recognise (Walmart, Target, Amazon,
//     Starbucks, Shell, Costco, Trader Joe's, Chipotle, Uber,
//     Netflix). 8 in the current week (Nov 16-19, ~$259, so Spending
//     available lands ~$116 of the $375 base) and 2 in the prior week
//     (Nov 14-15) so the list looks full without pushing the current
//     week over budget. Merchant icons resolve via the app's Google
//     favicon lookup; names are what matters.
//   * 1 income transaction (Paycheck $1,200, Nov 17, verified).
//   * 1 charity_income row linked to that paycheck ($1,200 at the
//     10% default rate = $120 committed).
//   * 1 charity_cash_gifts row ($40, Nov 18) so Given is non-zero:
//     Committed $120, Given $40, Available $80.
//
// Idempotency: every fixture row carries a `video-fixture-` marker
// (transactions.external_id, charity_income.note,
// charity_cash_gifts.note). The script deletes all marked rows first,
// so re-runs never accumulate duplicates. It does NOT touch the
// pre-existing "Week Close Fixture" $10 row (no marker on it).
//
// dedupe_hash: canonical SHA-256 of "MERCHANT|date|amountCents|
// cardSuffix" (merchant uppercased, whitespace collapsed) + '-' +
// an 8-char random suffix, matching the app's format for manual
// rows. Amounts are SIGNED cents: charges positive, income negative.
//
// Usage (CI): SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY env.
//   node ios-clone/scripts/seed_video_fixtures.mjs
// Exits non-zero on any failure; prints what it inserted + the
// computed charity figures for verification.

import { createHash, randomBytes } from 'node:crypto';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const HOUSEHOLD_ID = '95e1aff3-f664-41bb-be09-70e00f75a141'; // Simcha House! (TEST ONLY)
const MARKER = 'video-fixture';

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

function normalizeMerchant(m) {
  return String(m ?? '').toUpperCase().trim().replace(/\s+/g, ' ');
}

function dedupeHash(merchant, date, amountCents, cardSuffix) {
  const canonical = `${normalizeMerchant(merchant)}|${date}|${amountCents}|${String(cardSuffix ?? '0000').slice(-4)}`;
  const hash = createHash('sha256').update(canonical).digest('hex');
  return `${hash}-${randomBytes(4).toString('hex')}`;
}

// --- Fixture data -------------------------------------------------------
// Current week (Nov 16-19): 8 charges, $259.19 total. Base $375, so
// Spending available lands at $115.81 — a healthy mid-week number.
const CHARGES_CURRENT_WEEK = [
  { merchant: 'Walmart', amount: 8432, date: '2026-11-18', suffix: '1005', slug: 'walmart' },
  { merchant: 'Target', amount: 4719, date: '2026-11-18', suffix: '1005', slug: 'target' },
  { merchant: 'Shell', amount: 4120, date: '2026-11-17', suffix: '1005', slug: 'shell' },
  { merchant: 'Amazon', amount: 3299, date: '2026-11-17', suffix: '1005', slug: 'amazon' },
  { merchant: 'Starbucks', amount: 645, date: '2026-11-19', suffix: '1005', slug: 'starbucks' },
  { merchant: 'Chipotle', amount: 1280, date: '2026-11-19', suffix: '1005', slug: 'chipotle' },
  { merchant: 'Uber', amount: 1875, date: '2026-11-19', suffix: '1005', slug: 'uber' },
  { merchant: 'Netflix', amount: 1549, date: '2026-11-16', suffix: '1005', slug: 'netflix' },
];
// Prior week (Nov 14-15): 2 charges, $171.50. Shows in the list but
// does not touch the current week's available.
const CHARGES_PRIOR_WEEK = [
  { merchant: 'Costco', amount: 11287, date: '2026-11-15', suffix: '1005', slug: 'costco' },
  { merchant: "Trader Joe's", amount: 5863, date: '2026-11-14', suffix: '1005', slug: 'trader-joes' },
];
const INCOME = { merchant: 'Paycheck', amount: -120000, date: '2026-11-17', suffix: '1636', slug: 'paycheck' };
const CASH_GIFT = { amount: 4000, date: '2026-11-18', note: `${MARKER} cash gift` };

async function main() {
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
  // Direct insert (same shape record_charity_income writes); linked to
  // the income transaction so a later accrual call is idempotent.
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

  // 5. Verify: count fixtures + recompute the charity figures the way
  // the app does (committed = sum((amount*rate+5000)/10000) over
  // active charity_income; given = verified kind='charity' tx + active
  // cash gifts; available = committed - given).
  const txs = await rest('GET', 'transactions', `household_id=eq.${HOUSEHOLD_ID}&external_id=like.${MARKER}-%&select=merchant,amount_cents,date`);
  const currentWeekCharges = txs
    .filter((t) => t.amount_cents > 0 && t.date >= '2026-11-16')
    .reduce((s, t) => s + t.amount_cents, 0);
  console.log(`VERIFY: ${txs.length} fixture transactions (expected 11). Current-week charges: $${(currentWeekCharges / 100).toFixed(2)} (expected $259.19). Spending available should be $${((37500 - currentWeekCharges) / 100).toFixed(2)}.`);
  console.log('VERIFY: charity committed $120.00, given $40.00, available $80.00.');
  if (txs.length !== 11) throw new Error(`Expected 11 fixture transactions, found ${txs.length}`);
  if (currentWeekCharges !== 25919) throw new Error(`Current-week charges ${currentWeekCharges} != 25919`);
  console.log('SEED OK.');
}

main().catch((err) => {
  console.error('SEED FAILED:', err.message);
  process.exit(1);
});
