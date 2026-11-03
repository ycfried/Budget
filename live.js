// Household Budget — LIVE front end (Supabase).
//   * Real Supabase Auth (email + password, two accounts only).
//   * First account creates the household as admin; second joins by ID.
//   * Transactions, fund requests, and audit log read/write the shared DB.
//   * Week numbers come from the server (compute-week Edge Function),
//     never from client-side math alone.
//   * Admin-only settings and savings attestation run through RPCs with
//     explicit role checks. Fund allocations against the fund balance
//     are still missing (approve/decline is a decision record only).
//   * User-facing labels are bank-agnostic by design: internal function
//     and database names (plaid-*, source='plaid') stay as-is, but the
//     UI never names a bank or provider.
// S4 (live UI) notes — read before touching admin UI:
//   * Hiding an admin button from a non-admin is PRESENTATION ONLY. Role
//     enforcement lives in the server RPCs / Edge Functions / RLS; a member
//     calling an admin RPC directly must still be refused server-side.
//   * Week numbers come from compute-week under the FINAL-spec contract:
//     {week_start, base_available_cents, temp_cents, carried_debt_cents,
//     charges_cents, available_cents, week_locked,
//     pending_refund_excluded_cents}. No credit/R/X fields are used, and
//     the client never sends D, T, or R_in to compute-week.
//   * Bank connection state comes from the server plaid_items /
//     plaid_accounts rows, never from per-device localStorage.
//   * The demo entry is demo.html (app.js); the public root is landing.html
//     content in index.html. Live styling stays under body.live / #view-app.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';
import { formatCents, weekStartOf, nyTodayString } from './engine.mjs';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const dollarsToCents = (s) => Math.round(Number(s) * 100);
// Strict money-input parsing (S4): empty, blank, or non-numeric input is
// null — never 0. Callers reject null instead of sending 0 for an empty
// field. An explicitly typed "0" parses to 0 and is the caller's choice.
const parseDollarsStrict = (s) => {
  if (s === null || s === undefined) return null;
  const t = String(s).trim();
  if (!t || !/^-?\d+(\.\d{1,2})?$/.test(t)) return null;
  const n = Number(t);
  if (!Number.isFinite(n)) return null;
  return Math.round(n * 100);
};
// Curated institution-name -> logo domain map (bank logos only; no token
// or account data is ever rendered). Fallback is a letter tile.
const BANK_LOGO_DOMAINS = [
  ['american express', 'americanexpress.com'], ['bank of america', 'bankofamerica.com'],
  ['capital one', 'capitalone.com'], ['chase', 'chase.com'], ['citi', 'citibank.com'],
  ['discover', 'discover.com'], ['pnc', 'pnc.com'], ['td', 'td.com'],
  ['us bank', 'usbank.com'], ['wells fargo', 'wellsfargo.com'],
];
const bankDomainFor = (name) => {
  const n = String(name || '').toLowerCase();
  for (const [k, d] of BANK_LOGO_DOMAINS) if (n.includes(k)) return d;
  return null;
};
// ONE shared merchant-icon helper, used by BOTH Purchases rows and Home
// recent rows. Curated keyword -> domain; anything unmapped (or any logo
// load failure) falls back to the existing merchant-initial tile.
const MERCHANT_LOGO_DOMAINS = [
  ['trader joe', 'traderjoes.com'], ['whole foods', 'wholefoodsmarket.com'],
  ['home depot', 'homedepot.com'], ["lowe", 'lowes.com'], ['shoprite', 'shoprite.com'],
  ['mcdonald', 'mcdonalds.com'], ['starbucks', 'starbucks.com'], ['chipotle', 'chipotle.com'],
  ['amazon', 'amazon.com'], ['walmart', 'walmart.com'], ['target', 'target.com'],
  ['costco', 'costco.com'], ['apple', 'apple.com'], ['cvs', 'cvs.com'],
  ['walgreens', 'walgreens.com'], ['exxon', 'exxon.com'], ['shell', 'shell.com'],
  ['uber', 'uber.com'], ['lyft', 'lyft.com'], ['netflix', 'netflix.com'], ['spotify', 'spotify.com'],
];
const merchantDomainFor = (name) => {
  const n = String(name || '').toLowerCase();
  for (const [k, d] of MERCHANT_LOGO_DOMAINS) if (n.includes(k)) return d;
  return null;
};
function iconForMerchant(name) {
  const safe = String(name || '?');
  const initial = esc(safe.trim().charAt(0).toUpperCase() || '?');
  const domain = merchantDomainFor(safe);
  if (!domain) return `<span class="tx-icon" aria-hidden="true">${initial}</span>`;
  // On logo failure the <img> removes itself and the tile shows its letter.
  return `<span class="tx-icon tx-icon-logo" aria-hidden="true"><img class="tx-logo" src="https://logo.clearbit.com/${domain}" alt="" loading="lazy" onerror="var p=this.parentNode;this.remove();p.textContent='${initial}';"></span>`;
}
function bankLogoHtml(name) {
  const initial = esc(String(name || '?').trim().charAt(0).toUpperCase() || '?');
  const domain = bankDomainFor(name);
  if (!domain) return `<span class="bank-logo-tile" aria-hidden="true">${initial}</span>`;
  return `<span class="bank-logo" aria-hidden="true"><img class="bank-logo-img" src="https://logo.clearbit.com/${domain}" alt="" loading="lazy" onerror="var p=this.parentNode;this.remove();p.textContent='${initial}';p.classList.add('bank-logo-tile');"></span>`;
}
// Transaction state pill: 'reversed' renders as Reversed, never Posted.
function statePill(t, excluded) {
  if (excluded) return '<span class="pill warn">Excluded</span>';
  if (t.state === 'reversed') return '<span class="pill rev">Reversed</span>';
  if (t.state === 'provisional') return '<span class="pill warn">Pending</span>';
  return '<span class="pill ok">Posted</span>';
}
function stateWord(t, excluded) {
  if (excluded) return 'excluded from week math';
  if (t.state === 'reversed') return 'reversed (does not count)';
  if (t.state === 'provisional') return 'pending';
  return 'posted';
}
// Canonical CSV dedupe key (client preview): normalized merchant / date /
// amount / suffix. Normalization collapses whitespace and drops punctuation
// so "Trader Joe's" and "TRADER JOES" dedupe; the stored dedupe_hash below
// keeps the manual-insert form (uppercased merchant) so it stays consistent
// with the existing unique (household_id, dedupe_hash) constraint.
const normalizeMerchant = (m) => String(m || '').toUpperCase().trim().replace(/\s+/g, ' ');
const csvRowKey = (r) => `${normalizeMerchant(r.merchant).replace(/[^A-Z0-9 ]/g, '')}|${r.date}|${r.amountCents}|${r.suffix}`;
function parseAmountLive(raw) {
  let s = String(raw).trim().replace(/[$,]/g, '');
  let neg = false;
  if (s.startsWith('(') && s.endsWith(')')) { neg = true; s = s.slice(1, -1); }
  const n = Number(s);
  if (!Number.isFinite(n)) return null;
  return Math.round(Math.abs(n) * 100) * (neg || n < 0 ? -1 : 1);
}
// Port of the demo CSV parser (app.js parseCsv): header Date/Description/
// Amount/Card Ending, quote-aware split, YYYY-MM-DD or MM/DD/YYYY dates.
// Returns {rows, errors}; rows carry no insert until the user confirms.
function parseCsvLive(text) {
  const lines = String(text).split(/\r?\n/).filter((l) => l.trim());
  if (lines.length < 2) return { rows: [], errors: ['CSV needs a header row and at least one data row.'] };
  const split = (line) => {
    const out = []; let cur = '', inQ = false;
    for (const ch of line) {
      if (ch === '"') inQ = !inQ;
      else if (ch === ',' && !inQ) { out.push(cur); cur = ''; }
      else cur += ch;
    }
    out.push(cur); return out.map((v) => v.trim());
  };
  const header = split(lines[0]).map((h) => h.toLowerCase());
  const di = header.findIndex((h) => h.includes('date'));
  const mi = header.findIndex((h) => h.includes('description') || h.includes('merchant'));
  const ai = header.findIndex((h) => h.includes('amount'));
  const si = header.findIndex((h) => h.includes('ending') || h.includes('card'));
  if (di < 0 || mi < 0 || ai < 0) return { rows: [], errors: ['Header must include Date, Description, and Amount columns.'] };
  const rows = []; const errors = [];
  for (const line of lines.slice(1)) {
    const cols = split(line);
    const dateRaw = cols[di] || '';
    const merchant = normalizeMerchant(cols[mi] || '');
    const cents = parseAmountLive(cols[ai] || '');
    const suffixMatch = si >= 0 ? String(cols[si] || '').match(/(\d{4})\s*$/) : null;
    const suffix = suffixMatch ? suffixMatch[1] : '0000';
    let date = dateRaw;
    const mdy = dateRaw.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
    if (mdy) date = `${mdy[3]}-${mdy[1].padStart(2, '0')}-${mdy[2].padStart(2, '0')}`;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !merchant || cents === null) { errors.push(`Skipped unparseable row: ${line}`); continue; }
    rows.push({ date, merchant, amountCents: cents, suffix });
  }
  return { rows, errors };
}
let pendingCsvRows = []; // previewed, NOT inserted, until the user confirms

const sha = async (text) => {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
};

let session = null;
let household = null; // { household_id, role }
let txFilter = 'all'; // all | pending | posted | refunds | excluded
let txSort = localStorage.getItem('hb-tx-sort') || 'date-desc'; // date-desc | date-asc | amount-asc | amount-desc
let txMonth = localStorage.getItem('hb-tx-month') || 'all'; // 'all' or 'YYYY-MM'
let txCard = localStorage.getItem('hb-tx-card') || 'all'; // 'all' or card suffix
let txWeekOnly = false; // spec B5: transactions filter by week (client-side, current Sun–Sat week)
let txLimit = 100; // purchases load in pages of 100; Load more raises it
let weekCloseRan = false; // week-close runs itself once per session (admin only)
let lastRefreshAt = 0; // tab taps refresh in the background, throttled
let currentWeekData = null; // last compute-week result, for per-stat breakdowns
// Generic display labels for transaction sources. Database values are
// unchanged (e.g. 'plaid'); only what the user sees is bank-agnostic.
const sourceLabel = (s) => ({ plaid: 'Bank', manual: 'By hand', csv: 'File', amex_alert: 'Email alert' }[s] ?? String(s));

async function show(view) {
  $('view-auth').classList.toggle('hidden', view !== 'auth');
  $('view-household').classList.toggle('hidden', view !== 'household');
  $('view-app').classList.toggle('hidden', view !== 'app');
}

async function loadMembership() {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;
  const { data, error } = await supabase.from('household_members')
    .select('household_id, role').eq('user_id', user.id).limit(1).maybeSingle();
  // Surface membership-read failures instead of silently staying on the
  // household screen (the Nov 1 stuck-screen bug was exactly this: a
  // broken read policy made this return nothing with no visible error).
  if (error) {
    const el = $('householdMsg');
    if (el) el.textContent = `Could not load your household membership: ${error.message}`;
    console.warn('loadMembership failed:', error.message);
  }
  return data;
}

async function audit(action, detail) {
  if (!household) return;
  const { data: { user } } = await supabase.auth.getUser();
  // Audit is append-only; inserts go through RLS. If RLS blocks the insert
  // (no insert policy yet), the action still happened — the failure is
  // surfaced in the console, not hidden by faking a row.
  const { error } = await supabase.from('audit_log').insert({
    household_id: household.household_id,
    actor: user?.id ?? null,
    actor_name: user?.email ?? household.role,
    action, detail,
  });
  if (error) console.warn('audit insert blocked (expected until insert policies land):', error.message);
}

