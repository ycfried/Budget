#!/usr/bin/env node
// dump_test_household.mjs — STAGE how-to video v3 (Nov 19, 2026).
//
// READ-ONLY state dump for the TEST household "Simcha House!" ONLY
// (id 95e1aff3-f664-41bb-be09-70e00f75a141). Never the live household,
// never writes anything. Run on the CI runner with the service-role
// key; the service key bypasses RLS, so this reads directly via
// PostgREST + the compute-week edge function (which accepts the
// service key as Bearer — dual auth, Nov 16, 2026).
//
// What it prints, so the numbers the owner will record can be
// verified from the same data the app reads:
//   * households row (base allowance, shortfall, owner)
//   * members + roles
//   * every transaction (date, merchant, amount, kind, state,
//     source, excluded, external_id) — the Transactions list
//   * charity_settings / debt_settings rows (a missing
//     charity_settings row is why Funds shows "Loading rules…"
//     forever: the rate section renders only once the row exists)
//   * charity_income (active) + charity_cash_gifts (active) and the
//     derived Committed / Given / Available
//   * fund_topups (every row: amount, status, split) and the
//     fund_ledger sum — Savings Available is the ledger sum;
//     Pending is pending top-ups + pending/held surplus releases
//   * surplus_releases + week_closes (anything that could move the
//     hero or the Savings pending figure)
//   * compute-week for week_start 2026-11-15 (Sunday; the current
//     week Nov 15-21) — the authoritative hero numbers
//     (base_available_cents, charges_cents, available_cents).
//
// Usage (CI): SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY env.
//   node ios-clone/scripts/dump_test_household.mjs
// Exits 0 always (read-only); prints DUMP lines for grep.

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const HOUSEHOLD_ID = '95e1aff3-f664-41bb-be09-70e00f75a141'; // Simcha House! (TEST ONLY)
const WEEK_START = '2026-11-15'; // Sunday; current week Nov 15-21, 2026
const WEEK_END = '2026-11-21';

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error('BLOCKED: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.');
  process.exit(2);
}

const headers = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  'Content-Type': 'application/json',
};

async function rest(method, table, query) {
  const url = `${SUPABASE_URL}/rest/v1/${table}${query ? `?${query}` : ''}`;
  const res = await fetch(url, { method, headers });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`${method} ${table}${query ? `?${query}` : ''} -> HTTP ${res.status}: ${text.slice(0, 300)}`);
  }
  return text ? JSON.parse(text) : null;
}

const get = (table, query) => rest('GET', table, query);
const money = (c) => `$${(c / 100).toFixed(2)}`;