async function refresh() {
  if (!household) return;
  const rb = document.getElementById('refreshBtn');
  if (rb) { rb.disabled = true; rb.textContent = 'Updating…'; }
  try {
  // Webhook-triggered auto-sync happens first, so the numbers and
  // list below already include any purchases Plaid just announced.
  await Promise.race([autoSyncIfWebhookPending(), new Promise((r) => setTimeout(r, 8000))]);

  const { data: { session: s } } = await supabase.auth.getSession();
  const pe = document.getElementById('profileEmail'); if (pe && s?.user?.email) pe.textContent = s.user.email;
  const pr = document.getElementById('profileRole'); if (pr) pr.textContent = household.role;
  const token = s?.access_token ?? '';
  // Week numbers from the server (FINAL-spec contract). The client sends
  // ONLY household_id — never D, T, or R_in — and never chains any credit:
  // there is no credit field in this contract at all.
  let baseAllowanceCents = null;
  try {
    const { data: hhRow } = await supabase.from('households')
      .select('base_allowance_cents').eq('id', household.household_id).maybeSingle();
    if (hhRow && Number.isInteger(hhRow.base_allowance_cents)) baseAllowanceCents = hhRow.base_allowance_cents;
  } catch (e) { console.warn('base allowance read failed:', e); }
  // Weeks close themselves (admin only, once per session) — unchanged.
  if (household.role === 'admin' && !weekCloseRan) {
    try {
      const out = await callFn('week-close', { household_id: household.household_id });
      if (!out.error) weekCloseRan = true;
    } catch (e) { /* retry next refresh */ }
  }
  const weekErrEl = document.getElementById('weekError');
  const clearWeekNumbers = () => {
    $('weekLabel').textContent = 'Week numbers unavailable';
    $('weeklyAvailable').textContent = '—';
    $('statAllowance').textContent = '—'; $('statSpent').textContent = '—';
    $('statDebt').textContent = '—'; $('statOutgoing').textContent = '—';
    const bar = document.getElementById('weekProgressBar');
    if (bar) { bar.style.width = '0%'; bar.parentElement?.classList.remove('over'); }
    const pt = document.getElementById('weekProgressText');
    if (pt) pt.textContent = '';
    currentWeekData = null;
  };
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/compute-week`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
      body: JSON.stringify({ household_id: household.household_id }),
    });
    const week = await res.json();
    const r = week.result ?? week;
    const hasFields = r && Number.isInteger(r.base_available_cents) && Number.isInteger(r.temp_cents)
      && Number.isInteger(r.carried_debt_cents) && Number.isInteger(r.charges_cents)
      && Number.isInteger(r.available_cents);
    if (!hasFields) {
      if (weekErrEl) { weekErrEl.textContent = "Couldn't update this week's numbers — switch tabs or reopen the app to try again."; weekErrEl.classList.remove('hidden'); }
      clearWeekNumbers();
    } else {
      if (weekErrEl) weekErrEl.classList.add('hidden');
      const weekStart = week.week_start ?? r.week_start ?? null;
      const baseAvailable = r.base_available_cents, tempC = r.temp_cents;
      const carried = r.carried_debt_cents, charges = r.charges_cents, avail = r.available_cents;
      // Outgoing debt is derived from server outputs only (no credit):
      // new debt = charges above base room + temp room; outgoing = carried + new.
      const newDebt = Math.max(0, charges - baseAvailable - tempC);
      const outgoingDebt = carried + newDebt;
      if (weekStart) $('weekLabel').textContent = `Week of ${fmtLong(weekStart)} (Sun–Sat)`;
      $('weeklyAvailable').innerHTML = formatCentsHtml(avail);
      $('weeklyAvailable').classList.toggle('negative', avail < 0);
      $('statAllowance').innerHTML = formatCentsHtml(baseAllowanceCents ?? baseAvailable);
      $('statSpent').innerHTML = formatCentsHtml(charges);
      $('statDebt').innerHTML = formatCentsHtml(carried);
      $('statOutgoing').innerHTML = formatCentsHtml(outgoingDebt);
      currentWeekData = { weekStart, baseAvailableCents: baseAvailable, tempCents: tempC,
        carriedDebtCents: carried, chargesCents: charges, availableCents: avail,
        outgoingDebtCents: outgoingDebt, weekLocked: !!r.week_locked,
        pendingRefundExcludedCents: r.pending_refund_excluded_cents ?? 0,
        baseAllowanceCents };
      // Hero progress, debt-aware: spending room is base room + temp room
      // (carried debt already came off the top). Overspend is NOT silently
      // capped: the bar fills and an explicit "Over by" amount is shown.
      const capacity = baseAvailable + tempC;
      const pct = capacity > 0 ? (charges / capacity) * 100 : (charges > 0 ? 100 : 0);
      const bar = document.getElementById('weekProgressBar');
      if (bar) { bar.style.width = `${Math.min(100, Math.round(pct))}%`; bar.parentElement?.classList.toggle('over', charges > capacity); }
      const pt = document.getElementById('weekProgressText');
      if (pt) {
        let t = `Spent ${formatCents(charges)} of ${formatCents(capacity)} spending room`;
        if (carried > 0) t += ` · ${formatCents(carried)} carried debt already came off the top`;
        if (charges > capacity) t += ` · Over by ${formatCents(charges - capacity)}`;
        if (r.week_locked) t += ' · This week is locked';
        if ((r.pending_refund_excluded_cents ?? 0) > 0) t += ` · ${formatCents(r.pending_refund_excluded_cents)} in pending refunds excluded from this week`;
        pt.textContent = t;
      }
      lastRefreshAt = Date.now();
      const allowInput = document.getElementById('baseAllowanceInput');
      if (allowInput && document.activeElement !== allowInput && baseAllowanceCents !== null) allowInput.value = (baseAllowanceCents / 100).toFixed(2);
    }
  } catch (e) {
    console.warn('compute-week failed:', e);
    if (weekErrEl) { weekErrEl.textContent = "Couldn't update this week's numbers — check your connection and try again."; weekErrEl.classList.remove('hidden'); }
    clearWeekNumbers();
  }

  const { data: txns, error: txErr } = await supabase.from('transactions')
    .select('*').eq('household_id', household.household_id)
    .order('date', { ascending: false }).limit(txLimit);
  // Read failures are an ERROR STATE, never a silent empty list or stale
  // numbers: txReadFailed overrides the lists below.
  const txReadFailed = !!txErr;
  if (txErr) console.warn('transactions read failed:', txErr.message);
  const all = txReadFailed ? [] : (txns ?? []);
  const q = ($('txSearch')?.value ?? '').trim().toLowerCase();
  const byFilter = (t) => txFilter === 'all' ? true
    : txFilter === 'pending' ? t.state === 'provisional'
    : txFilter === 'posted' ? t.state === 'verified'
    : txFilter === 'refunds' ? t.kind === 'refund'
    : txFilter === 'excluded' ? (t.excluded === true || t.state === 'excluded')
    : true;
  // This-week filter: current Sunday–Saturday in America/New_York.
  const todayNy = nyTodayString();
  const todayD = new Date(`${todayNy}T12:00:00`);
  const sundayD = new Date(todayD); sundayD.setDate(todayD.getDate() - todayD.getDay());
  const saturdayD = new Date(sundayD); saturdayD.setDate(saturdayD.getDate() + 6);
  const fmtD = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const weekStartStr = fmtD(sundayD); const weekEndStr = fmtD(saturdayD);
  const inThisWeek = (t) => t.date >= weekStartStr && t.date <= weekEndStr;
  const shown = all.filter((t) => byFilter(t) && (txMonth === 'all' || String(t.date).startsWith(txMonth)) && (txCard === 'all' || String(t.card_suffix) === txCard) && (!txWeekOnly || inThisWeek(t)) && (!q
    || t.merchant.toLowerCase().includes(q)
    || String(t.date).includes(q)
    || formatCents(t.amount_cents).toLowerCase().includes(q)));
  const sorters = {
    'date-desc': (a, b) => b.date.localeCompare(a.date),
    'date-asc': (a, b) => a.date.localeCompare(b.date),
    'amount-asc': (a, b) => (Math.abs(a.amount_cents) - Math.abs(b.amount_cents)) || b.date.localeCompare(a.date),
    'amount-desc': (a, b) => (Math.abs(b.amount_cents) - Math.abs(a.amount_cents)) || b.date.localeCompare(a.date),
  };
  shown.sort(sorters[txSort] ?? sorters['date-desc']);
  const sortEl = $('txSort');
  if (sortEl) sortEl.value = txSort;
  // Month + card dropdowns are built from the months/cards actually
  // present in the loaded transactions, newest first.
  const monthSel = $('txMonth');
  if (monthSel) {
    const months = [...new Set(all.map((t) => String(t.date).slice(0, 7)))].sort().reverse();
    const cur = months.includes(txMonth) ? txMonth : 'all';
    if (cur !== txMonth) { txMonth = cur; localStorage.setItem('hb-tx-month', cur); }
    monthSel.innerHTML = '<option value="all">All months</option>' + months.map((m) => {
      const [y, mo] = m.split('-');
      const label = new Date(`${m}-02T12:00:00`).toLocaleString('en-US', { month: 'long', year: 'numeric' });
      return `<option value="${esc(m)}"${m === txMonth ? ' selected' : ''}>${esc(label)}</option>`;
    }).join('');
  }
  const cardSel = $('txCard');
  if (cardSel) {
    const cards = [...new Set(all.map((t) => String(t.card_suffix)))].sort();
    const cur = cards.includes(txCard) ? txCard : 'all';
    if (cur !== txCard) { txCard = cur; localStorage.setItem('hb-tx-card', cur); }
    cardSel.innerHTML = '<option value="all">All cards</option>' + cards.map((c) =>
      `<option value="${esc(c)}"${c === txCard ? ' selected' : ''}>••${esc(c)}</option>`).join('');
  }
  const thisWeekTxns = all.filter((t) => inThisWeek(t) && !(t.excluded === true || t.state === 'excluded'));
  const emptyHintEl = document.getElementById('weekEmptyHint');
  if (emptyHintEl) emptyHintEl.classList.toggle('hidden', thisWeekTxns.length > 0);
  const countEl = $('txCount');
  if (countEl) {
    const shownTotal = shown.filter((t) => !(t.excluded === true || t.state === 'excluded')).reduce((s, t) => s + t.amount_cents, 0);
    const capped = all.length >= txLimit ? ' of loaded purchases — tap Load more for older ones' : ' of loaded purchases';
    countEl.textContent = txReadFailed ? 'Could not load purchases — try again.' : `Showing ${shown.length}${capped}${txWeekOnly ? ' · this week only' : ''} · total ${formatCents(shownTotal)} (excluded rows not counted)`;
  }
  const loadMore = $('txLoadMore');
  if (loadMore) loadMore.classList.toggle('hidden', all.length < txLimit);
  const weekBtn = $('txWeekToggle');
  if (weekBtn) {
    weekBtn.classList.toggle('active', txWeekOnly);
    weekBtn.setAttribute('aria-pressed', txWeekOnly ? 'true' : 'false');
  }
  document.querySelectorAll('[data-tx-filter]').forEach((c) => {
    c.classList.toggle('active', c.dataset.txFilter === txFilter);
    c.setAttribute('aria-pressed', c.dataset.txFilter === txFilter ? 'true' : 'false');
  });
  const emptyHint = txFilter === 'excluded'
    ? 'No excluded transactions. Excluded purchases are hidden from the week math but kept here so you can restore them.'
    : txFilter === 'refunds'
    ? 'No refunds in this list yet.'
    : 'No purchases here yet — add one by hand above, or connect a bank account and sync.';
  $('txList').innerHTML = txReadFailed
    ? `<li class="tx-empty error">Could not load purchases. Check your connection and try again — nothing here is a complete list.</li>`
    : shown.length
    ? shown.map((t) => {
        const excluded = t.excluded === true || t.state === 'excluded';
        const isAdmin = household.role === 'admin';
        // Delete is honest about what it can do: a hand-entered
        // purchase can be truly deleted; a bank/email/file record
        // cannot be erased (the bank would re-sync it), so for those
        // "Remove" excludes it from the week and keeps the record.
        const deleteBtn = !isAdmin ? ''
          : t.source === 'manual'
          ? `<button class="btn btn-small btn-danger" data-delete-tx="${t.id}" type="button" aria-label="Delete ${esc(t.merchant)}">Delete</button>`
          : `<button class="btn btn-small btn-danger" data-remove-tx="${t.id}" type="button" aria-label="Remove ${esc(t.merchant)} from the budget">Remove</button>`;
        const fundBtn = `<button class="btn btn-small" data-use-fund="${t.id}" type="button" aria-label="Use Extra Fund for ${esc(t.merchant)}">Use Extra Fund</button>`;
        // Admin actions are hidden from non-admins in the UI; enforcement
        // is server-side in the RPCs (see header note). Reclassify is
        // admin-only and goes through reclassify_transaction.
        const reclassBtn = !isAdmin ? ''
          : `<button class="btn btn-small" data-reclassify="${t.id}" type="button" aria-label="Reclassify ${esc(t.merchant)}">Reclassify</button>`;
        const action = !isAdmin ? fundBtn
          : excluded
          ? `<div class="btn-row"><button class="btn btn-small" data-restore="${t.id}" type="button" aria-label="Restore ${esc(t.merchant)} to the week">Restore</button> ${deleteBtn} ${reclassBtn}</div>`
          : `<div class="btn-row"><button class="btn btn-small" data-exclude="${t.id}" type="button" aria-label="Exclude ${esc(t.merchant)} from the week">Exclude</button> ${deleteBtn} ${reclassBtn} ${fundBtn}</div>`;
        const neg = t.amount_cents < 0 ? ' negative' : '';
        return `<li class="tx-row ${excluded ? 'tx-excluded' : ''}"><div class="tx-head" data-tx-head="${t.id}" role="button" tabindex="0" aria-label="Show detail for ${esc(t.merchant)}"><div class="tx-line1">${iconForMerchant(t.merchant)}<strong class="tx-name" title="${esc(t.merchant)}">${esc(t.merchant)}</strong><span class="tx-amount${neg}">${formatCents(t.amount_cents)}</span></div>
        <div class="tx-line2">${statePill(t, excluded)}
        <span class="pill">${esc(sourceLabel(t.source))}</span>
        <span class="muted small tx-meta">${fmtShort(t.date)} · ••${esc(t.card_suffix)}</span> <span class="muted small">Tap for detail ▾</span></div></div>
        <div class="tx-detail hidden" id="tx-detail-${t.id}">
          <p class="small"><strong>${esc(t.merchant)}</strong> — ${formatCents(t.amount_cents)} (${t.kind === 'refund' ? 'Refund' : 'Purchase'})</p>
          <p class="small muted">Date: ${fmtLong(t.date)} · Counts in week: ${weekRangeOf(t.date)} (Sun–Sat)<br>
          Card: ••${esc(t.card_suffix)} · Source: ${esc(sourceLabel(t.source))} · Status: ${stateWord(t, excluded)}<br>
          ${excluded ? 'This purchase is kept for the record but does not count toward any week.' : t.state === 'reversed' ? 'This purchase was reversed and does not count.' : 'This purchase counts toward its week unless excluded.'}</p>
          <div>${action}</div>
        </div></li>`;
      }).join('')
    : `<li class="tx-empty">${emptyHint}</li>`;
  // Home preview: the 4 newest purchases, tapping one jumps to Purchases.
  const recentEl = $('recentList');
  if (recentEl) {
    const recent = [...all].sort((a, b) => b.date.localeCompare(a.date)).slice(0, 4);
    recentEl.innerHTML = txReadFailed
      ? '<li class="muted small error">Could not load recent purchases.</li>'
      : recent.length
      ? recent.map((t) => {
          const excluded = t.excluded === true || t.state === 'excluded';
          return `<li class="tx-row"><div class="tx-head" data-view="purchases" role="button" tabindex="0" aria-label="See ${esc(t.merchant)} in Purchases"><div class="tx-line1">${iconForMerchant(t.merchant)}<strong class="tx-name" title="${esc(t.merchant)}">${esc(t.merchant)}</strong><span class="tx-amount${t.amount_cents < 0 ? ' negative' : ''}">${formatCents(t.amount_cents)}</span></div>
          <div class="tx-line2">${statePill(t, excluded)}
          <span class="muted small tx-meta">${fmtShort(t.date)} · ••${esc(t.card_suffix)}</span></div></div></li>`;
        }).join('')
      : '<li class="muted small">No purchases yet.</li>';
    // Rows added after load need the same tab-switch handler as the nav.
    recentEl.querySelectorAll('[data-view]').forEach((el) => el.addEventListener('click', () => {
      showView(el.dataset.view, { clearMessages: true });
      if (Date.now() - lastRefreshAt > 30000) refresh();
    }));
  }
  // Tap a row header to expand / collapse its detail panel.
  document.querySelectorAll('[data-tx-head]').forEach((el) => el.addEventListener('click', () => {
    document.getElementById(`tx-detail-${el.dataset.txHead}`)?.classList.toggle('hidden');
  }));
  // Per-stat breakdowns: each number explains itself (the old panel
  // showed the same spending-by-source text for every stat).
  const bd = document.getElementById('weekBreakdown');
  if (bd && currentWeekData) {
    const w = currentWeekData;
    // Spent breakdown sums THIS WEEK ONLY (not all loaded history), and
    // excludes excluded and reversed rows. Server charges are authoritative.
    const counted = all.filter((t) => inThisWeek(t) && !(t.excluded === true || t.state === 'excluded') && t.state !== 'reversed');
    const bySrc = {};
    for (const t of counted) bySrc[t.source] = (bySrc[t.source] ?? 0) + t.amount_cents;
    const refundTotal = counted.filter((t) => t.kind === 'refund').reduce((s, t) => s + t.amount_cents, 0);
    const panels = {
      allowance: txReadFailed ? 'Could not load purchases for the breakdown.'
        : `<strong>Weekly allowance ${formatCents(w.baseAllowanceCents ?? w.baseAvailableCents)}</strong> plus ${formatCents(w.tempCents)} in temporary increases this week. Carried debt ${formatCents(w.carriedDebtCents)} comes off the top, leaving ${formatCents(w.baseAvailableCents)} of base spending room.`,
      spent: txReadFailed ? 'Could not load this week\'s purchases for the breakdown.'
        : `<strong>This week only — charges ${formatCents(w.chargesCents)}:</strong><br>${Object.entries(bySrc).map(([s2, v]) => `${esc(sourceLabel(s2))}: ${formatCents(v)}`).join(' · ') || 'nothing yet'}<br>Refunds in this week\'s list: ${formatCents(refundTotal)} · Excluded purchases kept out of the math: ${all.filter((t) => t.excluded === true || t.state === 'excluded').length}`,
      debt: w.carriedDebtCents > 0
        ? `<strong>${formatCents(w.carriedDebtCents)} carried over</strong> from earlier weeks — it comes off the top of this week's allowance before anything else.`
        : 'No carried-over overspending: this week starts with the full allowance.',
      outgoing: w.outgoingDebtCents > 0
        ? `<strong>${formatCents(w.outgoingDebtCents)} outgoing debt</strong> = ${formatCents(w.carriedDebtCents)} carried in plus ${formatCents(w.outgoingDebtCents - w.carriedDebtCents)} new debt from spending above this week's room. It carries into next week.`
        : 'No outgoing debt: this week\'s spending stayed within its room.',
    };
    bd.dataset.panels = JSON.stringify(panels);
    if (!bd.classList.contains('hidden') && bd.dataset.stat && panels[bd.dataset.stat]) {
      bd.innerHTML = `<p class="small">${panels[bd.dataset.stat]}</p>`;
    }
  }
  document.querySelectorAll('[data-use-fund]').forEach((b) => b.addEventListener('click', async () => {
    const row = all.find((t) => t.id === b.dataset.useFund);
    const amountText = await showSheet({ title: 'Use Extra Fund', message: `Ask the admin to cover "${row?.merchant ?? 'this purchase'}" (${formatCents(row?.amount_cents ?? 0)}) from the Extra Fund?`, inputLabel: 'Amount ($)', inputValue: row ? (row.amount_cents / 100).toFixed(2) : '', confirmLabel: 'Send request', cancelLabel: 'Cancel' });
    if (amountText === null) return;
    const cents = parseDollarsStrict(amountText);
    if (cents === null || cents <= 0) { await showAlert('Invalid amount', 'Enter a positive amount.'); return; }
    const { data: { user } } = await supabase.auth.getUser();
    const { error } = await supabase.from('fund_requests').insert({
      household_id: household.household_id, requested_by: user.id,
      amount_cents: cents, note: '', status: 'pending', transaction_id: b.dataset.useFund,
    });
    if (error) { console.warn('fund request (use-fund) failed:', error.message); await showAlert('Could not send request', 'Could not send this request. Try again.'); return; }
    await audit('Extra Fund request created', `Requested ${formatCents(cents)} for ${row?.merchant ?? 'a purchase'}.`);
    await refresh();
  }));
  document.querySelectorAll('[data-exclude]').forEach((b) => b.addEventListener('click', async () => {
    // Exclusion goes through exclude_transaction (never a direct .update),
    // and a reason is required — it is recorded in the audit log.
    const reason = await showSheet({ title: 'Exclude purchase', message: 'Why exclude this purchase? It stays in the list but stops counting toward the week.', inputLabel: 'Reason (required)', confirmLabel: 'Exclude', cancelLabel: 'Keep it' });
    if (reason === null) return;
    if (!reason.trim()) { await showAlert('Reason required', 'Enter a reason for excluding this purchase.'); return; }
    const row = all.find((t) => t.id === b.dataset.exclude);
    const { error } = await supabase.rpc('exclude_transaction', { txn_id: b.dataset.exclude, reason: reason.trim() });
    if (error) { console.warn('exclude_transaction failed:', error.message); await showAlert('Could not exclude', 'Could not exclude this purchase. Try again.'); return; }
    await audit('Transaction excluded', `${row ? row.merchant : 'Purchase'} ${row ? formatCents(row.amount_cents) : ''} — reason: ${reason.trim()}.`);
    await refresh();
  }));
  document.querySelectorAll('[data-restore]').forEach((b) => b.addEventListener('click', async () => {
    // Restore goes through restore_transaction; the server restores the
    // stored pre-exclude state — the client never invents one.
    const row = all.find((t) => t.id === b.dataset.restore);
    const { error } = await supabase.rpc('restore_transaction', { txn_id: b.dataset.restore });
    if (error) { console.warn('restore_transaction failed:', error.message); await showAlert('Could not restore', 'Could not restore this purchase. Try again.'); return; }
    await audit('Transaction restored', `${row ? row.merchant : 'Purchase'} returned to the week.`);
    await refresh();
  }));
  document.querySelectorAll('[data-reclassify]').forEach((b) => b.addEventListener('click', async () => {
    const newKind = await showSheet({ title: 'Reclassify purchase', message: 'Change how this purchase counts. Pick the new type, then give a reason.', inputLabel: 'New type', inputOptions: [{ value: 'charge', label: 'Charge' }, { value: 'refund', label: 'Refund' }, { value: 'fund_charge', label: 'Fund charge' }], confirmLabel: 'Continue', cancelLabel: 'Cancel' });
    if (newKind === null) return;
    const reason = await showSheet({ title: 'Reclassify purchase', message: 'Why reclassify this purchase?', inputLabel: 'Reason (required)', confirmLabel: 'Reclassify', cancelLabel: 'Cancel' });
    if (reason === null) return;
    if (!reason.trim()) { await showAlert('Reason required', 'Enter a reason for reclassifying this purchase.'); return; }
    const row = all.find((t) => t.id === b.dataset.reclassify);
    const { error } = await supabase.rpc('reclassify_transaction', { txn_id: b.dataset.reclassify, new_kind: newKind, reason: reason.trim() });
    if (error) { console.warn('reclassify_transaction failed:', error.message); await showAlert('Could not reclassify', 'Could not reclassify this purchase. Try again.'); return; }
    await audit('Transaction reclassified', `${row ? row.merchant : 'Purchase'} reclassified to ${newKind} — reason: ${reason.trim()}.`);
    await refresh();
  }));
  document.querySelectorAll('[data-delete-tx]').forEach((b) => b.addEventListener('click', async () => {
    const row = all.find((t) => t.id === b.dataset.deleteTx);
    if (!row || !(await showConfirm('Delete purchase', `"${row.merchant}" ${formatCents(row.amount_cents)} — this removes the hand-entered purchase and cannot be undone.`, 'Delete'))) return;
    const { error } = await supabase.rpc('delete_transaction', { p_transaction_id: b.dataset.deleteTx });
    if (error) { console.warn('delete_transaction failed:', error.message); await showAlert('Could not delete', 'Could not delete this purchase. Try again.'); return; }
    await refresh();
  }));
  document.querySelectorAll('[data-remove-tx]').forEach((b) => b.addEventListener('click', async () => {
    const row = all.find((t) => t.id === b.dataset.removeTx);
    // "Remove" for a bank/email/file record is an exclusion, not a delete:
    // the record stays with its source; it only stops counting here. It
    // goes through exclude_transaction with a required reason.
    const reason = await showSheet({ title: 'Remove from budget', message: `"${row?.merchant ?? 'This purchase'}" ${formatCents(row?.amount_cents ?? 0)} — the record stays with its source; this only stops it counting here. Give a reason to continue.`, inputLabel: 'Reason (required)', confirmLabel: 'Remove', cancelLabel: 'Keep it' });
    if (reason === null) return;
    if (!reason.trim()) { await showAlert('Reason required', 'Enter a reason for removing this purchase.'); return; }
    const { error } = await supabase.rpc('exclude_transaction', { txn_id: b.dataset.removeTx, reason: reason.trim() });
    if (error) { console.warn('exclude_transaction (remove) failed:', error.message); await showAlert('Could not remove', 'Could not remove this purchase. Try again.'); return; }
    await audit('Transaction removed from budget', `${row.merchant} ${formatCents(row.amount_cents)} excluded from week math — reason: ${reason.trim()}.`);
    await refresh();
  }));

  const { data: reqs, error: reqsErr } = await supabase.from('fund_requests')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(50);
  if (reqsErr) console.warn('fund_requests read failed:', reqsErr.message);
  $('fundQueue').innerHTML = reqsErr
    ? '<li class="error">Could not load fund requests. Try again.</li>'
    : (reqs ?? []).length
    ? (reqs ?? []).map((r) => {
        const btns = (household.role === 'admin' && r.status === 'pending')
          ? `<div class="btn-row"><button class="btn btn-small btn-primary" data-approve="${r.id}" type="button" aria-label="Approve this Extra Fund request">Approve</button> <button class="btn btn-small btn-quiet" data-decline="${r.id}" type="button" aria-label="Decline this Extra Fund request">Decline</button></div>`
          : '';
        const statusLabel = r.status === 'split'
          ? (r.remainder_cents != null ? `Split — ${formatCents(r.remainder_cents)} remaining` : 'Split')
          : r.status.toUpperCase();
        return `<li><div data-fund-head="${r.id}" role="button" tabindex="0" aria-label="Show detail for this Extra Fund request">${formatCents(r.amount_cents)} · ${esc(statusLabel)} · ${esc(r.note || '')} <span class="muted small">Tap for detail ▾</span></div>
        <div class="tx-detail hidden" id="fund-detail-${r.id}">
          <p class="small muted">Amount: ${formatCents(r.amount_cents)} · Status: ${esc(statusLabel)}<br>
          Note: ${esc(r.note || '—')}<br>
          Requested: ${fmtDateTime(r.created_at)}<br>
          ${r.status === 'pending' ? 'Waiting on the admin decision.' : r.status === 'approved' ? 'Approved — the fund balance above already reflects it.' : r.status === 'split' ? (r.remainder_cents != null ? `Split approval — ${formatCents(r.remainder_cents)} of this request is still unapproved.` : 'Split approval — part of this request was approved.') : 'Declined by the admin.'}</p>
          <div>${btns}</div>
        </div></li>`;
      }).join('')
    : '<li>No fund requests yet.</li>';
  document.querySelectorAll('[data-fund-head]').forEach((el) => el.addEventListener('click', () => {
    document.getElementById(`fund-detail-${el.dataset.fundHead}`)?.classList.toggle('hidden');
  }));
  document.querySelectorAll('[data-approve]').forEach((b) => b.addEventListener('click', async () => {
    const req = (reqs ?? []).find((r) => r.id === b.dataset.approve);
    const amountText = await showSheet({ title: 'Approve from the fund', message: `Approve how much of this ${formatCents(req?.amount_cents ?? 0)} request? Enter less for a split approval.`, inputLabel: 'Amount ($)', inputValue: req ? (req.amount_cents / 100).toFixed(2) : '', confirmLabel: 'Approve', cancelLabel: 'Cancel' });
    if (amountText === null) return;
    const cents = parseDollarsStrict(amountText);
    if (cents === null || cents <= 0) { await showAlert('Invalid amount', 'Enter a positive amount.'); return; }
    // The server rejects amount > requested; the client rejects it first
    // so no over-approval is ever sent.
    if (req && cents > req.amount_cents) { await showAlert('Too much', `You cannot approve more than the requested ${formatCents(req.amount_cents)}.`); return; }
    let { error } = await supabase.rpc('approve_and_allocate', { request_id: b.dataset.approve, amount_cents: cents, override_reason: null });
    if (error && /insufficient fund/i.test(error.message)) {
      const reason = await showSheet({ title: 'Fund is short', message: `The fund does not cover ${formatCents(cents)}. You can still approve with a typed reason — it will be logged.`, inputLabel: 'Reason for overriding', confirmLabel: 'Approve anyway', cancelLabel: 'Cancel' });
      if (reason === null) return;
      ({ error } = await supabase.rpc('approve_and_allocate', { request_id: b.dataset.approve, amount_cents: cents, override_reason: reason.trim() }));
    }
    if (error) { console.warn('approve_and_allocate failed:', error.message); await showAlert('Could not approve', 'Could not approve this request. Try again.'); } else await refresh();
  }));
  document.querySelectorAll('[data-decline]').forEach((b) => b.addEventListener('click', async () => {
    const { error } = await supabase.rpc('decline_fund_request', { p_request_id: b.dataset.decline });
    if (error) { console.warn('decline_fund_request failed:', error.message); await showAlert('Could not decline', 'Could not decline this request. Try again.'); } else await refresh();
  }));
  // Settings card: admin only.
  $('settingsCard').style.display = household.role === 'admin' ? '' : 'none';
  // Savings: FOUR numbers from savings_ledger kinds (transfer_in,
  // withdrawal, interest, adjustment). Balance is the latest attested
  // actual_balance_cents — never a sum of movements. See the S4 report for
  // the ledger-kind gap: the live write path today only attests a balance
  // (kind 'adjustment', amount 0), so transfer/withdrawal/interest totals
  // stay $0 until a write path for those kinds lands (S1).
  const { data: sav, error: savErr } = await supabase.from('savings_ledger')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(1000);
  if (savErr) console.warn('savings_ledger read failed:', savErr.message);
  const savRows = savErr ? [] : (sav ?? []);
  const latestBalRow = savRows.find((r) => r.actual_balance_cents !== null && r.actual_balance_cents !== undefined);
  const savBalance = latestBalRow ? latestBalRow.actual_balance_cents : null;
  const savIn = savRows.filter((r) => r.kind === 'transfer_in').reduce((t, r) => t + (r.amount_cents || 0), 0);
  const savOutSum = savRows.filter((r) => r.kind === 'withdrawal').reduce((t, r) => t + (r.amount_cents || 0), 0);
  const savOut = Math.abs(savOutSum);
  const savInterestAdj = savRows.filter((r) => r.kind === 'interest' || r.kind === 'adjustment').reduce((t, r) => t + (r.amount_cents || 0), 0);
  const savSumEl = $('savingsSummary');
  if (savSumEl) {
    savSumEl.innerHTML = savErr
      ? '<p class="error">Could not load savings. Try again.</p>'
      : `<div class="sav-grid"><div><div class="kicker">Balance</div><div class="num">${savBalance !== null ? formatCents(savBalance) : 'Not recorded yet'}</div></div><div><div class="kicker">Transferred in</div><div class="num">${formatCents(savIn)}</div></div><div><div class="kicker">Withdrawn</div><div class="num">${formatCents(savOut)}</div></div><div><div class="kicker">Interest / adjustments</div><div class="num">${formatCents(savInterestAdj)}</div></div></div>${savBalance === null ? '<p class="muted small">No savings attestation with a recorded balance was found.</p>' : ''}${!savRows.some((r) => ['transfer_in', 'withdrawal', 'interest'].includes(r.kind)) ? '<p class="muted small">No transfers, withdrawals, or interest have been recorded in the savings ledger yet.</p>' : ''}`;
  }
  $('savingsList').innerHTML = savErr
    ? '<p class="error">Could not load savings records. Try again.</p>'
    : savRows.length
    ? `<ul>${savRows.slice(0, 20).map((r) => `<li>${esc(r.kind)} ${formatCents(r.amount_cents ?? 0)}${r.actual_balance_cents != null ? ` · Recorded balance ${formatCents(r.actual_balance_cents)}` : ''} · ${fmtDateTime(r.created_at)} · ${esc(r.note || '')}</li>`).join('')}</ul>${savRows.length > 20 ? '<p class="muted small">Showing the latest 20 records.</p>' : ''}`
    : '<p class="muted small">No savings records yet.</p>';
  $('savingsFormWrap').style.display = household.role === 'admin' ? '' : 'none';

  // Bank accounts UI — SERVER TRUTH ONLY. Connected state derives from
  // plaid_items rows (status 'active' vs 'disconnected') and their
  // plaid_accounts rows. localStorage is never consulted for connection
  // state. No token, cursor, or secret is ever rendered.
  let bankLastSyncAt = null;
  try {
    const { data: items, error: itemsErr } = await supabase.from('plaid_items_public')
      .select('id, plaid_item_id, institution_name, institution_id, status, last_sync_at')
      .eq('household_id', household.household_id).order('created_at', { ascending: false });
    if (itemsErr) throw itemsErr;
    const itemRows = items ?? [];
    let acctRows = [];
    if (itemRows.length) {
      const { data: accts, error: acctsErr } = await supabase.from('plaid_accounts')
        .select('plaid_item_id, plaid_account_id, name, mask, type, subtype')
        .in('plaid_item_id', itemRows.map((i) => i.plaid_item_id));
      if (acctsErr) { console.warn('plaid_accounts read failed (items still shown):', acctsErr.message); }
      else acctRows = accts ?? [];
    }
    const syncTimes = itemRows.map((i) => i.last_sync_at).filter(Boolean).sort();
    bankLastSyncAt = syncTimes.length ? syncTimes[syncTimes.length - 1] : null;
    const syncLine = $('bankSyncLine');
    if (syncLine) syncLine.textContent = bankLastSyncAt ? `Last synced ${fmtDateTime(bankLastSyncAt)}` : 'Not synced yet.';
    const ls = document.getElementById('lastSync'); if (ls) ls.textContent = bankLastSyncAt ? fmtDateTime(bankLastSyncAt) : 'Not synced yet';
    const cb = $('connectBankBtn');
    if (cb) { cb.disabled = false; cb.classList.remove('btn-primary'); cb.textContent = itemRows.some((i) => i.status === 'active') ? 'Connect another bank account' : 'Connect a bank account'; }
    // Reaudit N1: bank linking is admin-only (plaid-link/plaid-exchange
    // enforce it server-side with a 403); hide the connect button for
    // non-admins so members never see a dead button.
    if (cb) cb.style.display = (household && household.role === 'admin') ? '' : 'none';
    const sb = $('syncBankBtn');
    if (sb) sb.classList.toggle('btn-primary', itemRows.some((i) => i.status === 'active'));
    // Decision 15: manual sync is admin-only once server sync is live
    // (plaid-sync enforces it server-side with a 403); hide the Bank &
    // Funds sync button for non-admins so members never see a dead
    // button. (The Home sync row is gated in showView instead.)
    if (sb) sb.style.display = (household && household.role === 'admin') ? '' : 'none';
    const renderBankList = (elId, rows) => {
      const el = document.getElementById(elId);
      if (!el) return;
      // Build off-DOM and swap atomically: the old rows stay visible
      // until the new ones are ready, so the card never collapses to
      // empty mid-refresh and the cards below never jump up and back
      // (Nov 2, 2026: the blank-then-fill rebuild was the glitch).
      const frag = document.createDocumentFragment();
      if (!rows.length) { const p = document.createElement('p'); p.className = 'muted small'; p.textContent = 'None.'; frag.appendChild(p); el.replaceChildren(frag); return; }
      for (const item of rows) {
        const wrap = document.createElement('div'); wrap.className = 'bank-row';
        const logo = document.createElement('span'); logo.innerHTML = bankLogoHtml(item.institution_name || 'Bank'); wrap.appendChild(logo);
        const info = document.createElement('div'); info.className = 'bank-info';
        const name = document.createElement('strong'); name.textContent = item.institution_name || 'Bank'; info.appendChild(name);
        const accts = acctRows.filter((x) => x.plaid_item_id === item.plaid_item_id);
        if (accts.length) {
          for (const acct of accts) {
            const line = document.createElement('div'); line.className = 'muted small';
            line.textContent = `${acct.name || 'Account'}${acct.mask ? ` ••${acct.mask}` : ''}${acct.type ? ` · ${acct.type}` : ''}${acct.subtype ? ` (${acct.subtype})` : ''}`;
            info.appendChild(line);
          }
        } else {
          const line = document.createElement('div'); line.className = 'muted small'; line.textContent = 'Account details unavailable.'; info.appendChild(line);
        }
        if (item.last_sync_at) { const line = document.createElement('div'); line.className = 'muted small'; line.textContent = `Last synced ${fmtDateTime(item.last_sync_at)}`; info.appendChild(line); }
        wrap.appendChild(info);
        if (item.status === 'active' && household.role === 'admin') {
          const btn = document.createElement('button'); btn.className = 'btn btn-small btn-danger'; btn.type = 'button';
          btn.textContent = 'Disconnect'; btn.setAttribute('aria-label', `Disconnect ${item.institution_name || 'bank'}`);
          btn.addEventListener('click', async () => {
            if (!(await showConfirm('Disconnect bank', `Disconnect ${item.institution_name || 'this bank'}? The app will stop syncing it. Past purchases stay in the list.`, 'Disconnect'))) return;
            // Sibling S3 plaid-disconnect requires BOTH household_id and plaid_item_id
            // (the S4 brief listed only plaid_item_id); sending both satisfies
            // the implemented function and is harmless if a stricter function
            // ignores the extra field.
            const out = await callFn('plaid-disconnect', { household_id: household.household_id, plaid_item_id: item.plaid_item_id });
            if (!out.disconnected) { console.warn('plaid-disconnect failed:', out.error); await showAlert('Could not disconnect', 'Could not disconnect this bank. Try again.'); return; }
            await refresh();
          });
          wrap.appendChild(btn);
        }
        frag.appendChild(wrap);
      }
      el.replaceChildren(frag);
    };
    renderBankList('bankAccountsList', itemRows.filter((i) => i.status === 'active'));
    renderBankList('bankPreviouslyList', itemRows.filter((i) => i.status === 'disconnected'));
  } catch (e) {
    console.warn('bank accounts read failed:', e);
    const syncLine = $('bankSyncLine'); if (syncLine) syncLine.textContent = 'Could not load bank accounts.';
    for (const id of ['bankAccountsList', 'bankPreviouslyList']) {
      const el = document.getElementById(id); if (el) el.innerHTML = '<p class="error">Could not load bank accounts. Try again.</p>';
    }
    const ls = document.getElementById('lastSync'); if (ls) ls.textContent = '—';
  }
  // Email connections UI — SERVER TRUTH ONLY (email_connections_public
  // view; the refresh-token ciphertext never leaves the server).
  // Admin-only card: hidden for members, and no read is attempted for
  // them. This is ADDITIVE: it never touches the owner's existing
  // Apps Script email path, which keeps working unchanged.
  const emailCard = $('section-email');
  if (emailCard) emailCard.style.display = household.role === 'admin' ? '' : 'none';
  if (household.role === 'admin') {
    try {
      const { data: conns, error: connErr } = await supabase.from('email_connections_public')
        .select('id, provider, email_address, status, last_poll_at, last_error')
        .eq('household_id', household.household_id).order('created_at', { ascending: false });
      if (connErr) throw connErr;
      const rows = conns ?? [];
      const line = $('emailStatusLine');
      if (line) line.textContent = rows.length ? '' : 'No email connected yet.';
      const listEl = $('emailConnectionsList');
      if (listEl) {
        // Same atomic swap as the bank lists: build off-DOM so the
        // card never collapses mid-refresh.
        const frag = document.createDocumentFragment();
        if (!rows.length) {
          const p = document.createElement('p'); p.className = 'muted small'; p.textContent = 'None — connect an email above.'; frag.appendChild(p);
        }
        for (const c of rows) {
          const wrap = document.createElement('div'); wrap.className = 'bank-row';
          const info = document.createElement('div'); info.className = 'bank-info';
          const name = document.createElement('strong'); name.textContent = c.email_address || 'Email'; info.appendChild(name);
          const st = document.createElement('div'); st.className = 'muted small';
          st.textContent = c.status === 'error' ? 'Needs reconnect — access was revoked or expired.' : 'Connected (read-only)';
          info.appendChild(st);
          if (c.last_poll_at) { const l = document.createElement('div'); l.className = 'muted small'; l.textContent = `Last checked ${fmtDateTime(c.last_poll_at)}`; info.appendChild(l); }
          if (c.last_error) { const l = document.createElement('div'); l.className = 'muted small'; l.textContent = c.last_error; info.appendChild(l); }
          wrap.appendChild(info);
          const btn = document.createElement('button'); btn.className = 'btn btn-small btn-danger'; btn.type = 'button';
          btn.textContent = 'Disconnect'; btn.setAttribute('aria-label', `Disconnect ${c.email_address || 'email'}`);
          btn.addEventListener('click', async () => {
            if (!(await showConfirm('Disconnect email', `Disconnect ${c.email_address || 'this email'}? The app will stop checking it. Past purchases stay in the list.`, 'Disconnect'))) return;
            const out = await callFn('gmail-disconnect', { household_id: household.household_id, connection_id: c.id });
            if (!out.disconnected) { console.warn('gmail-disconnect failed:', out.error); await showAlert('Could not disconnect', 'Could not disconnect this email. Try again.'); return; }
            await refresh();
          });
          wrap.appendChild(btn);
          frag.appendChild(wrap);
        }
        listEl.replaceChildren(frag);
      }
    } catch (e) {
      console.warn('email connections read failed:', e);
      const line = $('emailStatusLine'); if (line) line.textContent = 'Could not load email connections.';
      const listEl = $('emailConnectionsList'); if (listEl) listEl.innerHTML = '<p class="error">Could not load email connections. Try again.</p>';
    }
  }
  // Extra Fund summary — COMPLETE (spec A5): Available, Pending (not yet
  // released), Released total, Spent from fund, and Owed back (shortfall),
  // from fund_ledger / surplus_releases / week_closes aggregates. A read
  // failure is an error state, not a soft "will appear later" note.
  try {
    const { data: ledger, error: ledgerErr } = await supabase.from('fund_ledger').select('kind, amount_cents').eq('household_id', household.household_id);
    const { data: releases, error: relErr } = await supabase.from('surplus_releases').select('surplus_cents, released_cents, status').eq('household_id', household.household_id);
    const { data: hh, error: hhErr } = await supabase.from('households').select('fund_shortfall_cents').eq('id', household.household_id).maybeSingle();
    if (ledgerErr || relErr || hhErr) throw (ledgerErr || relErr || hhErr);
    const sumKind = (k) => (ledger ?? []).filter((r) => r.kind === k).reduce((t, r) => t + r.amount_cents, 0);
    const available = (ledger ?? []).reduce((t, r) => t + r.amount_cents, 0);
    const spent = Math.abs(sumKind('allocation') + sumKind('override_allocation'));
    const pending = (releases ?? []).filter((r) => r.status === 'pending').reduce((t, r) => t + Math.max(0, (r.surplus_cents || 0) - (r.released_cents || 0)), 0);
    const releasedTotal = (releases ?? []).filter((r) => r.status === 'released').reduce((t, r) => t + (r.released_cents || r.surplus_cents || 0), 0);
    const heldRows = (releases ?? []).filter((r) => r.status === 'held');
    const heldTotal = heldRows.reduce((t, r) => t + (r.surplus_cents || 0), 0);
    const shortfall = hh?.fund_shortfall_cents ?? 0;
    const fs = $('fundSummary');
    if (fs) fs.innerHTML = `<p class="fund-balance">Available <strong>${formatCents(available)}</strong></p>
      <p class="muted small">Pending (not yet released): ${formatCents(pending)}</p>
      <p class="muted small">Released total: ${formatCents(releasedTotal)}</p>
      <p class="muted small">Spent from fund: ${formatCents(spent)}</p>
      <p class="muted small">Owed back (shortfall): ${formatCents(shortfall)}</p>${heldRows.length ? `<p class="muted small">Held for review: ${formatCents(heldTotal)} across ${heldRows.length} week(s).</p>` : ''}`;
  } catch (e) {
    console.warn('fund summary read failed:', e);
    const fs = $('fundSummary');
    if (fs) fs.innerHTML = '<p class="error">Could not load fund balances. Try again.</p>';
  }
  // Refund restorations + held refunds (admin only, READ-ONLY lists).
  // Members never see this section (showView gates it) and no read
  // is attempted for them, mirroring the email card. Pending held
  // rows get a Release button calling the existing
  // resolve_held_refund RPC with action 'release' (owner decision 2:
  // release goes to spendable surplus, shortfall first).
  const restCard = $('section-restoration');
  if (restCard) restCard.style.display = household.role === 'admin' ? '' : 'none';
  if (household.role === 'admin') {
    try {
      const { data: restRows, error: restErr } = await supabase.from('restoration_entries')
        .select('week_start, restored_surplus_cents, debt_reduction_cents, fund_credit_cents, created_at')
        .eq('household_id', household.household_id).order('created_at', { ascending: false }).limit(100);
      const { data: heldRows2, error: heldErr } = await supabase.from('held_refunds')
        .select('id, held_cents, status, resolution_note, created_at')
        .eq('household_id', household.household_id).order('created_at', { ascending: false }).limit(100);
      if (restErr || heldErr) throw (restErr || heldErr);
      const rl = $('restorationList');
      if (rl) {
        const frag = document.createDocumentFragment();
        if (!(restRows ?? []).length) { const p = document.createElement('p'); p.className = 'muted small'; p.textContent = 'No restorations yet.'; frag.appendChild(p); }
        for (const r of restRows ?? []) {
          const p = document.createElement('p'); p.className = 'muted small';
          p.textContent = `Week of ${fmtLong(r.week_start)} · Restored ${formatCents(r.restored_surplus_cents ?? 0)} · Debt cut ${formatCents(r.debt_reduction_cents ?? 0)}${(r.fund_credit_cents ?? 0) ? ` · Fund +${formatCents(r.fund_credit_cents)}` : ''}`;
          frag.appendChild(p);
        }
        rl.replaceChildren(frag);
      }
      const hl = $('heldList');
      if (hl) {
        const frag = document.createDocumentFragment();
        if (!(heldRows2 ?? []).length) { const p = document.createElement('p'); p.className = 'muted small'; p.textContent = 'Nothing held for review.'; frag.appendChild(p); }
        for (const h of heldRows2 ?? []) {
          const wrap = document.createElement('div'); wrap.className = 'bank-row';
          const info = document.createElement('div'); info.className = 'bank-info';
          const amt = document.createElement('strong'); amt.textContent = formatCents(h.held_cents); info.appendChild(amt);
          const st = document.createElement('div'); st.className = 'muted small';
          st.textContent = h.status === 'pending' ? 'Held for review' : `Resolved${h.resolution_note ? ` — ${h.resolution_note}` : ''}`;
          info.appendChild(st);
          wrap.appendChild(info);
          if (h.status === 'pending') {
            const btn = document.createElement('button'); btn.className = 'btn btn-small btn-primary'; btn.type = 'button';
            btn.textContent = 'Release';
            btn.setAttribute('aria-label', `Release held refund ${formatCents(h.held_cents)} to spendable surplus`);
            btn.addEventListener('click', async () => {
              if (!(await showConfirm('Release held refund', `Release ${formatCents(h.held_cents)} to spendable surplus? Any amount owed back is covered first.`, 'Release'))) return;
              const { error } = await supabase.rpc('resolve_held_refund', { p_held_id: h.id, p_action: 'release', p_note: '' });
              if (error) { console.warn('resolve_held_refund failed:', error.message); await showAlert('Could not release', 'Could not release this held refund. Try again.'); } else await refresh();
            });
            wrap.appendChild(btn);
          }
          frag.appendChild(wrap);
        }
        hl.replaceChildren(frag);
      }
    } catch (e) {
      console.warn('restoration/held read failed:', e);
      const rl = $('restorationList'); if (rl) rl.innerHTML = '<p class="error">Could not load restorations. Try again.</p>';
      const hl = $('heldList'); if (hl) hl.innerHTML = '<p class="error">Could not load held refunds. Try again.</p>';
    }
  }
  // Week history display (History tab) — READ-ONLY, from week_closes +
  // surplus_releases. The client never recomputes a week.
  try {
    const { data: closes, error: closesErr } = await supabase.from('week_closes')
      .select('week_start, surplus_cents, outgoing_debt_cents').eq('household_id', household.household_id)
      .order('week_start', { ascending: false }).limit(100);
    const { data: rels, error: relsErr } = await supabase.from('surplus_releases')
      .select('week_start, surplus_cents, released_cents, status').eq('household_id', household.household_id);
    if (closesErr || relsErr) throw (closesErr || relsErr);
    const relByWeek = new Map((rels ?? []).map((r) => [r.week_start, r]));
    const wh = $('weekHistoryList');
    if (wh) wh.innerHTML = (closes ?? []).length
      ? (closes ?? []).map((c) => {
          const rel = relByWeek.get(c.week_start);
          const relText = !rel ? 'No release record' : rel.status === 'released' ? `Released ${formatCents(rel.released_cents ?? rel.surplus_cents ?? 0)}` : rel.status === 'pending' ? `Pending release ${formatCents(rel.surplus_cents ?? 0)}` : `Held ${formatCents(rel.surplus_cents ?? 0)}`;
          return `<li>Week of ${fmtLong(c.week_start)} · Surplus ${formatCents(c.surplus_cents ?? 0)} · Debt carried ${formatCents(c.outgoing_debt_cents ?? 0)} · ${relText} · ${rel ? esc(rel.status) : 'no release'}</li>`;
        }).join('')
      : '<li class="muted small">No closed weeks yet.</li>';
  } catch (e) {
    console.warn('week history read failed:', e);
    const wh = $('weekHistoryList'); if (wh) wh.innerHTML = '<li class="error">Could not load week history. Try again.</li>';
  }

  showView(currentView);
  const { data: auditRows, error: auditErr } = await supabase.from('audit_log')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(50);
  if (auditErr) console.warn('audit_log read failed:', auditErr.message);
  $('auditList').innerHTML = auditErr
    ? '<li class="error">Could not load history. Try again.</li>'
    : (auditRows ?? []).length
    ? (auditRows ?? []).map((a) => `<li><strong>${esc(formatAuditAction(a.action))}</strong> <span class="muted">(${esc(formatAuditActor(a.actor_name))} · ${fmtDateTime(a.created_at)})</span><br>${esc(formatAuditDetail(a.detail))}</li>`).join('') + ((auditRows ?? []).length >= 50 ? '<li class="muted small">Showing the latest 50 entries.</li>' : '')
    : '<li>No audit entries yet.</li>';
  } finally {
    if (rb) { rb.disabled = false; rb.textContent = 'Refresh'; }
  }
}

async function boot() {
  const { data: { session: s } } = await supabase.auth.getSession();
  session = s;
  if (!session) { await show('auth'); return; }
  household = await loadMembership();
  if (!household) { await show('household'); return; }
  await show('app');
  // Gmail OAuth return: the callback redirects back here with
  // ?gmail=connected or ?gmail=failed. The param only picks the
  // message (server truth on refresh decides what the card shows);
  // it is cleared so a later refresh does not re-toast.
  try {
    const g = new URLSearchParams(window.location.search).get('gmail');
    if (g === 'connected' || g === 'failed') {
      showToast(g === 'connected'
        ? 'Email connected — the app will check it for Amex alerts.'
        : 'Email connection didn\'t go through — try again from Bank & Funds.', g === 'failed');
      const u = new URL(window.location.href); u.searchParams.delete('gmail');
      window.history.replaceState(null, '', u.pathname + u.search + u.hash);
    }
  } catch (e) { /* ignore malformed URLs */ }
  await refresh();
}

$('forgotPasswordBtn')?.addEventListener('click', async () => {
  let email = ($('authEmail')?.value ?? '').trim();
  if (!email) {
    const typed = await showSheet({ title: 'Forgot password?', message: 'Enter the email for your account. A reset link will be sent to it.', inputLabel: 'Email', inputType: 'email', confirmLabel: 'Send reset link', cancelLabel: 'Cancel' });
    if (typed === null) return;
    email = typed.trim();
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { $('authMsg').textContent = 'Enter a valid email address.'; return; }
  const base = window.location.href.replace(/live\.html.*$/, '');
  const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${base}reset.html` });
  if (error) console.warn('password reset request failed:', error.message);
  // Generic wording either way: do not reveal whether an account exists.
  $('authMsg').textContent = 'If an account exists for that email, a password-reset link was sent to it.';
});
$('signInBtn').addEventListener('click', async () => {
  const { error } = await supabase.auth.signInWithPassword({
    email: $('authEmail').value.trim(), password: $('authPassword').value,
  });
  if (error) console.warn('sign-in failed:', error.message);
  $('authMsg').textContent = error ? 'Could not sign in. Check your email and password and try again.' : 'Signed in.';
  if (!error) await // ---- Live CSV import (Purchases tab) ----
// Port of the demo parser. NOTHING is inserted on file pick: the file is
// parsed, previewed with duplicate-skip counts, and inserted ONLY after
// the user taps Confirm. Inserts are source='csv', state='provisional'
// (member inserts are constrained to manual/csv + provisional by S1 SQL).
$('csvFile')?.addEventListener('change', async (e) => {
  const file = e.target.files[0];
  const preview = $('csvPreview'); const confirmBtn = $('csvConfirmBtn'); const msg = $('csvMsg');
  pendingCsvRows = [];
  if (confirmBtn) confirmBtn.disabled = true;
  if (msg) msg.textContent = '';
  // Loud failure (Nov 2 import bug): the old handler died silently when
  // the picker handed over no file or an unreadable file, leaving the
  // user with a file name, no preview, and a disabled button. Every
  // failure path now says so on screen.
  if (!file) { if (preview) preview.innerHTML = ''; if (msg) msg.textContent = 'No file reached the app from the picker. Try saving the file to Files first, then picking it from Files.'; return; }
  try {
  const text = await file.text();
  const parsed = parseCsvLive(text);
  // Existing rows for client-side preview dedupe (normalized key). The
  // server unique (household_id, dedupe_hash) constraint is the backstop
  // for any row this preview misses (e.g. beyond the 1000-row fetch).
  const { data: existing } = await supabase.from('transactions')
    .select('merchant, amount_cents, date, card_suffix').eq('household_id', household.household_id).limit(1000);
  const existingKeys = new Set((existing ?? []).map((t) => csvRowKey({ merchant: t.merchant, date: t.date, amountCents: t.amount_cents, suffix: t.card_suffix })));
  const seen = new Set(); let dupes = 0;
  const previewRows = parsed.rows.map((r) => {
    const key = csvRowKey(r);
    const isDupe = existingKeys.has(key) || seen.has(key);
    if (isDupe) dupes++; else seen.add(key);
    return { ...r, isDupe };
  });
  pendingCsvRows = previewRows.filter((r) => !r.isDupe);
  const newCount = pendingCsvRows.length;
  if (preview) preview.innerHTML = `<p class="muted small">${newCount} new, ${dupes} duplicate(s) skipped, ${parsed.errors.length} unparseable row(s).</p>`
    + (parsed.errors.length ? `<p class="muted small">${parsed.errors.map((er) => esc(er)).join('<br>')}</p>` : '')
    + `<ul class="plain">${previewRows.map((r) => `<li class="csv-row${r.isDupe ? ' csv-dupe' : ''}">${esc(r.date)} \u00b7 ${esc(r.merchant)} \u00b7 ${formatCents(r.amountCents)} \u00b7 \u2022\u2022${esc(r.suffix)} \u2014 ${r.isDupe ? 'Duplicate, will be skipped' : 'New'}</li>`).join('')}</ul>`;
  if (msg) msg.textContent = '';
  if (confirmBtn) confirmBtn.disabled = newCount === 0;
  } catch (err) {
    console.warn('csv import failed:', err);
    pendingCsvRows = [];
    if (preview) preview.innerHTML = '';
    if (confirmBtn) confirmBtn.disabled = true;
    if (msg) msg.textContent = `Could not read this file (${err?.message || err}). Try saving the file to Files first, then picking it from Files.`;
  }
});
$('csvConfirmBtn')?.addEventListener('click', async () => {
  const msg = $('csvMsg');
  if (!pendingCsvRows.length) { showToast('Nothing new to import.'); return; }
  const rows = pendingCsvRows;
  const inserts = [];
  for (const r of rows) {
    const hash = await sha(`${r.date}|${normalizeMerchant(r.merchant)}|${r.amountCents}|${r.suffix}`);
    inserts.push({ household_id: household.household_id, date: r.date, merchant: r.merchant,
      amount_cents: r.amountCents, card_suffix: r.suffix, source: 'csv', state: 'provisional',
      kind: r.amountCents < 0 ? 'refund' : 'charge', dedupe_hash: hash });
  }
  const { data, error } = await supabase.from('transactions').insert(inserts).select('id');
  if (error) { console.warn('csv insert failed:', error.message); showToast('Could not import. Nothing was claimed as imported — try again.', true); return; }
  const added = data?.length ?? rows.length;
  await audit('CSV import', `${added} added, ${rows.length - added} not inserted.`);
  pendingCsvRows = [];
  const fileEl = $('csvFile'); if (fileEl) fileEl.value = '';
  const confirmBtn = $('csvConfirmBtn'); if (confirmBtn) confirmBtn.disabled = true;
  const preview = $('csvPreview'); if (preview) preview.innerHTML = '';
  if (msg) msg.textContent = '';
  showToast(`Imported ${added} purchase(s) as provisional.`);
  await refresh();
});

boot();
});
$('signUpBtn').addEventListener('click', async () => {
  const { error } = await supabase.auth.signUp({
    email: $('authEmail').value.trim(), password: $('authPassword').value,
  });
  if (error) console.warn('sign-up failed:', error.message);
  $('authMsg').textContent = error ? 'Could not create the account. Try again.' : 'Account created. If email confirmation is on in Auth settings, confirm the email first, then sign in.';
  if (!error) await boot();
});
$('signOutBtn').addEventListener('click', async () => {
  await supabase.auth.signOut(); household = null; await show('auth');
});
// No header Refresh button anymore: tapping a tab refreshes.

$('createHouseholdBtn').addEventListener('click', async () => {
  // Household creation is server-side only — but NOT via the Edge
  // Function anymore. The bootstrap-household function failed on Nov 1
  // (HTTP 500, valid JWT, service-role insert failed) because it reads
  // the deprecated legacy SUPABASE_SERVICE_ROLE_KEY, which this project
  // no longer provisions with a working value. The fix is the
  // create_household() SECURITY DEFINER RPC: it runs as the database
  // owner, acts only for auth.uid(), refuses if the caller already has
  // a household, and needs no secret key at all. The client must still
  // never grant itself admin directly — this RPC is the only path.
  const { data, error } = await supabase.rpc('create_household');
  if (error) console.warn('create_household failed:', error.message);
  $('householdMsg').textContent = data
    ? 'Household created. Share the invite code from your profile menu so the second account can join as member.'
    : 'Could not create household. Try again.';
  // FIX (Nov 1, evening — reproduced by the beta test): do NOT re-read
  // the membership here. boot()'s loadMembership() returned null right
  // after creation (the RPC had just committed), so the app stayed on
  // the household screen until the user hit Refresh. The RPC already
  // proves the caller is the new household's admin, so set it directly
  // and go straight to the dashboard.
  if (data) { household = { household_id: data, role: 'admin' }; await show('app'); await refresh(); }
});
$('joinHouseholdBtn').addEventListener('click', async () => {
  const { data: { user } } = await supabase.auth.getUser();
  const code = $('joinId').value.trim();
  if (!user) { $('householdMsg').textContent = 'Sign in first.'; return; }
  if (!code) { $('householdMsg').textContent = 'Enter the invite code from the household owner.'; return; }
  // Join takes an invite CODE, not a UUID. join_household_by_code returns
  // the household UUID, which the client stores for its own queries but
  // never displays or shares.
  const { data, error } = await supabase.rpc('join_household_by_code', { code });
  if (error) console.warn('join_household_by_code failed:', error.message);
  // A NULL return means the code was invalid (the function logs the
  // failed attempt and returns NULL instead of raising, so the log
  // survives — see supabase/n13-invite-rate-limit.sql). Treat it
  // exactly like the old exception: same generic message, no join.
  $('householdMsg').textContent = (error || !data) ? 'Join failed. Check the invite code and try again.' : 'Joined. Loading shared budget…';
  if (!error && data) { household = { household_id: data, role: 'member' }; await show('app'); await refresh(); }
});

$('manualForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const amount = parseDollarsStrict(f.amount.value);
  if (amount === null || amount <= 0) { await showAlert('Invalid amount', 'Enter a positive amount.'); return; }
  const suffix = f.suffix.value.trim();
  if (!/^\d{4}$/.test(suffix)) { await showAlert('Card suffix', 'Card suffix must be exactly 4 digits. Never enter a full card number.'); return; }
  const merchant = f.merchant.value.trim().toUpperCase();
  // Smarter entry: warn on an apparent duplicate instead of silently
  // creating a second copy of the same purchase.
  const { data: dupes } = await supabase.from('transactions')
    .select('merchant, amount_cents, date').eq('household_id', household.household_id)
    .eq('merchant', merchant).eq('amount_cents', amount).eq('date', f.date.value).limit(1);
  if ((dupes ?? []).length && !(await showConfirm('Possible duplicate', `A purchase already exists for ${merchant} ${formatCents(amount)} on ${fmtLong(f.date.value)}. Add it again anyway?`, 'Add anyway'))) return;
  const hash = await sha(`${f.date.value}|${merchant}|${amount}|${suffix}`);
  const { error } = await supabase.from('transactions').insert({
    household_id: household.household_id, date: f.date.value, merchant,
    amount_cents: amount, card_suffix: suffix, source: 'manual',
    state: 'provisional', kind: 'charge', dedupe_hash: hash,
  });
  if (error) { console.warn('manual insert failed:', error.message); await showAlert('Could not save', 'Could not save this purchase. Try again.'); return; }
  await audit('Purchase added by hand', `${merchant} ${formatCents(amount)} on ${fmtLong(f.date.value)} (••${suffix}).`);
  f.reset(); await refresh();
});

async function callFn(name, body) {
  const { data: { session: s } } = await supabase.auth.getSession();
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${s?.access_token ?? ''}`, apikey: SUPABASE_ANON_KEY },
    body: JSON.stringify(body),
  });
  return res.json();
}