async function main() {
  console.log(`DUMP household=${HOUSEHOLD_ID} week=${WEEK_START}..${WEEK_END}`);

  const [hh] = await get('households', `id=eq.${HOUSEHOLD_ID}&select=id,name,base_allowance_cents,fund_shortfall_cents,owner_id,fund_names`);
  console.log(`DUMP household: name=${JSON.stringify(hh?.name)} base=${hh?.base_allowance_cents} shortfall=${hh?.fund_shortfall_cents} owner=${hh?.owner_id} fund_names=${JSON.stringify(hh?.fund_names)}`);

  const members = await get('household_members', `household_id=eq.${HOUSEHOLD_ID}&select=user_id,role,display_name&order=created_at`);
  for (const m of members) console.log(`DUMP member: user=${m.user_id} role=${m.role} name=${JSON.stringify(m.display_name)}`);

  const txs = await get('transactions', `household_id=eq.${HOUSEHOLD_ID}&select=date,merchant,amount_cents,kind,state,source,excluded,fund_allocation_cents,external_id&order=date.desc&order=created_at.desc&limit=200`);
  console.log(`DUMP transactions: ${txs.length} rows`);
  for (const t of txs) {
    console.log(`DUMP tx: ${t.date} ${t.merchant} ${money(t.amount_cents)} kind=${t.kind} state=${t.state} src=${t.source} excl=${t.excluded} alloc=${t.fund_allocation_cents} ext=${t.external_id}`);
  }

  const charitySettings = await get('charity_settings', `household_id=eq.${HOUSEHOLD_ID}&select=household_id,default_rate_bp`);
  console.log(`DUMP charity_settings: ${charitySettings.length ? `default_rate_bp=${charitySettings[0].default_rate_bp}` : 'MISSING (Funds shows "Loading rules…" forever)'}`);
  const debtSettings = await get('debt_settings', `household_id=eq.${HOUSEHOLD_ID}&select=household_id,mode,percent_bp,fixed_cents`);
  console.log(`DUMP debt_settings: ${debtSettings.length ? `mode=${debtSettings[0].mode} percent_bp=${debtSettings[0].percent_bp} fixed=${debtSettings[0].fixed_cents}` : 'MISSING (Funds debt rule shows "Loading rules…" forever)'}`);

  const income = await get('charity_income', `household_id=eq.${HOUSEHOLD_ID}&select=amount_cents,rate_bp,status,source_label,note&order=income_date.desc`);
  const committed = income.filter((r) => r.status === 'active').reduce((s, r) => s + Math.floor((r.amount_cents * r.rate_bp + 5000) / 10000), 0);
  console.log(`DUMP charity_income: ${income.length} rows, committed=${money(committed)}`);
  for (const r of income) console.log(`DUMP charity_income: ${money(r.amount_cents)} @${r.rate_bp}bp status=${r.status} src=${JSON.stringify(r.source_label)} note=${JSON.stringify(r.note)}`);
  const gifts = await get('charity_cash_gifts', `household_id=eq.${HOUSEHOLD_ID}&select=amount_cents,gift_date,status,note&order=gift_date.desc`);
  const givenCash = gifts.filter((r) => r.status === 'active').reduce((s, r) => s + r.amount_cents, 0);
  console.log(`DUMP charity_cash_gifts: ${gifts.length} rows, active total=${money(givenCash)}`);
  for (const r of gifts) console.log(`DUMP charity_cash_gift: ${money(r.amount_cents)} ${r.gift_date} status=${r.status} note=${JSON.stringify(r.note)}`);
  const charityTx = txs.filter((t) => t.kind === 'charity' && t.state === 'verified' && !t.excluded);
  const givenTx = charityTx.reduce((s, t) => s + t.amount_cents, 0);
  console.log(`DUMP charity: committed=${money(committed)} given=${money(givenTx + givenCash)} (tx ${money(givenTx)} + cash ${money(givenCash)}) available=${money(committed - givenTx - givenCash)}`);

  const topups = await get('fund_topups', `household_id=eq.${HOUSEHOLD_ID}&select=id,amount_cents,status,shortfall_covered_cents,fund_added_cents,note,created_at&order=created_at.desc`);
  const pendingTopups = topups.filter((r) => r.status === 'pending').reduce((s, r) => s + r.amount_cents, 0);
  console.log(`DUMP fund_topups: ${topups.length} rows, pending total=${money(pendingTopups)}`);
  for (const r of topups) console.log(`DUMP topup: ${money(r.amount_cents)} status=${r.status} covered=${r.shortfall_covered_cents} added=${r.fund_added_cents} note=${JSON.stringify(r.note)} ${r.created_at}`);
  const ledger = await get('fund_ledger', `household_id=eq.${HOUSEHOLD_ID}&select=kind,amount_cents,note,created_at&order=created_at.desc`);
  const ledgerSum = ledger.reduce((s, r) => s + r.amount_cents, 0);
  console.log(`DUMP fund_ledger: ${ledger.length} rows, sum (Savings Available)=${money(ledgerSum)}`);
  for (const r of ledger) console.log(`DUMP ledger: ${r.kind} ${money(r.amount_cents)} note=${JSON.stringify(r.note)} ${r.created_at}`);
  const releases = await get('surplus_releases', `household_id=eq.${HOUSEHOLD_ID}&select=status,surplus_cents,released_cents,week_start&order=week_start.desc`);
  const pendingRel = releases.filter((r) => r.status === 'pending').reduce((s, r) => s + Math.max(0, r.surplus_cents - r.released_cents), 0);
  const heldRel = releases.filter((r) => r.status === 'held').reduce((s, r) => s + r.surplus_cents, 0);
  console.log(`DUMP surplus_releases: ${releases.length} rows, pending=${money(pendingRel)} held=${money(heldRel)}`);
  for (const r of releases) console.log(`DUMP release: week=${r.week_start} status=${r.status} surplus=${money(r.surplus_cents)} released=${money(r.released_cents)}`);
  console.log(`DUMP savings: Available=${money(ledgerSum)} Pending=${money(pendingRel + heldRel + pendingTopups)} (releases ${money(pendingRel + heldRel)} + topups ${money(pendingTopups)}) Total=${money(ledgerSum + pendingRel + heldRel + pendingTopups)}`);

  const closes = await get('week_closes', `household_id=eq.${HOUSEHOLD_ID}&select=week_start,surplus_cents,outgoing_debt_cents,debt_payment_cents&order=week_start.desc`);
  console.log(`DUMP week_closes: ${closes.length} rows`);
  for (const c of closes) console.log(`DUMP close: week=${c.week_start} surplus=${money(c.surplus_cents)} outgoing_debt=${money(c.outgoing_debt_cents)} debt_payment=${c.debt_payment_cents}`);

  // Authoritative hero numbers, exactly as the app reads them.
  const weekRes = await fetch(`${SUPABASE_URL}/functions/v1/compute-week`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ household_id: HOUSEHOLD_ID, week_start: WEEK_START }),
  });
  const weekText = await weekRes.text();
  if (!weekRes.ok) throw new Error(`compute-week -> HTTP ${weekRes.status}: ${weekText.slice(0, 300)}`);
  const week = JSON.parse(weekText);
  console.log(`DUMP compute-week ${WEEK_START}: base_available=${money(week.base_available_cents)} temp=${money(week.temp_cents)} debt=${money(week.carried_debt_cents)} charges=${money(week.charges_cents)} available=${money(week.available_cents)} debt_payment=${money(week.debt_payment_cents)} locked=${week.week_locked}`);
  console.log('DUMP OK.');
}

main().catch((err) => {
  console.error('DUMP FAILED:', err.message);
  process.exit(1);
});