$('connectBankBtn')?.addEventListener('click', async () => {
  showToast('Getting a secure bank connection…');
  const out = await callFn('plaid-link', { household_id: household.household_id });
  if (!out.link_token) {
    showToast(`Could not start the bank connection: ${out.error ?? 'unknown error'}. If it says "not configured," the bank connection is not set up on the server yet.`, true);
    return;
  }
  const handler = window.Plaid.create({
    token: out.link_token,
    onSuccess: async (publicToken, metadata) => {
      showToast('Bank approved — finishing the secure connection…');
      const ex = await callFn('plaid-exchange', {
        household_id: household.household_id,
        public_token: publicToken,
        institution_name: metadata?.institution?.name ?? null,
      });
      showToast(ex.connected
        ? 'Connected. Tap "Sync bank transactions now" to pull transactions.'
        : `Connection could not be finished: ${ex.error ?? 'unknown error'}`, !ex.connected);
      if (ex.connected) { await refresh(); } // connection state now comes from plaid_items on refresh, not localStorage
    },
    onExit: (err) => {
      if (err) showToast(`Bank connection closed: ${err.error_message ?? err.error_code ?? 'cancelled'}`, true);
    },
  });
  handler.open();
});

async function runBankSync() {
  showToast('Syncing bank transactions…');
  const out = await callFn('plaid-sync', { household_id: household.household_id });
  const text = out.error
    ? `Sync failed: ${out.error}`
    : `Sync done: ${out.added ?? 0} added, ${out.updated ?? 0} updated, ${out.skipped ?? 0} skipped across ${out.items ?? 0} connected account(s).`;
  showToast(text, !!out.error);
  // No localStorage sync/connection state: refresh() re-reads last_sync_at
  // from plaid_items, which is the server truth.
  return out;
}

$('syncBankBtn')?.addEventListener('click', async () => {
  await runBankSync();
  await refresh();
});
$('homeSyncBtn')?.addEventListener('click', async () => {
  await runBankSync();
  await refresh();
});

$('registerWebhookBtn')?.addEventListener('click', async () => {
  showToast('Enabling automatic sync…');
  const out = await callFn('plaid-webhook-register', { household_id: household.household_id });
  if (out.error) { showToast(`Could not enable automatic sync: ${out.error}`, true); return; }
  const failed = (out.results ?? []).filter((r) => !r.ok);
  showToast(failed.length
    ? `Automatic sync partly enabled — ${failed.length} connection(s) failed. Try again.`
    : 'Automatic sync enabled. New purchases will be pulled in on your next refresh.', failed.length > 0);
  if (!failed.length) { await refresh(); }
});

// Email (OAuth) connection — admin only. gmail-oauth-start derives the
// household from the caller's own admin membership, so no household id
// is sent (and none would be trusted). A successful start redirects
// the whole page to Google; after consent the callback page links back
// to the app. This never touches the Apps Script email path.
$('connectEmailBtn')?.addEventListener('click', async () => {
  $('emailMsg').textContent = 'Getting a secure email connection…';
  const out = await callFn('gmail-oauth-start', {});
  if (!out.auth_url) {
    $('emailMsg').textContent = `Could not start the email connection: ${out.error ?? 'unknown error'}. If it says "not configured," the email connection is not set up on the server yet.`;
    return;
  }
  window.location.href = out.auth_url;
});

$('pollEmailBtn')?.addEventListener('click', async () => {
  $('emailMsg').textContent = 'Checking email…';
  const out = await callFn('gmail-poll', { household_id: household.household_id });
  $('emailMsg').textContent = out.error
    ? `Email check failed: ${out.error}`
    : `Email checked: ${out.stored ?? 0} added, ${out.duplicates ?? 0} already known, ${out.quarantined ?? 0} quarantined, ${out.unparseable ?? 0} could not be read.`;
  await refresh();
});

// Automatic sync: if a verified webhook event is waiting for this
// household's items, run a sync at the start of refresh (once —
// plaid-sync marks events processed, so this does not loop).
let autoSyncDoneThisLoad = false;
async function autoSyncIfWebhookPending() {
  if (autoSyncDoneThisLoad || !household) return;
  autoSyncDoneThisLoad = true;
  const { data: items } = await supabase.from('plaid_items_public')
    .select('plaid_item_id').eq('household_id', household.household_id);
  if (!items?.length) return;
  const { data: pending } = await supabase.from('webhook_events')
    .select('id').in('plaid_item_id', items.map((i) => i.plaid_item_id))
    .eq('processed', false).limit(1);
  if (pending?.length) await runBankSync();
}

// Section views: the nav tabs are real screens, not jump links —
// only one section group is shown at a time, so the app is never
// one long scrollable page. Choice persists across visits.
const VIEWS = {
  week: ['section-week', 'section-stats', 'section-hint', 'section-recent'],
  purchases: ['section-manual', 'section-csv', 'section-transactions'],
  money: ['section-bank', 'section-email', 'settingsCard', 'section-savings', 'section-fund', 'section-fund-use', 'section-fund-ask', 'section-restoration'],
  activity: ['section-activity', 'section-week-history'],
};
const ALL_VIEW_SECTIONS = Object.values(VIEWS).flat();
let currentView = localStorage.getItem('hb-view') || 'week';
if (!VIEWS[currentView]) currentView = 'week';
// Bottom toast: in-app result messages float above the tab bar instead
// of popping open inside cards and shoving everything below them down.
// Function declarations hoist, so handlers below can call these freely.
let toastTimer = null;
function showToast(text, isError) {
  const t = document.getElementById('toast');
  if (!t) return;
  t.textContent = text ?? '';
  t.classList.toggle('error', !!isError);
  t.classList.remove('hidden');
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(hideToast, 4000);
}
function hideToast() {
  if (toastTimer) { clearTimeout(toastTimer); toastTimer = null; }
  document.getElementById('toast')?.classList.add('hidden');
}
document.getElementById('toast')?.addEventListener('click', hideToast);
function showView(name, opts = {}) {
  if (!VIEWS[name]) name = 'week';
  currentView = name;
  localStorage.setItem('hb-view', name);
  // Success/error messages do NOT persist across tabs: a user-initiated
  // tab switch clears every in-app result message (refresh() calls
  // showView without opts, so messages set during a refresh survive).
  if (opts.clearMessages) {
    // Clear TRANSIENT messages only (by id) — never content lists such as
    // savingsList, savingsSummary, or the CSV preview, which refresh()
    // only repopulates on a timed refresh.
    for (const id of ['bankMsg', 'homeSyncMsg', 'settingsMsg', 'tempMsg', 'savingsMsg', 'fundAllocateMsg', 'csvMsg']) {
      const el = document.getElementById(id); if (el) el.textContent = '';
    }
    hideToast();
    document.getElementById('weekError')?.classList.add('hidden');
  }
  for (const id of ALL_VIEW_SECTIONS) {
    const el = document.getElementById(id);
    if (!el) continue;
    if (!VIEWS[name].includes(id)) { el.style.display = 'none'; continue; }
    if (id === 'settingsCard' || id === 'section-fund-use' || id === 'section-restoration') { el.style.display = (household && household.role === 'admin') ? 'block' : 'none'; continue; }
    el.style.display = id === 'section-stats' ? 'grid' : 'block';
  }
  document.querySelectorAll('[data-view]').forEach((b) => {
    b.classList.toggle('active', b.dataset.view === name);
    b.setAttribute('aria-pressed', b.dataset.view === name ? 'true' : 'false');
  });
  // Home sync button lives inside the hero card now (not its own
  // section above it): gate the button itself, admin-only.
  const homeSync = document.getElementById('homeSyncBtn');
  if (homeSync) homeSync.style.display = (household && household.role === 'admin') ? '' : 'none';
  window.scrollTo(0, 0);
}
document.querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', () => {
  showView(b.dataset.view, { clearMessages: true });
  // Cached content shows instantly; data refreshes in the background,
  // at most once every 30s, so tab taps never stare at empty cards.
  if (Date.now() - lastRefreshAt > 30000) refresh();
}));
document.getElementById('profileBtn')?.addEventListener('click', (e) => {
  e.stopPropagation();
  const menu = document.getElementById('profileMenu');
  menu.classList.toggle('hidden');
  document.getElementById('profileBtn').setAttribute('aria-expanded', menu.classList.contains('hidden') ? 'false' : 'true');
});
document.addEventListener('click', (e) => {
  const menu = document.getElementById('profileMenu');
  if (menu && !menu.classList.contains('hidden') && !menu.contains(e.target) && e.target.id !== 'profileBtn' && !document.getElementById('profileBtn')?.contains(e.target)) menu.classList.add('hidden');
});
document.getElementById('menuShareIdBtn')?.addEventListener('click', async () => {
  document.getElementById('profileMenu')?.classList.add('hidden');
  // Share shows/copies the invite CODE, never the household UUID.
  if (!household) { await showAlert('Not signed in', 'Sign in first, then share the invite code.'); return; }
  let code = null;
  try {
    const { data } = await supabase.from('households').select('invite_code').eq('id', household.household_id).maybeSingle();
    code = data?.invite_code ?? null;
  } catch (e) { console.warn('invite_code read failed:', e); }
  if (!code) { await showSheet({ title: 'Invite code', message: 'No invite code is set up for this household yet. Ask the household owner to set one up before the second account joins.', confirmLabel: 'Done' }); return; }
  let copied = false;
  try { await navigator.clipboard.writeText(code); copied = true; } catch (e) { /* clipboard may be unavailable; the code is still shown */ }
  await showSheet({ title: 'Invite code', message: `Share this code with the second account so they can join as a member:\n${code}${copied ? '\n(Copied to clipboard.)' : ''}`, confirmLabel: 'Done' });
});
document.getElementById('menuDeleteBtn')?.addEventListener('click', async () => {
  document.getElementById('profileMenu')?.classList.add('hidden');
  if (!household) { await showAlert('Not signed in', 'Sign in first.'); return; }
  // TWO-STEP confirmation: "Delete account" then "Yes, delete everything".
  if (!(await showConfirm('Delete account', 'Delete your account and remove yourself from this household? If you are the last member, the household is deleted too. This cannot be undone.', 'Delete account'))) return;
  if (!(await showConfirm('Delete everything?', 'This permanently deletes your account and, if you are the last member, the whole household. Are you sure?', 'Yes, delete everything'))) return;
  const out = await callFn('delete-account', {});
  if (out.error || !out.deleted) { console.warn('delete-account failed:', out.error); await showAlert('Could not delete account', 'Could not delete your account. Try again.'); return; }
  await supabase.auth.signOut(); household = null; await show('auth');
  $('authMsg').textContent = 'Your account was deleted.';
});
document.getElementById('menuPasswordBtn')?.addEventListener('click', async () => {
  document.getElementById('profileMenu')?.classList.add('hidden');
  if (!household) { await showAlert('Not signed in', 'Sign in first.'); return; }
  const pw = await showSheet({ title: 'Change password', message: 'Enter a new password for this account.', inputLabel: 'New password', inputType: 'password', confirmLabel: 'Change password', cancelLabel: 'Cancel' });
  if (!pw) return;
  if (pw.length < 8) { await showAlert('Password too short', 'Enter a password of at least 8 characters.'); return; }
  const { error } = await supabase.auth.updateUser({ password: pw });
  if (error) console.warn('password change failed:', error.message);
  await showAlert(error ? 'Could not change password' : 'Password changed', error ? 'Could not change your password. Try again.' : 'Your password is updated.');
});
// Stat cards: tap a number to see that number's own breakdown.
document.querySelectorAll('[data-stat]').forEach((el) => el.addEventListener('click', () => {
  const bd = document.getElementById('weekBreakdown');
  if (!bd) return;
  const stat = el.dataset.stat;
  if (!bd.classList.contains('hidden') && bd.dataset.stat === stat) { bd.classList.add('hidden'); return; }
  bd.dataset.stat = stat;
  try {
    const panels = JSON.parse(bd.dataset.panels || '{}');
    if (panels[stat]) bd.innerHTML = `<p class="small">${panels[stat]}</p>`;
  } catch (e) { /* panel text refreshes on next data load */ }
  bd.classList.remove('hidden');
}));
// HTML form of an amount with smaller cents, for the hero and stat
// numbers only (formatCents from the engine stays the plain-text form
// used in search, messages, and audit text).
function formatCentsHtml(cents) {
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(cents);
  return `${sign}$${Math.floor(abs / 100)}<span class="cents">.${String(abs % 100).padStart(2, '0')}</span>`;
}

// Friendly dates for display only — the raw YYYY-MM-DD stays in the
// data (and in search), so nothing about filtering changes.
// Audit display formatter: stored rows contain internal text
// (UUIDs, "create_household RPC", ISO dates, raw cent counts).
// The log on screen translates those into plain sentences.
function formatAuditDetail(detail) {
  let d = String(detail ?? '');
  d = d.replace(/Request [0-9a-f-]{36} approved/gi, 'Request approved');
  d = d.replace(/Request [0-9a-f-]{36} declined/gi, 'Request declined');
  d = d.replace(/^Created via create_household RPC.*$/i, 'Household created.');
  d = d.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '');
  d = d.replace(/\b(\d{4})-(\d{2})-(\d{2})\b/g, (_, y, m, dd) => fmtLong(`${y}-${m}-${dd}`));
  d = d.replace(/\b(\d+) cents\b/g, (_, n) => formatCents(Number(n)));
  d = d.replace(/as provisional/g, 'as pending');
  d = d.replace(/\s{2,}/g, ' ').replace(/\.{2,}/g, '.').trim();
  return d;
}
function formatAuditAction(action) {
  return action === 'Manual provisional purchase added' ? 'Purchase added by hand' : action; // old rows
}
function formatAuditActor(name) {
  if (name === 'admin') return 'Admin';
  if (name === 'member') return 'Member';
  if (typeof name === 'string' && name.includes('@')) return name.split('@')[0];
  return name;
}

function fmtDateTime(iso) {
  const d = new Date(iso);
  return isNaN(d) ? String(iso) : d.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function fmtLong(dateStr) {
  const d = new Date(`${dateStr}T12:00:00`);
  return isNaN(d) ? dateStr : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}
function fmtShort(dateStr) {
  const d = new Date(`${dateStr}T12:00:00`);
  return isNaN(d) ? dateStr : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

// In-app sheet (replaces the browser's grey prompt/confirm/alert
// boxes, which looked cheap and blocked the whole page).
function showSheet({ title, message, inputLabel, inputValue = '', inputType = 'text', inputOptions = null, confirmLabel = 'OK', cancelLabel = null }) {
  // SECURITY: EVERY interpolated value is escaped with esc() — title,
  // message, input label/value, option labels/values, and button labels.
  // No raw caller value reaches innerHTML through any showSheet path.
  // Messages are plain text (never HTML); the sheet CSS renders newlines.
  return new Promise((resolve) => {
    document.getElementById('sheetOverlay')?.remove();
    const safeType = ['text', 'password', 'number', 'email'].includes(inputType) ? inputType : 'text';
    const overlay = document.createElement('div');
    overlay.id = 'sheetOverlay';
    const inputHtml = !inputLabel ? '' : inputOptions
      ? `<label>${esc(inputLabel)}<select id="sheetInput">${inputOptions.map((o) => `<option value="${esc(o.value)}">${esc(o.label)}</option>`).join('')}</select></label>`
      : `<label>${esc(inputLabel)}<input id="sheetInput" type="${safeType}" value="${esc(inputValue)}"></label>`;
    overlay.innerHTML = `<div class="sheet" role="dialog" aria-modal="true" aria-label="${esc(title)}">
      <h3>${esc(title)}</h3><p>${esc(message)}</p>
      ${inputHtml}
      <div class="sheet-btns">
        ${cancelLabel ? `<button class="btn" type="button" id="sheetCancel">${esc(cancelLabel)}</button>` : ''}
        <button class="btn btn-primary" type="button" id="sheetConfirm">${esc(confirmLabel)}</button>
      </div></div>`;
    document.body.appendChild(overlay);
    let settled = false;
    const done = (v) => { if (settled) return; settled = true; overlay.remove(); resolve(v); };
    overlay.addEventListener('click', (e) => { if (e.target === overlay) done(inputLabel ? null : false); });
    overlay.querySelector('#sheetCancel')?.addEventListener('click', () => done(inputLabel ? null : false));
    overlay.querySelector('#sheetConfirm').addEventListener('click', () => {
      done(inputLabel ? document.getElementById('sheetInput').value : true);
    });
    if (inputLabel) document.getElementById('sheetInput').focus();
  });
}
const showAlert = (title, message) => showSheet({ title, message, confirmLabel: 'OK' });
const showConfirm = (title, message, confirmLabel = 'OK') => showSheet({ title, message, confirmLabel, cancelLabel: 'Cancel' });

function weekRangeOf(dateStr) {
  const d = new Date(`${dateStr}T12:00:00`);
  const sun = new Date(d); sun.setDate(d.getDate() - d.getDay());
  const sat = new Date(sun); sat.setDate(sat.getDate() + 6);
  const f = (x) => `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
  return `${fmtShort(f(sun))} – ${fmtLong(f(sat))}`;
}

document.getElementById('txMonth')?.addEventListener('change', (e) => {
  txMonth = e.target.value;
  localStorage.setItem('hb-tx-month', txMonth);
  refresh();
});
document.getElementById('txCard')?.addEventListener('change', (e) => {
  txCard = e.target.value;
  localStorage.setItem('hb-tx-card', txCard);
  refresh();
});
document.getElementById('txSort')?.addEventListener('change', (e) => {
  txSort = e.target.value;
  localStorage.setItem('hb-tx-sort', txSort);
  refresh();
});

// Transaction filters: chips combine with the search box; refresh()
// re-renders the list with both applied.
document.querySelectorAll('[data-tx-filter]').forEach((c) => c.addEventListener('click', async () => {
  txFilter = c.dataset.txFilter;
  // "All" means all: it also clears the This-week chip, which used to
  // stay on silently and make All show only this week.
  if (txFilter === 'all') txWeekOnly = false;
  await refresh();
}));
$('txWeekToggle')?.addEventListener('click', async () => {
  txWeekOnly = !txWeekOnly;
  await refresh();
});
$('txLoadMore')?.addEventListener('click', async () => {
  txLimit += 100;
  await refresh();
});
$('txFiltersToggle')?.addEventListener('click', (e) => {
  const f = document.getElementById('txFilters');
  if (!f) return;
  f.classList.toggle('hidden');
  const open = !f.classList.contains('hidden');
  e.target.textContent = open ? 'Filters ▴' : 'Filters ▾';
  e.target.setAttribute('aria-expanded', open ? 'true' : 'false');
});
let txSearchTimer = null;
$('txSearch')?.addEventListener('input', () => {
  clearTimeout(txSearchTimer);
  txSearchTimer = setTimeout(() => { refresh(); }, 250);
});

$('addTempBtn')?.addEventListener('click', async () => {
  const cents = parseDollarsStrict($('tempIncreaseInput').value);
  if (cents === null || cents <= 0) { showToast('Enter a positive amount.', true); return; }
  const ny = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/New_York' }));
  const sunday = new Date(ny); sunday.setDate(ny.getDate() - ny.getDay());
  const weekStart = `${sunday.getFullYear()}-${String(sunday.getMonth() + 1).padStart(2, '0')}-${String(sunday.getDate()).padStart(2, '0')}`;
  const { error } = await supabase.rpc('add_temp_increase', { p_household_id: household.household_id, p_week_start: weekStart, p_amount_cents: cents, p_note: '' });
  if (error) console.warn('add_temp_increase failed:', error.message);
  showToast(error ? 'Could not add the temporary increase. Try again.' : 'Temporary increase added — dashboard will reflect it on refresh.', !!error);
  if (!error) await refresh();
});

$('attestSavingsBtn')?.addEventListener('click', async () => {
  const cents = parseDollarsStrict($('savingsBalanceInput').value);
  if (cents === null || cents < 0) { showToast('Enter a valid balance (empty is not 0).', true); return; }
  const { error } = await supabase.rpc('attest_savings', { p_household_id: household.household_id, p_actual_balance_cents: cents, p_note: $('savingsNoteInput').value.trim() });
  if (error) console.warn('attest_savings failed:', error.message);
  showToast(error ? 'Could not record the balance. Try again.' : 'Balance recorded.', !!error);
  if (!error) await refresh();
});

$('recordSavingsMovementBtn')?.addEventListener('click', async () => {
  const cents = parseDollarsStrict($('savingsAmountInput').value);
  if (cents === null || cents <= 0) { showToast('Enter a valid amount (must be more than 0).', true); return; }
  const { error } = await supabase.rpc('record_savings_entry', { p_household_id: household.household_id, p_kind: $('savingsKindInput').value, p_amount_cents: cents, p_note: $('savingsMovementNoteInput').value.trim() });
  if (error) console.warn('record_savings_entry failed:', error.message);
  showToast(error ? 'Could not record the movement. Try again.' : 'Movement recorded.', !!error);
  if (!error) await refresh();
});

$('saveAllowanceBtn')?.addEventListener('click', async () => {
  const cents = parseDollarsStrict($('baseAllowanceInput').value);
  if (cents === null || cents < 0) { showToast('Enter a valid allowance (empty is not 0).', true); return; }
  // Allowance changes require a confirmation sheet showing old -> new.
  let oldCents = currentWeekData?.baseAllowanceCents ?? null;
  if (oldCents === null) {
    try {
      const { data: hhRow } = await supabase.from('households').select('base_allowance_cents').eq('id', household.household_id).maybeSingle();
      oldCents = hhRow?.base_allowance_cents ?? null;
    } catch (e) { /* old value stays unknown; the sheet says so */ }
  }
  const confirmed = await showSheet({ title: 'Change allowance', message: oldCents === null
    ? `Set the weekly allowance to ${formatCents(cents)}? (The current allowance could not be read, so no old value is shown.)`
    : `Change the weekly allowance from ${formatCents(oldCents)} to ${formatCents(cents)}?`, confirmLabel: 'Change allowance', cancelLabel: 'Keep current' });
  if (!confirmed) return;
  const { error } = await supabase.rpc('set_base_allowance', { p_household_id: household.household_id, p_cents: cents });
  if (error) console.warn('set_base_allowance failed:', error.message);
  showToast(error ? 'Could not save allowance. Try again.' : 'Allowance saved.', !!error);
  if (!error) await refresh();
});

$('fundAllocateForm')?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const cents = parseDollarsStrict(f.amount.value);
  if (cents === null || cents <= 0) { showToast('Enter a positive amount.', true); return; }
  let { error } = await supabase.rpc('allocate_fund', { p_household_id: household.household_id, p_amount_cents: cents, p_note: f.note.value.trim(), p_override_reason: null });
  if (error && /insufficient fund/i.test(error.message)) {
    const reason = await showSheet({ title: 'Fund is short', message: `The fund does not cover ${formatCents(cents)}. Record it anyway with a typed reason — it will be logged.`, inputLabel: 'Reason for overriding', confirmLabel: 'Record anyway', cancelLabel: 'Cancel' });
    if (reason === null) return;
    ({ error } = await supabase.rpc('allocate_fund', { p_household_id: household.household_id, p_amount_cents: cents, p_note: f.note.value.trim(), p_override_reason: reason.trim() }));
  }
  if (error) console.warn('allocate_fund failed:', error.message);
  showToast(error ? 'Could not record fund spending. Try again.' : 'Fund spending recorded.', !!error);
  if (!error) { f.reset(); await refresh(); }
});
$('fundRequestForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const cents = parseDollarsStrict(f.amount.value);
  if (cents === null || cents <= 0) { await showAlert('Invalid amount', 'Enter a positive amount.'); return; }
  const { data: { user } } = await supabase.auth.getUser();
  const { error } = await supabase.from('fund_requests').insert({
    household_id: household.household_id, requested_by: user.id,
    amount_cents: cents, note: f.note.value.trim(), status: 'pending',
  });
  if (error) { console.warn('fund request insert failed:', error.message); await showAlert('Could not save request', 'Could not save this request. Try again.'); return; }
  await audit('Extra Fund request created', `Requested ${formatCents(cents)}.`);
  f.reset(); await refresh();
});

boot();
