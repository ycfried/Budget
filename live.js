// Household Budget — LIVE front end (Supabase).
//   * Real Supabase Auth (email + password, two accounts only).
//   * First account creates the household as admin; second joins by ID.
//   * Transactions, fund requests, and audit log read/write the shared DB.
//   * Week numbers come from the server (compute-week Edge Function),
//     never from client-side math alone.
//   * Admin-only settings and savings records run through RPCs with
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
import { formatCents, weekStartOf, nyTodayString, applyShortfallToRelease, charityCommittedCents } from './engine.mjs';
import { activeFilterLabels, createSyncGuard, historyPeriodLabel, filterRowsByDate, weeklyReconciliation, groupDayActivity, householdActivityText, simplifyActivityDetail, titleCaseMerchant, relativeDayLabel, resolveRestoredView, resolveRestoredSubView, scrollStorageKey, VIEW_STORAGE_KEY, PREV_VIEW_STORAGE_KEY, isWeekCloseCheckDue, classifyCsvKind, activityDotClass, activityTitle } from './filterState.mjs';
import { describeConnection } from './duplicateConnection.mjs';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// Native-style-live: display-only merchant/date wording (stored
// values unchanged). Today/Yesterday use the NY date, matching the
// Sunday–Saturday week.
const displayMerchant = (name) => titleCaseMerchant(name);
const displayDay = (dateStr) => relativeDayLabel(dateStr, nyTodayString()) ?? fmtShort(dateStr);
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
// ONE shared merchant-icon helper, used by BOTH Transactions rows and Home
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
// Plain-language account type for the Connected accounts list, DISPLAY
// ONLY (overnight audit C2, owner approved Nov 4, 2026): Plaid's raw
// type/subtype strings ("credit (credit card)", "depository
// (checking)") are never rendered verbatim. Unknown types render
// nothing at all, never a raw Plaid word. Nothing here is stored and
// nothing touches classification, matching, or week math.
function plainAccountType(type, subtype) {
  const t = String(type || '').trim().toLowerCase();
  const s = String(subtype || '').trim().toLowerCase();
  if (t === 'credit') return 'Credit card';
  if (t === 'depository') {
    if (s === 'checking') return 'Checking';
    if (s === 'savings') return 'Savings';
    return 'Bank account';
  }
  if (t === 'loan') return 'Loan';
  if (t === 'investment') return 'Investment';
  return '';
}
// Transaction state pill: 'reversed' renders as Reversed, never Posted.
function statePill(t, excluded) {
  if (excluded) return '<span class="pill warn">Excluded</span>';
  if (t.state === 'reversed') return '<span class="pill rev">Reversed</span>';
  if (t.state === 'provisional') return '<span class="pill warn">Pending</span>';
  return '<span class="pill ok">Posted</span>';
}
function stateWord(t, excluded) {
  // Same Title Case labels as statePill above — one status mapping
  // for both the pill and the detail "Status:" line (UX audit 11).
  // The counting sentence in the detail panel still explains
  // separately whether the row counts toward its week.
  if (excluded) return 'Excluded';
  if (t.state === 'reversed') return 'Reversed';
  if (t.state === 'provisional') return 'Pending';
  return 'Posted';
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
let txFilter = 'all'; // all | pending | posted | refunds | charity | excluded
let txSort = localStorage.getItem('hb-tx-sort') || 'date-desc'; // date-desc | date-asc | amount-asc | amount-desc
let txMonth = localStorage.getItem('hb-tx-month') || 'all'; // 'all' or 'YYYY-MM'
let txCard = localStorage.getItem('hb-tx-card') || 'all'; // 'all' or card suffix
let txWeekOnly = false; // spec B5: transactions filter by week (client-side, current Sun–Sat week)
let txFromDate = ''; // delta B2: optional date-range lower bound (YYYY-MM-DD, sheet-committed)
let txToDate = ''; // delta B2: optional date-range upper bound (YYYY-MM-DD, sheet-committed)
let historyFilter = { from: '', to: '' }; // delta B1: History date filter (YYYY-MM-DD, both lists)
let lastWeekHistoryShown = { shown: 0, total: null }; // delta B1: week-history counts for the combined count line
let auditLimit = 50; // delta B1: activity entries shown; Load more raises it
let fundFormOpen = null; // delta C3: which Funds form is open (null = More card)
let moreFundActivityOpen = false; // Task 7: More sections, toggled by their › rows
let moreReviewOpen = false;
let moreSavingsOpen = false;
let reviewNeedsCount = 0; // Task 7: pending held refunds + pending duplicates (things needing review)
function updateMoreReviewLabel() {
  const lbl = document.getElementById('moreReviewLabel');
  if (lbl) lbl.textContent = reviewNeedsCount > 0 ? `Review (${reviewNeedsCount})` : 'Review';
}
const syncGuard = createSyncGuard(); // delta B3: one bank sync at a time
let txLimit = 100; // transactions load in pages of 100; Load more raises it
let weekCloseRan = false; // week-close runs itself once per session (admin only)
// Delta3 week-close fingerprint: the week start of the last successful
// week-close check, in localStorage per household, so a reload in the
// same week skips the call (the server would be a silent no-op). A
// missing or unreadable value means "unknown" — the caller falls back
// to calling, because the server no-op is silent when nothing is due.
const weekCloseCheckKey = () => `ob-weekclose-${household?.household_id ?? 'none'}`;
const readWeekCloseCheck = () => { try { return localStorage.getItem(weekCloseCheckKey()); } catch (e) { return null; } };
const writeWeekCloseCheck = (weekStart) => { try { if (weekStart) localStorage.setItem(weekCloseCheckKey(), weekStart); } catch (e) { /* private mode: next load just calls again */ } };
let lastRefreshAt = 0; // tab taps refresh in the background, throttled
let txLoaded = false; // transactions have loaded at least once (gates the empty-week hint)
let refreshInFlight = 0; // Task 6: overlap counter only; it drives no UI text (the footer is last-sync only).
let currentWeekData = null; // last compute-week result, for per-stat breakdowns
let lastSpentBreakdown = null; // { datedTotal, lateTotal } cents, for the Weekly sheet
let currentFundData = null; // last fund aggregates, for the Extra Fund card sheet
let currentCharityData = null; // last charity aggregates, for the Charity card sheet
// R3 nicknames: keyed by stable Plaid account id, never by suffix alone.
// nicknameBySuffix is a display hint only, built from the same rows, and
// drops any suffix claimed by two accounts.
let nicknameByAccount = new Map();
let nicknameBySuffix = new Map();
let nicknamesLoaded = false;
// Generic display labels for transaction sources. Database values are
// unchanged (e.g. 'plaid'); only what the user sees is bank-agnostic.
const sourceLabel = (s) => ({ plaid: 'Bank', manual: 'By hand', csv: 'File', amex_alert: 'Email alert' }[s] ?? String(s));

async function show(view) {
  // Delta3 loading screen: view-loading is the HTML default (visible
  // on first paint), so a signed-in reload never flashes the sign-in
  // form — boot() replaces the loader directly with auth, household,
  // or app once the session is known.
  $('view-loading')?.classList.toggle('hidden', view !== 'loading');
  $('view-auth').classList.toggle('hidden', view !== 'auth');
  $('view-household').classList.toggle('hidden', view !== 'household');
  $('view-app').classList.toggle('hidden', view !== 'app');
  // The header sits outside view-app, so the profile button would
  // otherwise stay tappable on the signed-out screen (Nov 3 fix
  // round): hide it — and close the menu — until signed in.
  document.getElementById('profileBtn')?.classList.toggle('hidden', view !== 'app');
  if (view !== 'app') document.getElementById('profileMenu')?.classList.add('hidden');
  // Audit-merge fix (review B H5, trivial): the "Last bank sync"
  // footer is an in-app status line — it showed "Last bank sync —"
  // (empty) on the sign-in screen too. Hide it off the app screens,
  // like the profile button above.
  document.querySelector('footer.foot')?.classList.toggle('hidden', view !== 'app');
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
  // Task 4: the page must not jump to the top after an action
  // (dedupe Same/Separate, transaction Actions, fund actions,
  // saves, disconnects — every one of them ends in refresh()).
  // Root cause was showView(currentView) inside refresh(), which
  // always scrolled to (0, 0). The fix is central, so every
  // refresh() call site is covered: capture the position up front,
  // keep the internal re-renders from scrolling, and restore in
  // the finally below after the last re-render.
  const savedScrollY = window.scrollY || 0;
  // Task 6: the footer NEVER shows an app-refresh "Updating…"
  // state. It used to sit on the same line as "Last bank sync",
  // so the owner read it as a bank sync in progress (bank sync
  // last ran at 5:09 PM, separately), and a hung refresh left it
  // stuck. The footer is now the last-sync line only; a bank sync
  // in progress already shows on its own buttons (Sync button
  // "Syncing…", Home sync icon spins, toast) with a finally that
  // restores them on success AND failure. refreshInFlight is kept
  // only as an overlap counter; it drives no UI text, so there is
  // nothing that can stick, hang, or need a timeout clear.
  refreshInFlight++;
  try {
  // Webhook-triggered auto-sync happens first, so the numbers and
  // list below already include any transactions Plaid just announced.
  await Promise.race([autoSyncIfWebhookPending(), new Promise((r) => setTimeout(r, 8000))]);

  const { data: { session: s } } = await supabase.auth.getSession();
  const pe = document.getElementById('profileEmail'); if (pe && s?.user?.email) pe.textContent = s.user.email;
  // Household naming (owner, Nov 4, 2026): show the stored household
  // name in the Settings Account card. Fail silent — the static
  // "Household: Household" line already covers existing households
  // and any read failure, so nothing here can break a refresh.
  try {
    const { data: hrow } = await supabase.from('households').select('name').eq('id', household.household_id).maybeSingle();
    const hn = document.getElementById('householdNameLine');
    if (hn && typeof hrow?.name === 'string' && hrow.name.trim()) hn.textContent = `Household: ${hrow.name.trim()}`;
  } catch (e) { console.warn('household name read failed:', e); }
  // Audit-merge fix (review B S2): when no name is set, the header
  // below falls back to the email, so showing this line too would
  // print the email twice. Hide it exactly when it duplicates the
  // header; with a name set, both lines show (name + email).
  // Applied after the header is set, further down in refresh().
  const hideDupEmail = () => {
    const pn2 = document.getElementById('profileName');
    const pe2 = document.getElementById('profileEmail');
    if (pn2 && pe2) pe2.classList.toggle('hidden', pn2.textContent !== '—' && pn2.textContent === pe2.textContent);
  };
  // UX-review-fix, profile name (owner screenshot Nov 3, 7:53 PM):
  // the header is the user's name from auth metadata (full_name,
  // then name), falling back to the email only when no name is set.
  // No name is ever hardcoded: until the user saves one, the header
  // is their email and the menu row reads "Add your name". Saving a
  // name uses updateUser metadata only — no SQL, no new column. The
  // backend already supports this: household_members.display_name
  // exists, and the audit trigger prefers it, then user_metadata
  // full_name / name, then email — so a metadata name already flows
  // into audit actor names as the trigger's second preference.
  const displayName = s?.user?.user_metadata?.full_name || s?.user?.user_metadata?.name || '';
  // Profile-menu rework (owner, Nov 3, ~11:20 PM): the menu header
  // shows the FIRST NAME only (first whitespace token; a string with
  // no space, e.g. the email fallback, is shown unchanged) with the
  // role pill inline beside it, and the user's email below in small
  // muted text. hideDupEmail() keeps the email from printing twice
  // when the header itself fell back to the email. The role-wording
  // paragraph is gone entirely, and there is no Edit-profile row:
  // profile editing lives in the Settings Profile card.
  const headerName = (displayName || s?.user?.email || '—').split(/\s+/)[0] || '—';
  const pn = document.getElementById('profileName'); if (pn) pn.textContent = headerName;
  hideDupEmail();
  const pni = document.getElementById('profileNameInput'); if (pni && document.activeElement !== pni) pni.value = displayName;
  const pei = document.getElementById('profileEmailInput'); if (pei && document.activeElement !== pei && s?.user?.email) pei.value = s.user.email;
  const pr = document.getElementById('profileRole'); if (pr) pr.textContent = household.role ? household.role.charAt(0).toUpperCase() + household.role.slice(1) : '—';
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
  const weekErrEl = document.getElementById('weekError');
  const clearWeekNumbers = () => {
    $('weekLabel').textContent = 'Week numbers unavailable';
    $('weeklyAvailable').textContent = '—';
    $('weeklyAvailable').setAttribute('aria-label', 'Show Weekly Budget breakdown');
    $('homeFundPrimary').textContent = '—';
    const bar = document.getElementById('weekProgressBar');
    if (bar) { bar.style.width = '0%'; bar.parentElement?.classList.remove('over'); }
    const pt = document.getElementById('weekProgressText');
    if (pt) pt.textContent = '';
    for (const id of ['heroSpentLine', 'heroUsedPct', 'heroAllowance', 'heroPurchaseCount']) { const el = document.getElementById(id); if (el) el.textContent = '—'; }
    currentWeekData = null;
  };
  // Delta3: week figures load through this helper so a week-close that
  // actually closed a week can reload them once, right after closing.
  const loadWeekNumbers = async () => { try {
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
      // Outgoing debt follows engine.mjs computeWeek exactly (the
      // server returns incoming debt D, not the engine's carriedDebt
      // component): outgoing = debt the allowance did not cover +
      // new debt from spending above base room + temp room. The
      // previous client formula added the full incoming debt, which
      // overstated outgoing whenever the allowance absorbed part of
      // it (engine fixture: D 42500, B 37500, C 0 -> outgoing 5000,
      // not 42500). Display derivation only — server numbers are
      // untouched, and week-close stores the engine value.
      const recon = weeklyReconciliation({
        allowance: baseAllowanceCents ?? (baseAvailable + carried),
        carried, temp: tempC, spent: charges,
      });
      const outgoingDebt = recon.outgoing;
      if (weekStart) $('weekLabel').textContent = `${fmtLong(weekStart)} (Sun–Sat)`;
      $('weeklyAvailable').innerHTML = formatCentsHtml(avail);
      $('weeklyAvailable').removeAttribute('aria-busy');
      $('weeklyAvailable').classList.toggle('negative', avail < 0);
      // UX-review-fix, numbers-only stat cards (owner screenshot
      // Nov 3, 7:53 PM): the face is Title + signed number only.
      // A negative figure in red does the talking — no "Over budget
      // by $X" sentence and no "Spent $X of $Y room" line on the
      // face. Those words live in the tap sheet (rows below) and in
      // the card's aria-label, so assistive technology still gets
      // them. Spent, room, carried debt, and outgoing debt all live
      // in the sheet, not on the face.
      // Excluded-decisions (owner, Nov 3, 9:42 PM): the smaller Weekly
      // Budget stat card is gone — the hero number IS the breakdown
      // target. The face stays numbers-only; the words live in the
      // hero number's aria-label, exactly as the card used to carry.
      $('weeklyAvailable').setAttribute('aria-label', avail < 0
        ? `Weekly Budget, over budget by ${formatCents(Math.abs(avail))}, show breakdown`
        : `Weekly Budget, ${formatCents(avail)} left this week, show breakdown`);
      currentWeekData = { weekStart, baseAvailableCents: baseAvailable, tempCents: tempC,
        carriedDebtCents: carried, chargesCents: charges, availableCents: avail,
        outgoingDebtCents: outgoingDebt, weekLocked: !!r.week_locked,
        pendingRefundExcludedCents: r.pending_refund_excluded_cents ?? 0,
        baseAllowanceCents, baseRoomCents: recon.baseRoom,
        unabsorbedDebtCents: recon.unabsorbed, newDebtCents: recon.newDebt };
      // Hero progress, debt-aware: spending room is base room + temp room
      // (carried debt already came off the top). Overspend is NOT silently
      // capped: the bar fills and an explicit "Over by" amount is shown.
      const capacity = baseAvailable + tempC;
      const pct = capacity > 0 ? (charges / capacity) * 100 : (charges > 0 ? 100 : 0);
      const bar = document.getElementById('weekProgressBar');
      if (bar) { bar.style.width = `${Math.min(100, Math.round(pct))}%`; bar.parentElement?.classList.toggle('over', charges > capacity); }
      // UX-review-fix: the hero keeps its bar and its signed big
      // figure only. The progress sentence ("Spent $X of $Y room",
      // carried debt, over-by) duplicated the Weekly sheet rows, so
      // it is no longer written on the face; locked and pending-
      // refund status are sheet rows instead (see weeklyRows).
      const pt = document.getElementById('weekProgressText');
      if (pt) pt.textContent = '';
      const heroSpent = document.getElementById('heroSpentLine'); if (heroSpent) heroSpent.textContent = `${formatCents(charges)} spent`;
      const heroUsed = document.getElementById('heroUsedPct'); if (heroUsed) heroUsed.textContent = capacity > 0 ? `${Math.round(pct)}% used` : (charges > 0 ? 'Over budget' : '0% used');
      const heroAllow = document.getElementById('heroAllowance'); if (heroAllow) heroAllow.textContent = formatCents(baseAllowanceCents ?? (baseAvailable + carried));
      lastRefreshAt = Date.now();
      const allowInput = document.getElementById('baseAllowanceInput');
      if (allowInput && document.activeElement !== allowInput && baseAllowanceCents !== null) allowInput.value = (baseAllowanceCents / 100).toFixed(2);
    }
  } catch (e) {
    console.warn('compute-week failed:', e);
    if (weekErrEl) { weekErrEl.textContent = "Couldn't update this week's numbers — check your connection and try again."; weekErrEl.classList.remove('hidden'); }
    clearWeekNumbers();
  } };
  await loadWeekNumbers();

  // Delta3: weeks still close themselves (admin only, once per
  // session) — but only when a close can be due. The due-check reads
  // the week start compute-week just loaded and the stored
  // fingerprint: same week as the last successful check means no
  // close can be due, so the call is skipped. When due-ness cannot
  // be determined (compute-week failed, no week start) the call still
  // runs — the server no-op is silent, so that fallback costs one
  // quiet call and never a spurious activity row. The close path
  // itself is NOT removed: admin loads are what close weeks (there
  // is no scheduled week-close). When the call actually closed a
  // week, figures reload once so the close is reflected immediately.
  if (household.role === 'admin' && !weekCloseRan) {
    const currentWeekStart = currentWeekData?.weekStart ?? null;
    if (!isWeekCloseCheckDue({ lastCheckedWeekStart: readWeekCloseCheck(), currentWeekStart })) {
      weekCloseRan = true;
    } else {
      try {
        const out = await callFn('week-close', { household_id: household.household_id });
        if (!out.error) {
          weekCloseRan = true;
          writeWeekCloseCheck(currentWeekStart);
          if (out.weeks_closed > 0) await loadWeekNumbers();
        }
      } catch (e) { /* retry next refresh */ }
    }
  }

  const { data: txns, error: txErr } = await supabase.from('transactions')
    .select('*').eq('household_id', household.household_id)
    .order('date', { ascending: false }).limit(txLimit);
  // Read failures are an ERROR STATE, never a silent empty list or stale
  // numbers: txReadFailed overrides the lists below.
  const txReadFailed = !!txErr;
  if (txErr) console.warn('transactions read failed:', txErr.message);
  const all = txReadFailed ? [] : (txns ?? []);
  txLoaded = true;
  const q = ($('txSearch')?.value ?? '').trim().toLowerCase();
  // Send-live-bundle, Trash: the main Transactions list never shows
  // excluded rows — they live only in the Trash bin below the list.
  // The old 'excluded' status filter is gone (its select option was
  // removed); a legacy 'excluded' value falls back to 'all', which
  // also hides excluded rows.
  if (txFilter === 'excluded') txFilter = 'all';
  const isExcludedRow = (t) => t.excluded === true || t.state === 'excluded';
  const byFilter = (t) => txFilter === 'pending' ? t.state === 'provisional'
    : txFilter === 'posted' ? t.state === 'verified'
    : txFilter === 'refunds' ? t.kind === 'refund'
    : txFilter === 'charity' ? t.kind === 'charity'
    : !isExcludedRow(t);
  // This-week filter: current Sunday–Saturday in America/New_York.
  const todayNy = nyTodayString();
  const todayD = new Date(`${todayNy}T12:00:00`);
  const sundayD = new Date(todayD); sundayD.setDate(todayD.getDate() - todayD.getDay());
  const saturdayD = new Date(sundayD); saturdayD.setDate(saturdayD.getDate() + 6);
  const fmtD = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const weekStartStr = fmtD(sundayD); const weekEndStr = fmtD(saturdayD);
  const inThisWeek = (t) => t.date >= weekStartStr && t.date <= weekEndStr;
  // R8 amount bounds: inclusive, either end alone, applied together
  // with the month/card/week/search filters. Bounds compare to the
  // SIGNED amount (a $10 refund is −$10) — the signed-refund
  // meaning the handoff doc left open, stated here rather than
  // silently reinterpreted as absolute value. A blank or unparseable
  // end means no limit on that side; min above max is a validation
  // state, not an empty result.
  const minCents = parseDollarsStrict($('txMinAmount')?.value ?? '');
  const maxCents = parseDollarsStrict($('txMaxAmount')?.value ?? '');
  const amountRangeInvalid = minCents !== null && maxCents !== null && minCents > maxCents;
  const shown = amountRangeInvalid ? [] : all.filter((t) => byFilter(t) && (txMonth === 'all' || String(t.date).startsWith(txMonth)) && (txCard === 'all' || String(t.card_suffix) === txCard) && (!txWeekOnly || inThisWeek(t)) && (!txFromDate || String(t.date) >= txFromDate) && (!txToDate || String(t.date) <= txToDate) && (minCents === null || t.amount_cents >= minCents) && (maxCents === null || t.amount_cents <= maxCents) && (!q
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
  // R9: sort is separate from filtering — a field select plus a
  // direction button showing both arrow AND words, synced from
  // txSort on every refresh. Amount sort stays by size (absolute
  // value), as fixed Nov 1; only its control changed, never the
  // sorter itself.
  const sortFieldEl = $('txSortField');
  if (sortFieldEl) sortFieldEl.value = txSort.startsWith('amount') ? 'amount' : 'date';
  const sortDirBtn = $('txSortDirBtn');
  if (sortDirBtn) {
    // Delta A2: the approved arrow design — arrow AND words together.
    const dirLabel = txSort === 'date-asc' ? '↑ Oldest first'
      : txSort === 'amount-desc' ? '↓ Largest first'
      : txSort === 'amount-asc' ? '↑ Smallest first'
      : '↓ Newest first';
    sortDirBtn.textContent = dirLabel;
    sortDirBtn.setAttribute('aria-label', `Sort direction: ${dirLabel}. Tap to reverse.`);
  }
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
    // R3: a nickname shows in the filter only when it was loaded from
    // the Settings bank list (keyed by Plaid account id) and maps to
    // exactly one suffix; ambiguous suffixes stay suffix-only.
    cardSel.innerHTML = '<option value="all">All cards</option>' + cards.map((c) => {
      const nick = nicknameBySuffix.get(c);
      return `<option value="${esc(c)}"${c === txCard ? ' selected' : ''}>••${esc(c)}${nick ? ` · ${esc(nick)}` : ''}</option>`;
    }).join('');
  }
  const thisWeekTxns = all.filter((t) => inThisWeek(t) && !(t.excluded === true || t.state === 'excluded'));
  const emptyHintEl = document.getElementById('weekEmptyHint');
  // Show the empty-week hint only once a load has actually returned
  // empty — never while the first load is still in flight, and never
  // on a failed load (Nov 3 fix round: it used to flash on every
  // fresh open even in a household with data).
  if (emptyHintEl) emptyHintEl.classList.toggle('hidden', !(txLoaded && !txReadFailed && thisWeekTxns.length === 0));
  const heroCount = document.getElementById('heroPurchaseCount'); if (heroCount && !txReadFailed) heroCount.textContent = String(thisWeekTxns.length);
  const countEl = $('txCount');
  if (countEl) {
    // Charity gifts are not spending: leave them out of the list
    // total except on the Charity filter itself, where the total is
    // the gifts total. (Week math already excludes them everywhere.)
    const shownTotal = shown.filter((t) => !(t.excluded === true || t.state === 'excluded') && (txFilter === 'charity' || t.kind !== 'charity')).reduce((s, t) => s + t.amount_cents, 0);
    const capped = all.length >= txLimit ? ' of loaded transactions — tap Load more for older ones' : ' of loaded transactions';
    countEl.textContent = txReadFailed ? 'Could not load transactions — try again.' : amountRangeInvalid ? 'Minimum amount is above the maximum amount — change one of them to see transactions.' : `Showing ${shown.length}${capped}${txWeekOnly ? ' · this week' : ''} · total of the rows shown ${formatCents(shownTotal)} (${txFilter === 'charity' ? 'excluded rows not counted' : 'charity gifts and excluded rows not counted'}) · search covers loaded rows only`;
  }
  const loadMore = $('txLoadMore');
  if (loadMore) loadMore.classList.toggle('hidden', all.length < txLimit);
  // Delta B2: the sheet controls mirror the state variables (the
  // month/card selects are rebuilt above; status, week, and dates
  // are synced here so Apply/Cancel always show the true state).
  const statusSel = $('txStatusSelect');
  if (statusSel) statusSel.value = txFilter;
  const weekCheck = $('txWeekCheck');
  if (weekCheck) weekCheck.checked = txWeekOnly;
  const fromInput = $('txFromDate');
  if (fromInput && document.activeElement !== fromInput) fromInput.value = txFromDate;
  const toInput = $('txToDate');
  if (toInput && document.activeElement !== toInput) toInput.value = txToDate;
  // Delta B2: applied filters as small individually removable labels
  // above the list. Clearing one label clears only that filter.
  const activeEl = $('txActiveFilters');
  if (activeEl) {
    const monthLabel = txMonth === 'all' ? null : (() => {
      try { return new Date(`${txMonth}-02T12:00:00`).toLocaleString('en-US', { month: 'long', year: 'numeric' }); } catch (e) { return txMonth; }
    })();
    const labels = activeFilterLabels({
      status: txFilter,
      monthLabel,
      cardLabel: txCard === 'all' ? null : `••${txCard}`,
      minLabel: minCents === null ? null : formatCents(minCents),
      maxLabel: maxCents === null ? null : formatCents(maxCents),
      weekOnly: txWeekOnly,
      fromDate: txFromDate,
      toDate: txToDate,
    });
    activeEl.innerHTML = labels.map((l) => `<button class="tx-active-filter" data-clear-filter="${esc(l.key)}" type="button" aria-label="Remove filter ${esc(l.label)}">${esc(l.label)} ×</button>`).join('');
    activeEl.querySelectorAll('[data-clear-filter]').forEach((b) => b.addEventListener('click', () => {
      const key = b.dataset.clearFilter;
      if (key === 'status') txFilter = 'all';
      else if (key === 'month') { txMonth = 'all'; localStorage.setItem('hb-tx-month', 'all'); }
      else if (key === 'card') { txCard = 'all'; localStorage.setItem('hb-tx-card', 'all'); }
      else if (key === 'min') { const mn = $('txMinAmount'); if (mn) mn.value = ''; }
      else if (key === 'max') { const mx = $('txMaxAmount'); if (mx) mx.value = ''; }
      else if (key === 'week') txWeekOnly = false;
      else if (key === 'from') txFromDate = '';
      else if (key === 'to') txToDate = '';
      refresh();
    }));
  }
  // Audit-merge fix (review B T2): a search or an active filter that
  // matches nothing used to show the new-household message ("No
  // transactions here yet — add one…"), which is wrong for a populated
  // ledger. Status-only hints stay specific; any search or other
  // active filter gets the no-match state with a clear action. The
  // new-household message only appears with no search, no filter,
  // and genuinely no loaded transactions (all.length === 0).
  const searchOrFilterActive = q !== '' || txMonth !== 'all' || txCard !== 'all' || txWeekOnly || !!txFromDate || !!txToDate || minCents !== null || maxCents !== null;
  const trashRowCount = all.filter((t) => t.excluded === true || t.state === 'excluded').length;
  const emptyHint = searchOrFilterActive
    ? 'No matching transactions. Try a different search, or clear the search and filters.'
    : trashRowCount > 0 && shown.length === 0
    ? 'No transactions here — deleted bank rows live in the Trash link above the list.'
    : txFilter === 'refunds'
    ? 'No refunds in this list yet.'
    : txFilter === 'charity'
    ? 'No charity gifts in this list yet — record one from Add, or mark a posted donation as a gift.'
    : 'No transactions here yet — add one by hand above, or connect a bank account and sync.';
  const emptyLi = searchOrFilterActive
    ? `<li class="tx-empty">${emptyHint} <button class="btn btn-small" data-clear-search-filters type="button" aria-label="Clear search and filters">Clear search and filters</button></li>`
    : `<li class="tx-empty">${emptyHint}</li>`;
  $('txList').innerHTML = txReadFailed
    ? `<li class="tx-empty error">Could not load transactions. Check your connection and try again — nothing here is a complete list.</li>`
    : shown.length
    ? shown.map((t) => {
        const excluded = t.excluded === true || t.state === 'excluded';
        const isAdmin = household.role === 'admin';
        // Send-live-bundle, detail Actions sheet: the old five-button
        // row (Exclude, Mark as charity, Use Extra Fund, Reclassify,
        // Remove/Delete) is replaced by one Actions line. Tapping it
        // opens openTxActionsSheet (below, after the list render),
        // which lists exactly Charity, Extra Fund, Other, Delete.
        // Charity rows show Delete only; members see Extra Fund only
        // on charges and no Actions line on any other row. Excluded
        // rows never reach this render — they live only in Trash.
        const cardLabel = (t.kind === 'charity' && String(t.card_suffix) === '0000') ? 'Cash / no card' : `••${esc(t.card_suffix)}`;
        const kindLabel = t.kind === 'refund' ? 'Refund' : t.kind === 'charity' ? 'Charity gift' : t.kind === 'transfer' ? 'Transfer' : 'Transaction';
        const qualifiesForFund = t.kind === 'charge';
        const hasActions = isAdmin
          ? true
          : (qualifiesForFund && !excluded);
        const action = !hasActions ? ''
          : `<div class="btn-row"><button class="btn btn-small btn-tertiary" data-tx-actions="${t.id}" type="button" aria-label="Actions for ${esc(t.merchant)}">Actions</button></div>`;
        const neg = t.amount_cents < 0 ? ' negative' : '';
        // UX audit 05: the row's accessible name carries merchant,
        // amount, date, and status, so repeated merchants never share
        // an identical row name; the chevron marks the
        // row as a disclosure (it rotates when the detail opens).
        const rowLabel = `${displayMerchant(t.merchant)} ${formatCents(t.amount_cents)} ${displayDay(t.date)} ${stateWord(t, excluded)} — show detail`;
        return `<li class="tx-row ${excluded ? 'tx-excluded' : ''}"><div class="tx-head" data-tx-head="${t.id}" role="button" tabindex="0" aria-label="${esc(rowLabel)}"><div class="tx-line1">${iconForMerchant(t.merchant)}<strong class="tx-name" title="${esc(displayMerchant(t.merchant))}">${esc(displayMerchant(t.merchant))}</strong><span class="tx-amount${neg}">${formatCents(t.amount_cents)}</span><span class="tx-chevron" aria-hidden="true"></span></div>
        <div class="tx-line2">${statePill(t, excluded)}
        <span class="pill">${esc(sourceLabel(t.source))}</span>
        <span class="muted small tx-meta">${displayDay(t.date)} · ${cardLabel}</span></div></div>
        <div class="tx-detail hidden" id="tx-detail-${t.id}">
          <p class="small"><strong>${esc(displayMerchant(t.merchant))}</strong> — ${formatCents(t.amount_cents)} (${kindLabel})</p>
          <p class="small muted">${t.kind === 'charity' ? 'Outside weekly spending.' : excluded ? 'Kept for the record; does not count toward any week.' : t.state === 'reversed' ? 'Reversed; does not count.' : t.kind === 'payment' ? 'Card payment; does not count toward weekly spending.' : t.kind === 'cashback' ? 'Cash-back credit; does not count toward weekly spending.' : t.kind === 'transfer' ? 'Transfer; does not count toward weekly spending.' : 'Counts toward its week unless excluded.'}</p>
          <div class="tx-detail-rows">
            <div><span>Week</span><span>${esc(weekRangeOf(t.date))} (Sun–Sat)</span></div>
            <div><span>Date</span><span>${fmtLong(t.date)}</span></div>
            <div><span>Status</span><span>${esc(stateWord(t, excluded))}</span></div>
            <div><span>Card</span><span>${cardLabel}</span></div>
            <div><span>Source</span><span>${esc(sourceLabel(t.source))}</span></div>
          </div>
          ${t.source === 'amex_alert' ? `<p class="small muted">${t.state === 'provisional' ? 'From an email alert — pending until the bank confirms it.' : 'From an email alert, confirmed by the bank.'}</p>` : ''}
          <div>${action}</div>
        </div></li>`;
      }).join('')
    : emptyLi;
  // T2 clear action: wipes the search box and every filter back to
  // defaults, then re-renders. Status returns to All like Reset.
  document.querySelectorAll('[data-clear-search-filters]').forEach((b) => b.addEventListener('click', () => {
    const s = $('txSearch'); if (s) s.value = '';
    txFilter = 'all'; txMonth = 'all'; localStorage.setItem('hb-tx-month', 'all');
    txCard = 'all'; localStorage.setItem('hb-tx-card', 'all');
    txWeekOnly = false; txFromDate = ''; txToDate = '';
    const mn = $('txMinAmount'); if (mn) mn.value = '';
    const mx = $('txMaxAmount'); if (mx) mx.value = '';
    refresh();
  }));
  // Home preview: the 4 newest transactions, tapping one jumps to Transactions.
  const recentEl = $('recentList');
  if (recentEl) {
    recentEl.removeAttribute('aria-busy');
    const recent = [...all].sort((a, b) => b.date.localeCompare(a.date)).slice(0, 4);
    recentEl.innerHTML = txReadFailed
      ? '<li class="muted small error">Could not load recent transactions.</li>'
      : recent.length
      ? recent.map((t) => {
          const excluded = t.excluded === true || t.state === 'excluded';
          return `<li class="tx-row"><div class="tx-head" data-view="purchases" data-recent-tx="${t.id}" role="button" tabindex="0" aria-label="See ${esc(t.merchant)} in Transactions"><div class="tx-line1">${iconForMerchant(t.merchant)}<strong class="tx-name" title="${esc(displayMerchant(t.merchant))}">${esc(displayMerchant(t.merchant))}</strong><span class="tx-amount${t.amount_cents < 0 ? ' negative' : ''}">${formatCents(t.amount_cents)}</span></div>
          <div class="tx-line2">${statePill(t, excluded)}
          <span class="muted small tx-meta">${displayDay(t.date)} · ••${esc(t.card_suffix)}</span></div></div></li>`;
        }).join('')
      : '<li class="muted small">No transactions yet.</li>';
    // Rows added after load need the same tab-switch handler as the nav.
    // UX-review-fix: opening a recent item jumps to Transactions AND
    // expands that row's detail, with the row scrolled into view; the
    // detail itself is the way back (tap the row header to collapse).
    const openRecent = async (el) => {
      showView(el.dataset.view, { clearMessages: true });
      // Refresh first when stale, so the re-render does not collapse
      // the detail we are about to open.
      if (Date.now() - lastRefreshAt > 30000) await refresh();
      const detail = document.getElementById(`tx-detail-${el.dataset.recentTx}`);
      const head = document.querySelector(`[data-tx-head="${el.dataset.recentTx}"]`);
      if (detail) detail.classList.remove('hidden');
      if (head) { head.classList.add('open'); head.scrollIntoView({ block: 'start' }); }
    };
    recentEl.querySelectorAll('[data-view]').forEach((el) => {
      el.addEventListener('click', () => openRecent(el));
      el.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openRecent(el); } });
    });
  }
  // Tap a row header to expand / collapse its detail panel.
  document.querySelectorAll('[data-tx-head]').forEach((el) => el.addEventListener('click', () => {
    document.getElementById(`tx-detail-${el.dataset.txHead}`)?.classList.toggle('hidden');
    el.classList.toggle('open');
  }));
  // Keyboard users get the same disclosure: Enter/Space on a focused
  // row header toggles its detail (a div with role=button does not
  // fire click on keys by itself).
  document.querySelectorAll('[data-tx-head]').forEach((el) => el.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); el.click(); }
  }));
  // Per-stat breakdowns: each number explains itself (the old panel
  // showed the same spending-by-source text for every stat).
  const bd = document.getElementById('weekBreakdown');
  if (bd && currentWeekData) {
    const w = currentWeekData;
    // Spent breakdown: server charges are authoritative. The server total
    // mixes charges dated this week with late charges from locked weeks
    // (A2); the panel shows those two parts separately so the itemized
    // lines always sum exactly to the server total. Excluded and
    // reversed rows are left out. The late part is derived (server
    // total minus dated charges minus verified refunds the server
    // nets), because the loaded list cannot enumerate late rows on its
    // own — it is labeled as late charges, never as dated charges.
    const counted = all.filter((t) => inThisWeek(t) && !(t.excluded === true || t.state === 'excluded') && t.state !== 'reversed');
    const datedRows = counted.filter((t) => t.kind === 'charge' || t.kind === 'fund_charge');
    const datedAmt = (t) => (t.amount_cents ?? 0) - (t.fund_allocation_cents ?? 0);
    const bySrc = {};
    for (const t of datedRows) bySrc[t.source] = (bySrc[t.source] ?? 0) + datedAmt(t);
    const datedTotal = datedRows.reduce((s, t) => s + datedAmt(t), 0);
    const refundTotal = counted.filter((t) => t.kind === 'refund').reduce((s, t) => s + t.amount_cents, 0);
    const verifiedRefundNet = counted.filter((t) => t.kind === 'refund' && t.state === 'verified').reduce((s, t) => s + t.amount_cents, 0);
    const lateTotal = (w.chargesCents ?? 0) - datedTotal - verifiedRefundNet;
    // The Weekly Budget sheet (R6) surfaces these two lines too:
    // the breakdown panel itself has no control that opens it.
    lastSpentBreakdown = { datedTotal, lateTotal };
    const panels = {
      allowance: txReadFailed ? 'Could not load transactions for the breakdown.'
        : `<strong>Weekly allowance ${formatCents(w.baseAllowanceCents ?? w.baseAvailableCents)}</strong> plus ${formatCents(w.tempCents)} in temporary increases this week. Carried debt ${formatCents(w.carriedDebtCents)} comes off the top, leaving ${formatCents(w.baseAvailableCents)} of base spending room.`,
      spent: txReadFailed ? 'Could not load this week\'s transactions for the breakdown.'
        : `<strong>Charges ${formatCents(w.chargesCents)} this week:</strong><br>Dated this week — ${Object.entries(bySrc).map(([s2, v]) => `${esc(sourceLabel(s2))}: ${formatCents(v)}`).join(' · ') || 'nothing yet'} (total ${formatCents(datedTotal)})<br>Late charges from earlier locked weeks: ${formatCents(lateTotal)}<br>Refunds in this week\'s list: ${formatCents(refundTotal)} · Excluded transactions kept out of the math: ${all.filter((t) => t.excluded === true || t.state === 'excluded').length}`,
      debt: w.carriedDebtCents > 0
        ? `<strong>${formatCents(w.carriedDebtCents)} carried over</strong> from earlier weeks — it comes off the top of this week's allowance before anything else.`
        : 'No carried-over overspending: this week starts with the full allowance.',
      outgoing: w.outgoingDebtCents > 0
        ? `<strong>${formatCents(w.outgoingDebtCents)} outgoing debt</strong> = ${formatCents(w.unabsorbedDebtCents ?? Math.max(0, w.carriedDebtCents - (w.baseAllowanceCents ?? w.baseAvailableCents)))} debt the allowance did not cover plus ${formatCents(w.newDebtCents ?? Math.max(0, w.outgoingDebtCents - (w.unabsorbedDebtCents ?? 0)))} new debt from spending above this week's room. It carries into next week.`
        : 'No outgoing debt: this week\'s spending stayed within its room.',
    };
    bd.dataset.panels = JSON.stringify(panels);
    if (!bd.classList.contains('hidden') && bd.dataset.stat && panels[bd.dataset.stat]) {
      bd.innerHTML = `<p class="small">${panels[bd.dataset.stat]}</p>`;
    }
  }
  // Send-live-bundle, detail Actions sheet + Trash. The Actions
  // line in each detail opens openTxActionsSheet (defined just
  // below, outside refresh so it can be called from the Trash list
  // too if needed). It lists exactly Charity, Extra Fund, Other,
  // Delete — the same pattern as the Add popup list. Charity rows
  // show Delete only; members see Extra Fund only, on charges.
  // Charity automatically excludes Extra Fund: a charity row gets
  // no Extra Fund action, and the Extra Fund action itself refuses
  // charity rows (the server already guards this; this is the UI
  // making it explicit). Delete: hand-written rows are permanently
  // deleted (delete_transaction, cannot be undone); bank/email/file
  // rows are moved to Trash via exclude_transaction with a reason,
  // with the exact toast 'Moved to trash bin.', and leave the main
  // list. Trash is rendered below from `all` (excluded rows only).
  document.querySelectorAll('[data-tx-actions]').forEach((b) => b.addEventListener('click', async () => {
    const row = all.find((t) => t.id === b.dataset.txActions);
    if (row) await openTxActionsSheet(row);
  }));
  const trashBtn = $('txTrashBtn');
  if (trashBtn) {
    const trashCountEl = $('txTrashCount'); if (trashCountEl) trashCountEl.textContent = trashRowCount ? ` (${trashRowCount})` : '';
    trashBtn.style.display = (household && household.role === 'admin' && trashRowCount > 0) ? '' : 'none';
    if (!trashBtn.dataset.bound) {
      trashBtn.dataset.bound = '1';
      trashBtn.addEventListener('click', () => {
        const el = $('txTrashList'); if (!el) return;
        const nowHidden = el.classList.toggle('hidden');
        // Task 5: Trash is a sub-view of Transactions, admin-only.
        // Persist it so a reload returns to the open Trash, not
        // just the Transactions list; a member never restores it
        // (resolveRestoredSubView returns null for members).
        try { localStorage.setItem('hb-view-sub', nowHidden ? '' : 'trash'); } catch (e) { /* private mode */ }
      });
      $('txTrashCloseBtn')?.addEventListener('click', () => { $('txTrashList')?.classList.add('hidden'); try { localStorage.setItem('hb-view-sub', ''); } catch (e) { /* private mode */ } });
    }
  }
  // Task 5: reopen the Trash list when the saved sub-view says so
  // (admin only; members get null from resolveRestoredSubView).
  if (resolveRestoredSubView(currentView, localStorage.getItem('hb-view-sub'), household?.role) === 'trash') {
    $('txTrashList')?.classList.remove('hidden');
  }
  const trashEl = $('trashList');
  if (trashEl) {
    const trash = all.filter((t) => t.excluded === true || t.state === 'excluded');
    trashEl.innerHTML = trash.length
      ? trash.map((t) => `<li class="tx-row"><div class="tx-line1">${iconForMerchant(t.merchant)}<strong class="tx-name">${esc(displayMerchant(t.merchant))}</strong><span class="tx-amount${t.amount_cents < 0 ? ' negative' : ''}">${formatCents(t.amount_cents)}</span></div>
        <div class="tx-line2"><span class="muted small tx-meta">${displayDay(t.date)} · ••${esc(t.card_suffix)}</span></div>
        <div class="btn-row"><button class="btn btn-small btn-primary" data-trash-restore="${t.id}" type="button" aria-label="Restore ${esc(t.merchant)} from trash">Restore</button></div></li>`).join('')
      : '<li class="muted small">Trash is empty.</li>';
    trashEl.querySelectorAll('[data-trash-restore]').forEach((b) => b.addEventListener('click', async () => {
      const row = all.find((t) => t.id === b.dataset.trashRestore);
      const { error } = await supabase.rpc('restore_transaction', { txn_id: b.dataset.trashRestore });
      if (error) { console.warn('restore_transaction failed:', error.message); await showAlert('Could not restore', 'Could not restore this transaction. Try again.'); return; }
      await audit('Transaction restored', `${row ? row.merchant : 'Transaction'} returned to the week.`);
      await refresh();
    }));
  }

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
        // UX-review-fix: the detail shows requested, available,
        // approved, and remainder together, so a partial approval is
        // not ambiguous: approved = requested − remainder, and the
        // remainder stays unapproved (it is not paid later on its
        // own — a new request is needed for it).
        const approvedCents = r.status === 'approved' ? r.amount_cents : (r.status === 'split' && r.remainder_cents != null ? r.amount_cents - r.remainder_cents : null);
        return `<li><div data-fund-head="${r.id}" role="button" tabindex="0" aria-label="Show detail for this Extra Fund request">${formatCents(r.amount_cents)} · ${esc(statusLabel)} · ${esc(r.note || '')}</div>
        <div class="tx-detail hidden" id="fund-detail-${r.id}">
          <p class="small muted">Requested: ${formatCents(r.amount_cents)} · Status: ${esc(statusLabel)}<br>
          Fund available now: ${currentFundData ? formatCents(currentFundData.available) : 'not loaded'}<br>
          ${approvedCents !== null ? `Approved: ${formatCents(approvedCents)}${r.status === 'split' ? ` of ${formatCents(r.amount_cents)} requested — ${formatCents(r.remainder_cents)} is still unapproved and needs a new request.` : ' (in full).'}` : ''}<br>
          Note: ${esc(r.note || '—')}<br>
          Requested: ${fmtDateTime(r.created_at)}<br>
          ${r.status === 'pending' ? 'Waiting on the admin decision. You can track it here — its status changes when the admin approves or declines it.' : r.status === 'approved' ? 'Approved — the fund balance above already reflects it.' : r.status === 'split' ? 'Split approval — see the approved and remaining amounts above.' : 'Declined by the admin.'}</p>
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
    let { error } = await supabase.rpc('approve_and_allocate', { p_request_id: b.dataset.approve, p_amount_cents: cents, p_override_reason: null });
    if (error && /insufficient fund/i.test(error.message)) {
      const reason = await showSheet({ title: 'Fund is short', message: `The fund does not cover ${formatCents(cents)}. You can still approve with a typed reason — it will be logged.`, inputLabel: 'Reason for overriding', confirmLabel: 'Approve anyway', cancelLabel: 'Cancel' });
      if (reason === null) return;
      ({ error } = await supabase.rpc('approve_and_allocate', { p_request_id: b.dataset.approve, p_amount_cents: cents, p_override_reason: reason.trim() }));
    }
    if (error) { console.warn('approve_and_allocate failed:', error.message); await showAlert('Could not approve', 'Could not approve this request. Please try again in a moment.'); } else await refresh();
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
      : `<div class="sav-grid"><div><div class="kicker">Balance</div><div class="num">${savBalance !== null ? formatCents(savBalance) : 'Not recorded yet'}</div></div><div><div class="kicker">Transferred in</div><div class="num">${formatCents(savIn)}</div></div><div><div class="kicker">Withdrawn</div><div class="num">${formatCents(savOut)}</div></div><div><div class="kicker">Interest / adjustments</div><div class="num">${formatCents(savInterestAdj)}</div></div></div>${savBalance === null && !savRows.length ? '<p class="muted small">No past savings records yet — these old records are separate from the Extra Fund, which is the savings story now.</p>' : savBalance === null ? '<p class="muted small">Past savings records exist, but no balance was ever recorded for them — that is a missing balance, not $0.</p>' : ''}`;
  }
  $('savingsList').innerHTML = savErr
    ? '<p class="error">Could not load savings records. Try again.</p>'
    : savRows.length
    ? `<ul>${savRows.slice(0, 20).map((r) => `<li>${esc(r.kind)} ${formatCents(r.amount_cents ?? 0)}${r.actual_balance_cents != null ? ` · Recorded balance ${formatCents(r.actual_balance_cents)}` : ''} · ${fmtDateTime(r.created_at)} · ${esc(r.note || '')}</li>`).join('')}</ul>${savRows.length > 20 ? '<p class="muted small">Showing the latest 20 records.</p>' : ''}`
    : ''; // UX-review-fix: one empty message only, in the summary above — not repeated here.
  // Delta A1: the everyday Savings section is gone — the records
  // above stay read-only behind the Funds page's "Past savings
  // records" link. No form exists anymore, so nothing here writes
  // savings; the database rows are untouched.

  // Bank accounts UI — SERVER TRUTH ONLY. Connected state derives from
  // plaid_items rows (status 'active' vs 'disconnected') and their
  // plaid_accounts rows. localStorage is never consulted for connection
  // state. No token, cursor, or secret is ever rendered.
  let bankLastSyncAt = null;
  try {
    const { data: items, error: itemsErr } = await supabase.from('plaid_items_public')
      .select('id, plaid_item_id, institution_name, institution_id, status, last_sync_at, created_at')
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
    // R3: load nicknames (gracefully absent until r3-account-nicknames.sql
    // is applied live — the bank list still renders, without nicknames).
    nicknameByAccount = new Map(); nicknameBySuffix = new Map(); nicknamesLoaded = false;
    try {
      const { data: nicks, error: nickErr } = await supabase.from('account_nicknames')
        .select('plaid_item_id, plaid_account_id, card_suffix, nickname').eq('household_id', household.household_id);
      if (nickErr) throw nickErr;
      const suffixCounts = new Map();
      for (const n of nicks ?? []) {
        nicknameByAccount.set(`${n.plaid_item_id}|${n.plaid_account_id}`, n.nickname);
        if (n.card_suffix) suffixCounts.set(n.card_suffix, (suffixCounts.get(n.card_suffix) ?? 0) + 1);
      }
      for (const n of nicks ?? []) {
        if (n.card_suffix && suffixCounts.get(n.card_suffix) === 1) nicknameBySuffix.set(n.card_suffix, n.nickname);
      }
      nicknamesLoaded = true;
    } catch (e) { console.warn('nicknames read failed:', e.message); }
    const syncTimes = itemRows.map((i) => i.last_sync_at).filter(Boolean).sort();
    bankLastSyncAt = syncTimes.length ? syncTimes[syncTimes.length - 1] : null;
    const syncLine = $('bankSyncLine');
    if (syncLine) syncLine.textContent = bankLastSyncAt ? `Last synced ${fmtDateTime(bankLastSyncAt)}` : 'Not synced yet.';
    const ls = document.getElementById('lastSync'); if (ls) ls.textContent = bankLastSyncAt ? fmtDateTime(bankLastSyncAt) : 'Not synced yet';
    const cb = $('connectBankBtn');
    // Button-card-fix: Connect stays primary and Sync stays secondary
    // in every state. The old code stripped primary from Connect and
    // toggled it onto Sync when an item was active, so with no active
    // item Connect and Sync were adjacent secondary buttons — the
    // exact duplicate the owner rule forbids. Sequence is now always
    // primary, secondary, tertiary.
    if (cb) { cb.disabled = false; cb.classList.add('btn-primary'); cb.textContent = itemRows.some((i) => i.status === 'active') ? 'Connect another bank account' : 'Connect a bank account'; }
    // Reaudit N1: bank linking is admin-only (plaid-link/plaid-exchange
    // enforce it server-side with a 403); hide the connect button for
    // non-admins so members never see a dead button.
    if (cb) cb.style.display = (household && household.role === 'admin') ? '' : 'none';
    const sb = $('syncBankBtn');
    if (sb) sb.classList.remove('btn-primary');
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
        if (item.created_at) { const cl = document.createElement('div'); cl.className = 'muted small'; cl.textContent = `Connected ${fmtLong(String(item.created_at).slice(0, 10))}`; info.appendChild(cl); }
        const accts = acctRows.filter((x) => x.plaid_item_id === item.plaid_item_id);
        if (accts.length) {
          for (const acct of accts) {
            const line = document.createElement('div'); line.className = 'muted small';
            const nick = nicknameByAccount.get(`${item.plaid_item_id}|${acct.plaid_account_id}`);
            const typeLabel = plainAccountType(acct.type, acct.subtype);
            line.textContent = `${nick ? `${nick} · ` : ''}${acct.name || 'Account'}${acct.mask ? ` ••${acct.mask}` : ''}${typeLabel ? ` · ${typeLabel}` : ''}`;
            info.appendChild(line);
            // R3: nickname editing lives in Settings, admin-only, via
            // the RPC (never a direct table write).
            if (household.role === 'admin') {
              const nickBtn = document.createElement('button'); nickBtn.className = 'btn btn-small'; nickBtn.type = 'button';
              nickBtn.textContent = nick ? 'Edit nickname' : 'Add nickname';
              nickBtn.setAttribute('aria-label', `Set a nickname for ${acct.name || 'this account'}`);
              nickBtn.addEventListener('click', async () => {
                if (!nicknamesLoaded) { await showAlert('Nicknames unavailable', 'Nicknames could not be loaded. Try again.'); return; }
                const value = await showSheet({ title: 'Nickname', message: 'Give this account a short name (up to 40 characters). Leave it blank to remove the nickname. The nickname is only a label — it never changes bank links, matching, or week math.', inputLabel: 'Nickname', inputValue: nick ?? '', confirmLabel: 'Save', cancelLabel: 'Cancel' });
                if (value === null) return;
                const { error } = await supabase.rpc('set_account_nickname', { p_household_id: household.household_id, p_plaid_item_id: item.plaid_item_id, p_plaid_account_id: acct.plaid_account_id, p_card_suffix: acct.mask ?? null, p_nickname: value.trim() ? value.trim().slice(0, 40) : null });
                if (error) { console.warn('set_account_nickname failed:', error.message); await showAlert('Could not save nickname', 'Could not save this nickname. Try again.'); } else await refresh();
              });
              info.appendChild(nickBtn);
            }
          }
        } else {
          const line = document.createElement('div'); line.className = 'muted small'; line.textContent = 'Account details unavailable.'; info.appendChild(line);
        }
        if (item.last_sync_at) { const line = document.createElement('div'); line.className = 'muted small'; line.textContent = `Last synced ${fmtDateTime(item.last_sync_at)}`; info.appendChild(line); }
        wrap.appendChild(info);
        if (item.status === 'active' && household.role === 'admin') {
          const btn = document.createElement('button'); btn.className = 'btn btn-small btn-danger'; btn.type = 'button';
          // UX-review-fix: two connections can share one institution
          // name, so Disconnect must identify THIS connection — by
          // its masked accounts (and connection date when known), in
          // both the button label and the confirmation. Accounts are
          // already grouped under their connection above; this is the
          // disambiguation the duplicate-Disconnect report asked for.
          // It does not change disconnect behavior: past transactions
          // stay, only syncing stops (see the confirmation copy).
          const connMasks = acctRows.filter((x) => x.plaid_item_id === item.plaid_item_id).map((x) => x.mask ? `••${x.mask}` : 'account').join(', ');
          const connId = connMasks ? `${item.institution_name || 'Bank'} (${connMasks})` : (item.institution_name || 'bank');
          btn.textContent = 'Disconnect'; btn.setAttribute('aria-label', `Disconnect ${connId}`);
          btn.addEventListener('click', async () => {
            if (!(await showConfirm('Disconnect bank', `Disconnect ${connId}? The app will stop syncing this connection only. Past transactions stay in the list, and other connections are untouched.`, 'Disconnect'))) return;
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
  // The card is visible to all members: the view is member-readable
  // by design (household_members RLS), and UX audit 10 asks that
  // status lines stay visible. What members do NOT get is actions:
  // Connect / Check buttons are hidden in showView, Disconnect
  // buttons are rendered admin-only below, and the connect /
  // disconnect Edge Functions still enforce admin server-side.
  // This is ADDITIVE: it never touches the owner's existing
  // Apps Script email path, which keeps working unchanged.
  const emailCard = $('section-email');
  if (emailCard) emailCard.style.display = '';
  {
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
          const p = document.createElement('p'); p.className = 'muted small'; p.textContent = household.role === 'admin' ? 'None — connect an email above.' : 'None — the admin connects email alerts.'; frag.appendChild(p);
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
          if (household.role === 'admin') {
          const btn = document.createElement('button'); btn.className = 'btn btn-small btn-danger'; btn.type = 'button';
          btn.textContent = 'Disconnect'; btn.setAttribute('aria-label', `Disconnect ${c.email_address || 'email'}`);
          btn.addEventListener('click', async () => {
            if (!(await showConfirm('Disconnect email', `Disconnect ${c.email_address || 'this email'}? The app will stop checking it. Past transactions stay in the list.`, 'Disconnect'))) return;
            const out = await callFn('gmail-disconnect', { household_id: household.household_id, connection_id: c.id });
            if (!out.disconnected) { console.warn('gmail-disconnect failed:', out.error); await showAlert('Could not disconnect', 'Could not disconnect this email. Try again.'); return; }
            await refresh();
          });
          wrap.appendChild(btn);
          }
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
  // Extra Fund summary — aggregates from fund_ledger /
  // surplus_releases / week_closes. The tap sheet shows only
  // Available / Pending / Total (owner, Nov 4); the other aggregates
  // stay computed in currentFundData for history and previews.
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
    currentFundData = { available, pending, releasedTotal, spent, shortfall, heldTotal, heldWeeks: heldRows.length };
    const fp = $('homeFundPrimary'); if (fp) { fp.innerHTML = formatCentsHtml(available); fp.removeAttribute('aria-busy'); }
    // UX audit 07: a member cannot spend fund money, only request it
    // and wait for approval — so members read "Available to request".
    // Audit-merge fix (review B F2): admins read "Available to use"
    // (was "Spendable now"). That wording
    // lives in the tap sheet and in the Home card's aria-label, not
    // on either card face (numbers-only faces, UX-review-fix).
    const fundFreeWord = household.role === 'admin' ? 'Available to use' : 'Available to request';
    // Numbers-only face: the secondary line is gone from the card.
    // Its wording lives in the tap sheet and in the aria-label.
    // Fund-sheet-button-rule (owner, Nov 4): the Home fund card's
    // aria-label carries Available + the sheet's Pending (pending
    // releases plus held weeks) — no owed-back mention, matching the
    // three-row sheet (Available / Pending / Total).
    const pendingAll = pending + heldTotal;
    document.querySelector('[data-home-card="fund"]')?.setAttribute('aria-label', pendingAll > 0
      ? `Extra Fund, ${formatCents(available)} ${fundFreeWord.toLowerCase()}, ${formatCents(pendingAll)} pending, show breakdown`
      : `Extra Fund, ${formatCents(available)} ${fundFreeWord.toLowerCase()}, show breakdown`);
    const fs = $('fundSummary');
    // Button-card-fix: the face is Title + Amount only. The title is
    // the h2 in live.html; this is the amount alone, no "Available"
    // word, no secondary lines. Available, Pending, and Total live
    // in the tap sheet (fundBreakdownRows).
    if (fs) fs.innerHTML = `<p class="fund-balance"><strong>${formatCents(available)}</strong></p>`;
    const heldWrap = document.getElementById('fundHeldLinkWrap');
    if (heldWrap) {
      heldWrap.classList.toggle('hidden', !(heldRows.length > 0));
      const heldBtn = document.getElementById('fundHeldLinkBtn');
      if (heldBtn && heldRows.length > 0) heldBtn.textContent = `Held for review: ${formatCents(heldTotal)} across ${heldRows.length} ${heldRows.length === 1 ? 'week' : 'weeks'} — Open Review queue`;
    }
    updateFundTopupPreview();
  } catch (e) {
    console.warn('fund summary read failed:', e);
    // Clear the cached fund data (the charity block already does
    // this): otherwise the Home fund card keeps showing old numbers
    // with no stale label after a failed read.
    currentFundData = null;
    const fp = $('homeFundPrimary'); if (fp) fp.textContent = '—';
    document.querySelector('[data-home-card="fund"]')?.setAttribute('aria-label', 'Extra Fund, could not load balances, show breakdown');
    const fs = $('fundSummary');
    if (fs) fs.innerHTML = '<p class="error">Could not load fund balances. Try again.</p>';
    document.getElementById('fundHeldLinkWrap')?.classList.add('hidden');
  }
  // R12 top-up history (admin only, READ-ONLY list). One row per
  // top-up with the split it made, newest first. A load failure
  // shows an error, never an empty list. The preview split is
  // informational only; the server split returned by add_fund_money
  // is authoritative.
  if (household.role === 'admin') {
    try {
      const { data: topRows, error: topErr } = await supabase.from('fund_topups')
        .select('amount_cents, shortfall_covered_cents, fund_added_cents, shortfall_after_cents, note, created_at')
        .eq('household_id', household.household_id).order('created_at', { ascending: false }).limit(50);
      if (topErr) throw topErr;
      const tl = $('fundTopupsList');
      if (tl) {
        const frag = document.createDocumentFragment();
        if (!(topRows ?? []).length) { const p = document.createElement('p'); p.className = 'muted small'; p.textContent = 'No money added yet.'; frag.appendChild(p); }
        for (const r of topRows ?? []) {
          const li = document.createElement('li');
          const d = new Date(r.created_at);
          const when = Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
          li.innerHTML = `<strong>${formatCents(r.amount_cents)}</strong> <span class="muted small">${esc(when)} · ${formatCents(r.shortfall_covered_cents ?? 0)} covered owed back · ${formatCents(r.fund_added_cents ?? 0)} added to fund · Owed back after ${formatCents(r.shortfall_after_cents ?? 0)}${r.note ? ` · ${esc(r.note)}` : ''}</span>`;
          frag.appendChild(li);
        }
        tl.replaceChildren(frag);
      }
    } catch (e) {
      console.warn('fund topups read failed:', e);
      const tl = $('fundTopupsList'); if (tl) tl.innerHTML = '<li class="error">Could not load money added. Try again.</li>';
    }
  }
  // R13 charity aggregates — November 2026 onward, all members read.
  // Committed is summed per active income row at that row's own rate
  // (half-up, engine helper); Given counts only verified, unexcluded
  // charity rows. A read failure is an error state on the cards,
  // never zeros presented as real numbers.
  try {
    const { data: incRows, error: incErr } = await supabase.from('charity_income')
      .select('amount_cents, rate_bp').eq('household_id', household.household_id).eq('status', 'active').limit(1000);
    const { data: setRow, error: setErr } = await supabase.from('charity_settings')
      .select('default_rate_bp').eq('household_id', household.household_id).maybeSingle();
    const { data: giftRows, error: giftErr } = await supabase.from('transactions')
      .select('amount_cents').eq('household_id', household.household_id).eq('kind', 'charity')
      .eq('state', 'verified').eq('excluded', false).gte('date', '2026-11-01').limit(1000);
    if (incErr || setErr || giftErr) throw (incErr || setErr || giftErr);
    const committed = (incRows ?? []).reduce((s, r) => s + charityCommittedCents(r.amount_cents ?? 0, r.rate_bp ?? 1000), 0);
    const given = (giftRows ?? []).reduce((s, r) => s + (r.amount_cents ?? 0), 0);
    const remaining = committed - given;
    const defaultRateBp = setRow?.default_rate_bp ?? 1000;
    currentCharityData = { committed, given, remaining, defaultRateBp };
    const cp = $('homeCharityPrimary');
    // UX-review-fix: a dash is the LOADING / FAILED state only (the
    // initial HTML says "Loading charity…" and the catch block sets
    // '—'). A successfully loaded zero is a confirmed $0.00, not a
    // dash — the popup and Funds already showed $0.00, so Home
    // showing '—' for the same state was the inconsistency. The
    // secondary line still says "No charity tracked yet." for the
    // no-activity case, so no-activity vs confirmed-zero vs
    // loading are now three distinct states.
    // Numbers-only face: a confirmed zero is $0.00, a negative
    // remaining is a signed number (given more than committed).
    // "No charity tracked yet" lives in the aria-label, and the
    // Given/Total words live in the tap sheet and the aria-label,
    // not on the face.
    if (cp) { cp.textContent = formatCents(remaining); cp.removeAttribute('aria-busy'); }
    document.querySelector('[data-home-card="charity"]')?.setAttribute('aria-label', (committed === 0 && given === 0)
      ? 'Charity, no charity tracked yet, show breakdown'
      : remaining < 0
      ? `Charity, ahead by ${formatCents(Math.abs(remaining))}, show breakdown`
      : `Charity, ${formatCents(remaining)} remaining, ${formatCents(given)} given, ${formatCents(committed)} committed, show breakdown`);
    const ch = $('charitySummary');
    // Button-card-fix: the face is Title + Amount only. The title is
    // the h2 in live.html; this is the amount alone. A negative
    // remaining still reads as a signed number on the face, and the
    // tap sheet shows Available (signed) / Given / Total
    // (charityBreakdownRows); Default rate lives on the Funds
    // income & rate card, the period in the sheet title.
    if (ch) ch.innerHTML = `<p class="fund-balance"><strong>${formatCents(remaining)}</strong></p>`;
    document.querySelector('[data-fund-card="charity"]')?.setAttribute('aria-label', remaining < 0
      ? `Show Charity breakdown, ahead by ${formatCents(Math.abs(remaining))}`
      : `Show Charity breakdown, ${formatCents(remaining)} remaining`);
    const cr = $('charityRateCurrent');
    if (cr) cr.textContent = `Current default rate: ${(defaultRateBp / 100).toFixed(2).replace(/\.?0+$/, '')}%.`;
    updateCharityIncomePreview();
  } catch (e) {
    console.warn('charity read failed:', e);
    currentCharityData = null;
    const cp = $('homeCharityPrimary'); if (cp) cp.textContent = '—';
    document.querySelector('[data-home-card="charity"]')?.setAttribute('aria-label', 'Charity, could not load, show breakdown');
    const ch = $('charitySummary'); if (ch) ch.innerHTML = '<p class="error">Could not load charity. Try again.</p>';
  }
  // R13 charity income list (admin only, READ-ONLY except Correct,
  // which prefills the form for an append-only reversal + replacement).
  if (household.role === 'admin') {
    try {
      const { data: allInc, error: allIncErr } = await supabase.from('charity_income')
        .select('id, source_label, amount_cents, income_date, rate_bp, status, note')
        .eq('household_id', household.household_id).order('income_date', { ascending: false }).limit(50);
      if (allIncErr) throw allIncErr;
      const il = $('charityIncomeList');
      if (il) {
        const frag = document.createDocumentFragment();
        if (!(allInc ?? []).length) { const p = document.createElement('p'); p.className = 'muted small'; p.textContent = 'No income recorded yet.'; frag.appendChild(p); }
        for (const r of allInc ?? []) {
          const li = document.createElement('li');
          const committedOne = charityCommittedCents(r.amount_cents ?? 0, r.rate_bp ?? 1000);
          li.innerHTML = `<strong>${esc(r.source_label)}</strong> · ${formatCents(r.amount_cents)} on ${fmtLong(r.income_date)} at ${(r.rate_bp / 100).toFixed(2).replace(/\.?0+$/, '')}% → commits ${formatCents(committedOne)}${r.note ? ` · ${esc(r.note)}` : ''}${r.status === 'reversed' ? ' <span class="muted small">(Reversed — replaced)</span>' : ''}`;
          if (r.status === 'active') {
            const btn = document.createElement('button'); btn.className = 'btn btn-small'; btn.type = 'button';
            btn.textContent = 'Correct'; btn.setAttribute('aria-label', `Correct income ${esc(r.source_label)}`);
            btn.addEventListener('click', () => {
              correctingIncomeId = r.id;
              const f = document.getElementById('charityIncomeForm');
              if (f) {
                f.source.value = r.source_label; f.amount.value = (r.amount_cents / 100).toFixed(2);
                f.date.value = r.income_date; f.rate.value = (r.rate_bp / 100).toFixed(2).replace(/\.?0+$/, '');
                f.note.value = r.note || '';
              }
              const mode = $('charityIncomeMode');
              if (mode) mode.textContent = 'Correcting an earlier entry — saving reverses it and adds a replacement. The old entry stays, marked reversed.';
              const cancel = $('charityIncomeCancelBtn');
              if (cancel) cancel.style.display = '';
              updateCharityIncomePreview();
            });
            li.appendChild(document.createTextNode(' ')); li.appendChild(btn);
          }
          frag.appendChild(li);
        }
        il.replaceChildren(frag);
      }
    } catch (e) {
      console.warn('charity income read failed:', e);
      const il = $('charityIncomeList'); if (il) il.innerHTML = '<li class="error">Could not load income. Try again.</li>';
    }
  }
  // Refund restorations + held refunds (admin only, READ-ONLY lists).
  // Delta C3: these live in the Funds Review area, which showView
  // gates to admins and which starts collapsed; members never see
  // the section and no read is attempted for them, mirroring the
  // email card. Pending held rows get a Release button calling the
  // resolve_held_refund RPC with action 'release' (owner decision 2:
  // release goes to spendable surplus, shortfall first).
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
      reviewNeedsCount = (heldRows2 ?? []).filter((h) => h.status === 'pending').length;
      updateMoreReviewLabel();
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
  // Possible duplicates (admin only, Funds tab, inside the Review
  // area). Reads pending duplicate_candidates + all their transactions in ONE query
  // (Nov 3 fix round: it used to query one pair at a time, up to
  // 100 queries). Same purchase and Separate both go through
  // resolve_duplicate_candidate, which never deletes a row.
  if (household.role === 'admin') {
    try {
      const { data: candRows, error: candErr } = await supabase.from('duplicate_candidates')
        .select('id, canonical_transaction_id, duplicate_transaction_id, reason, merchant_a, merchant_b')
        .eq('household_id', household.household_id).eq('status', 'pending').order('created_at', { ascending: true }).limit(100);
      if (candErr) throw candErr;
      reviewNeedsCount += (candRows ?? []).length;
      updateMoreReviewLabel();
      const dl = $('dedupeList');
      if (dl) {
        const frag = document.createDocumentFragment();
        if (!(candRows ?? []).length) { const p = document.createElement('p'); p.className = 'muted small'; p.textContent = 'No possible duplicates waiting.'; frag.appendChild(p); }
        const allIds = [...new Set((candRows ?? []).flatMap((c) => [c.canonical_transaction_id, c.duplicate_transaction_id]))];
        const { data: txRows } = allIds.length
          ? await supabase.from('transactions')
            .select('id, merchant, amount_cents, date, card_suffix, source, excluded')
            .in('id', allIds)
          : { data: [] };
        const byId = new Map((txRows ?? []).map((t) => [t.id, t]));
        const shownCands = (candRows ?? []).slice(0, 20);
        if ((candRows ?? []).length > shownCands.length) { const p = document.createElement('p'); p.className = 'muted small'; p.textContent = `Showing the first 20 of ${(candRows ?? []).length} possible duplicates.`; frag.appendChild(p); }
        for (const c of shownCands) {
          const keep = byId.get(c.canonical_transaction_id);
          const dup = byId.get(c.duplicate_transaction_id);
          // UX-review-fix, duplicates readability (owner screenshot
          // Nov 3, 7:49 PM): the old .bank-row flex row squeezed the
          // pair into ~180px, broke merchant names mid-word, and
          // rendered both records as one long dot-joined paragraph.
          // Each pair is now a vertical comparison card: merchant on
          // its own bold line, labeled Amount/Date/Card/Source rows
          // (like the transaction detail), Keep and Possible stacked
          // on phone and side-by-side only at wide widths, a match
          // summary up top, buttons BELOW the comparison, and the
          // remember-alias checkbox with its explanation below the
          // buttons. Resolution logic, RPCs, and flagging are
          // untouched — presentation only.
          const card = document.createElement('div'); card.className = 'dedupe-card';
          const matchParts = [];
          if (keep && dup) {
            if (keep.amount_cents === dup.amount_cents) matchParts.push('same amount');
            if (keep.date === dup.date) matchParts.push('same date');
            if (keep.card_suffix === dup.card_suffix) matchParts.push('same card');
            if (keep.source === dup.source) matchParts.push('same source');
          }
          const match = document.createElement('p'); match.className = 'dedupe-match';
          match.textContent = matchParts.length ? `Match: ${matchParts.join(', ')}.` : 'Compare the two records below.';
          card.appendChild(match);
          const pair = document.createElement('div'); pair.className = 'dedupe-pair';
          const side = (label, tx, fallback) => {
            const sEl = document.createElement('div'); sEl.className = 'dedupe-side';
            const h = document.createElement('h4'); h.textContent = label; sEl.appendChild(h);
            if (!tx) { const pp = document.createElement('p'); pp.className = 'muted small'; pp.textContent = fallback; sEl.appendChild(pp); return sEl; }
            const m = document.createElement('p'); m.className = 'dedupe-merchant'; m.textContent = tx.merchant; sEl.appendChild(m);
            const rows = document.createElement('div'); rows.className = 'dedupe-rows';
            const row = (k, v) => { const d = document.createElement('div'); const a = document.createElement('span'); a.textContent = k; const b = document.createElement('span'); b.textContent = v; d.appendChild(a); d.appendChild(b); rows.appendChild(d); };
            row('Amount', formatCents(tx.amount_cents));
            row('Date', fmtLong(tx.date));
            row('Card', tx.card_suffix ? `\u2022\u2022${tx.card_suffix}` : '—');
            row('Source', sourceLabel(tx.source));
            row('Counts', tx.excluded ? 'Excluded' : 'Counted');
            sEl.appendChild(rows);
            return sEl;
          };
          pair.appendChild(side('Keep', keep, 'Keep: transaction not found'));
          pair.appendChild(side('Possible duplicate', dup, 'Possible duplicate: transaction not found'));
          card.appendChild(pair);
          const btnRow = document.createElement('div'); btnRow.className = 'btn-row';
          const aliasLabel = document.createElement('label'); aliasLabel.className = 'dedupe-alias';
          const aliasBox = document.createElement('input'); aliasBox.type = 'checkbox'; aliasBox.setAttribute('aria-label', 'Remember these merchant names as the same merchant for future review');
          aliasLabel.appendChild(aliasBox); aliasLabel.appendChild(document.createTextNode(' Remember as same merchant — remembers these two merchant names as the same for future review, so similar pairs are treated as the same merchant next time.'));
          const sameBtn = document.createElement('button'); sameBtn.className = 'btn btn-small btn-primary'; sameBtn.type = 'button'; sameBtn.textContent = 'Same purchase';
          sameBtn.addEventListener('click', async () => {
            if (!(await showConfirm('Same purchase', 'Keep one transaction and exclude the other from counts? Neither row is deleted.', 'Same purchase'))) return;
            sameBtn.disabled = true;
            const { error } = await supabase.rpc('resolve_duplicate_candidate', { p_candidate_id: c.id, p_action: 'merge', p_note: '', p_remember_alias: aliasBox.checked });
            if (error) { console.warn('resolve_duplicate_candidate failed:', error.message); sameBtn.disabled = false; await showAlert('Could not resolve', 'Could not resolve this pair. Try again.'); } else await refresh();
          });
          btnRow.appendChild(sameBtn);
          const sepBtn = document.createElement('button'); sepBtn.className = 'btn btn-small btn-tertiary'; sepBtn.type = 'button'; sepBtn.textContent = 'Separate';
          sepBtn.addEventListener('click', async () => {
            if (!(await showConfirm('Separate purchases', 'Keep both transactions and never flag this pair again?', 'Separate'))) return;
            sepBtn.disabled = true;
            const { error } = await supabase.rpc('resolve_duplicate_candidate', { p_candidate_id: c.id, p_action: 'separate', p_note: '', p_remember_alias: false });
            if (error) { console.warn('resolve_duplicate_candidate failed:', error.message); sepBtn.disabled = false; await showAlert('Could not resolve', 'Could not resolve this pair. Try again.'); } else await refresh();
          });
          btnRow.appendChild(sepBtn);
          card.appendChild(btnRow);
          card.appendChild(aliasLabel);
          frag.appendChild(card);
        }
        dl.replaceChildren(frag);
      }
    } catch (e) {
      console.warn('dedupe read failed:', e);
      const dl = $('dedupeList'); if (dl) dl.innerHTML = '<p class="error">Could not load possible duplicates. Try again.</p>';
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
    // Delta B1: the total count covers the full data set, not just
    // the page — it is honesty garnish, so a failed count never
    // blocks the list itself.
    let closesTotal = null;
    try {
      const { count } = await supabase.from('week_closes').select('week_start', { count: 'exact', head: true }).eq('household_id', household.household_id);
      if (Number.isInteger(count)) closesTotal = count;
    } catch (e) { /* count unavailable; the list still renders */ }
    const wh = $('weekHistoryList');
    // R10: weekly summaries first, with carry-in explained. Carry-in
    // for a week is the previous closed week's outgoing debt (the
    // debt-carry chain); a first week has no carry-in on record, and
    // missing figures are shown as not recorded, never as $0.
    const asc = [...(closes ?? [])].sort((a, b) => String(a.week_start).localeCompare(String(b.week_start)));
    const carryInByWeek = new Map();
    asc.forEach((c, i) => { carryInByWeek.set(c.week_start, i === 0 ? null : asc[i - 1].outgoing_debt_cents); });
    const fmtOrMissing = (v) => Number.isInteger(v) ? formatCents(v) : 'not recorded';
    // Delta B1: the date filter narrows what is shown (carry-in
    // still comes from the full chain above, so it stays true).
    const shownCloses = filterRowsByDate(closes ?? [], (c) => c.week_start, historyFilter.from, historyFilter.to);
    lastWeekHistoryShown = { shown: shownCloses.length, total: closesTotal };
    const periodEl = $('historyPeriodLine');
    if (periodEl) periodEl.textContent = historyPeriodLabel(historyFilter.from, historyFilter.to);
    if (wh) wh.innerHTML = shownCloses.length
      ? shownCloses.map((c) => {
          const rel = relByWeek.get(c.week_start);
          // Owner screenshot (Nov 3): the one-line summary wraps
          // badly and is hard to scan. Each closed week is now a
          // block: a heading plus one labeled row per figure. Every
          // figure is kept; only the presentation changes, and a
          // missing figure still reads "not recorded", never $0.
          const relLabel = !rel ? 'Release' : rel.status === 'released' ? 'Released' : rel.status === 'pending' ? 'Pending release' : 'Held';
          const relCents = !rel ? null : rel.status === 'released' ? (rel.released_cents ?? rel.surplus_cents) : rel.surplus_cents;
          const relValue = (relCents === null || relCents === undefined) ? 'not recorded' : formatCents(relCents);
          const carryIn = carryInByWeek.get(c.week_start);
          return `<li class="week-block"><strong>${fmtLong(c.week_start)}</strong><div class="week-metrics"><div><span>Carry-in</span><span>${carryIn === null ? 'not recorded' : fmtOrMissing(carryIn)}</span></div><div><span>Surplus</span><span>${fmtOrMissing(c.surplus_cents)}</span></div><div><span>Debt carried out</span><span>${fmtOrMissing(c.outgoing_debt_cents)}</span></div><div><span>${relLabel}</span><span>${relValue}</span></div></div></li>`;
        }).join('')
      : `<li class="muted small">${(historyFilter.from || historyFilter.to) ? 'No closed weeks in the selected period.' : 'No closed weeks yet.'}</li>`;
  } catch (e) {
    console.warn('week history read failed:', e);
    const wh = $('weekHistoryList'); if (wh) wh.innerHTML = '<li class="error">Could not load week history. Try again.</li>';
  }

  showView(currentView, { preserveScroll: true });
  // Delta B1: unfiltered activity pages by auditLimit (Load more
  // raises it); a filtered view fetches up to 1000 newest rows so
  // the period is not silently cut off by the page size.
  const auditFetchLimit = (historyFilter.from || historyFilter.to) ? 1000 : auditLimit;
  const { data: auditRows, error: auditErr } = await supabase.from('audit_log')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(auditFetchLimit);
  if (auditErr) console.warn('audit_log read failed:', auditErr.message);
  let auditTotal = null;
  try {
    const { count } = await supabase.from('audit_log').select('created_at', { count: 'exact', head: true }).eq('household_id', household.household_id);
    if (Number.isInteger(count)) auditTotal = count;
  } catch (e) { /* count unavailable; the list still renders */ }
  const filteredAudit = filterRowsByDate(auditRows ?? [], (a) => a.created_at, historyFilter.from, historyFilter.to);
  // Delta B1: the count line covers the full data set (totals from
  // the count queries), never just the page that was downloaded.
  // Task 1: the count line only changes meaning when a filter is
  // active or a list is empty; unfiltered and non-empty it is
  // redundant ("0 shown of 0 total" style noise) and stays blank.
  const countLine = $('historyCountLine');
  if (countLine && !auditErr) {
    const filterActive = !!(historyFilter.from || historyFilter.to);
    const listsEmpty = lastWeekHistoryShown.shown === 0 && filteredAudit.length === 0;
    if (filterActive || listsEmpty) {
      const weekPart = `Closed weeks: ${lastWeekHistoryShown.shown} shown${lastWeekHistoryShown.total !== null ? ` of ${lastWeekHistoryShown.total} total` : ''}`;
      const auditPart = `Activity: ${filteredAudit.length} shown${auditTotal !== null ? ` of ${auditTotal} total` : ''}`;
      countLine.textContent = `${weekPart} · ${auditPart}`;
    } else {
      countLine.textContent = '';
    }
  }
  const loadMoreHistory = $('historyLoadMoreBtn');
  if (loadMoreHistory) {
    const moreRemains = auditTotal !== null ? filteredAudit.length < auditTotal : (auditRows ?? []).length >= auditFetchLimit;
    loadMoreHistory.classList.toggle('hidden', !!auditErr || !(historyFilter.from || historyFilter.to ? false : moreRemains));
  }
  // R10: Activity is the secondary view, grouped by day (newest day
  // first), instead of one flat list. Locked snapshots are never
  // recomputed here — this only re-presents the audit rows.
  $('auditList').innerHTML = auditErr
    ? '<li class="error">Could not load history. Try again.</li>'
    : filteredAudit.length
    ? (() => {
        const groups = new Map();
        for (const a of filteredAudit) {
          const day = new Date(a.created_at);
          const key = isNaN(day) ? 'Unknown date' : day.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
          if (!groups.has(key)) groups.set(key, []);
          groups.get(key).push(a);
        }
        let html = '';
        for (const [day, rows] of groups) {
          html += `<li class="muted small"><strong>${esc(day)}</strong></li>`;
          // UX audit 09 / owner screenshot: repeated weekly-processing
          // rows collapse into one line with a count (e.g. "Weeks
          // processed ×3"); user actions never collapse, even when
          // two look identical, because they may be distinct events.
          const grouped = groupDayActivity(rows.map((a) => ({
            action: formatAuditAction(a.action),
            detail: formatAuditDetail(a.detail),
            actor: formatAuditActor(a.actor_name),
            time: fmtDateTime(a.created_at),
          })));
          // Send-live-bundle, activity timeline: a small coloured
          // dot per type, short bold title, one plain line, muted
          // time + Admin/Member (formatAuditActor, never raw
          // usernames). A collapsed "Weeks processed ×N" group
          // reads as "N weeks closed" via activityTitle.
          html += grouped.map((g) => {
            const title = activityTitle(g.action, g.count);
            const dot = activityDotClass(g.action, g.detail);
            return `<li class="activity-item"><span class="activity-dot activity-dot-${dot}" aria-hidden="true"></span><span><strong>${esc(title)}</strong><br>${esc(g.detail)}<br><span class="muted">${esc(g.actor)} · ${esc(g.time)}</span></span></li>`;
          }).join('');
        }
        // Task 1: with a filter active the period line above already
        // states the period, so no trailing "Showing entries…" line.
        return html + ((historyFilter.from || historyFilter.to)
          ? ''
          : (auditTotal !== null && filteredAudit.length < auditTotal)
          ? '<li class="muted small">More entries exist — tap Load more below.</li>'
          : '');
      })()
    : `<li>${(historyFilter.from || historyFilter.to) ? 'No entries in the selected period.' : 'No audit entries yet.'}</li>`;
  } finally {
    // A failed read must not blank the page: showView already ran in
    // boot(), and re-running it here guarantees the sections stay
    // visible with their own inline errors, even if a read threw
    // before the in-try showView call. No data logic changes here.
    try { if (household) showView(currentView, { preserveScroll: true }); } catch (e) { /* sections stay as boot left them */ }
    // Task 4 fallback: if anything during the refresh did scroll
    // (e.g. a list that shrank below the old position), put the
    // page back. The browser clamps to the new page height when
    // the list got shorter, which lands the user as close as
    // possible to where they were.
    try { window.scrollTo(0, savedScrollY); requestAnimationFrame(() => window.scrollTo(0, savedScrollY)); } catch (e) { /* scroll restore is best-effort */ }
    refreshInFlight = Math.max(0, refreshInFlight - 1);
    // Task 6: no footer state to clear here — the footer shows the
    // last bank sync time only, on success, on failure, and on a
    // hung refresh alike.
  }
}

async function boot() {
  const { data: { session: s } } = await supabase.auth.getSession();
  session = s;
  if (!session) { await show('auth'); return; }
  household = await loadMembership();
  if (!household) { await show('household'); return; }
  await show('app');
  // UX-review-fix, blank shell (owner screenshot Nov 3, 7:48 PM):
  // #view-app > .card starts display:none in CSS and showView() is
  // what turns sections on. It used to run only late inside
  // refresh(), after every read, so a slow or hanging boot showed
  // the bare shell — topbar, nav, footer, empty white main — and a
  // throw before it left the page blank with only console warnings.
  // Show the current view NOW, so the cards with their existing
  // "Loading…" placeholders appear instantly; refresh() then fills
  // them in, and its finally block re-runs showView even on failure.
  showView(currentView);
  // Gmail OAuth return: the callback redirects back here with
  // ?gmail=connected or ?gmail=failed. The param only picks the
  // message (server truth on refresh decides what the card shows);
  // it is cleared so a later refresh does not re-toast.
  try {
    const g = new URLSearchParams(window.location.search).get('gmail');
    if (g === 'connected' || g === 'failed') {
      showToast(g === 'connected'
        ? 'Email connected — the app will check it for Amex alerts.'
        : 'Email connection didn\'t go through — try again from Funds.', g === 'failed');
      const u = new URL(window.location.href); u.searchParams.delete('gmail');
      window.history.replaceState(null, '', u.pathname + u.search + u.hash);
    }
  } catch (e) { /* ignore malformed URLs */ }
  await refresh();
  // Task 5: on a fresh load the refresh above starts at scroll 0,
  // so Task 4's in-refresh restore cannot know where the user was.
  // Restore the saved position for this page now, once, after the
  // first render. On a first-ever load there is no saved position
  // and the page stays at the top, as before.
  try {
    const saved = Number(localStorage.getItem(scrollStorageKey(currentView)));
    if (Number.isFinite(saved) && saved > 0) requestAnimationFrame(() => window.scrollTo(0, saved));
  } catch (e) { /* scroll restore is best-effort */ }
}

$('forgotPasswordBtn')?.addEventListener('click', async () => {
  let email = ($('authEmail')?.value ?? '').trim();
  if (!email) {
    const typed = await showSheet({ title: 'Forgot password?', message: 'Step 1: enter the email for your account. Step 2: check your inbox for the reset link. Step 3: choose a new password on that page, then return here to sign in. If the link has expired, send a fresh one from here.', inputLabel: 'Email', inputType: 'email', confirmLabel: 'Send reset link', cancelLabel: 'Cancel' });
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
  // Delta3: the sync-button busy pattern, extended to sign-in —
  // disable + progress label while signing in, then the loading
  // screen (never the app shell) while boot() restores the session.
  const btn = $('signInBtn');
  if (btn) { btn.disabled = true; btn.textContent = 'Signing in…'; }
  const { error } = await supabase.auth.signInWithPassword({
    email: $('authEmail').value.trim(), password: $('authPassword').value,
  });
  if (error) console.warn('sign-in failed:', error.message);
  // Privacy-safe generic error, plus a direct recovery action: the
  // Forgot password? button sits below this message on the form.
  $('authMsg').textContent = error ? 'Could not sign in. Check your email and password and try again. If you forgot the password, use Forgot password? below to reset it.' : 'Signed in.';
  if (!error) await show('loading');
  await boot();
  if (btn) { btn.disabled = false; btn.textContent = 'Sign in'; }
});
// ---- Live CSV import (Transactions tab), registered at top level so
// it works after a plain reload, not only after an in-page sign-in
// (Nov 3 fix round: it used to live inside the sign-in handler).
// Port of the demo parser. NOTHING is inserted on file pick: the file is
// parsed, previewed with duplicate-skip counts, and inserted ONLY after
// the user taps Confirm. Inserts are source='csv', state='provisional'
// (member inserts are constrained to manual/csv + provisional by S1 SQL).
$('csvFile')?.addEventListener('change', async (e) => {
  const file = e.target.files[0];
  const fileNameEl = $('csvFileName'); if (fileNameEl) fileNameEl.textContent = file ? file.name : 'No file selected';
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
    + `<ul class="plain">${previewRows.map((r, i) => `<li class="csv-row${r.isDupe ? ' csv-dupe' : ''}">${i + 1}. ${esc(r.date)} \u00b7 ${esc(r.merchant)} \u00b7 ${formatCents(r.amountCents)} \u00b7 \u2022\u2022${esc(r.suffix)} \u2014 ${r.isDupe ? 'Duplicate, will be skipped' : 'New'}</li>`).join('')}</ul>`;
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
  // Add popup member gate (owner design Nov 3, 9:49 PM: members get
  // Purchase only): a member reaching the import form any other way
  // is refused here, before any row is inserted.
  if (!(household && household.role === 'admin')) { showToast('Only the admin can import transactions.'); return; }
  const msg = $('csvMsg');
  if (!pendingCsvRows.length) { showToast('Nothing new to import.'); return; }
  // R1 busy control: block repeat taps while the import is inserting.
  const confirmBtnTop = $('csvConfirmBtn'); if (confirmBtnTop) confirmBtnTop.disabled = true;
  const rows = pendingCsvRows;
  const inserts = [];
  for (const r of rows) {
    const hash = await sha(`${r.date}|${normalizeMerchant(r.merchant)}|${r.amountCents}|${r.suffix}`);
    inserts.push({ household_id: household.household_id, date: r.date, merchant: r.merchant,
      amount_cents: r.amountCents, card_suffix: r.suffix, source: 'csv', state: 'provisional',
      kind: classifyCsvKind(r.merchant, r.amountCents), dedupe_hash: hash });
  }
  const { data, error } = await supabase.from('transactions').insert(inserts).select('id');
  if (error) { console.warn('csv insert failed:', error.message); showToast('Could not import. Nothing was claimed as imported — try again.', true); if (confirmBtnTop) confirmBtnTop.disabled = false; return; }
  const added = data?.length ?? rows.length;
  await audit('CSV import', `${added} added, ${rows.length - added} not inserted.`);
  pendingCsvRows = [];
  const fileEl = $('csvFile'); if (fileEl) fileEl.value = '';
  const confirmBtn = $('csvConfirmBtn'); if (confirmBtn) confirmBtn.disabled = true;
  const preview = $('csvPreview'); if (preview) preview.innerHTML = '';
  if (msg) msg.textContent = '';
  showToast(`Imported ${added} transaction(s) as provisional.`);
  setAddForm(null);
  await refresh();
});
// Auth-card-cleanup (owner, Nov 4, 2026): the sign-in password toggle
// is a standard eye icon sitting INSIDE the field (see #view-auth
// .password-row in styles.css), not Show/Hide text beside it. The
// icon swaps with the state; aria-label and aria-pressed carry the
// meaning, exactly as the text toggle did. The change-password sheet
// keeps its own text toggle — this handler is sign-in only.
const eyeOpenSvg = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>';
const eyeSlashSvg = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/><line x1="2" y1="2" x2="22" y2="22"/></svg>';
$('togglePasswordBtn')?.addEventListener('click', (e) => {
  const input = $('authPassword'); if (!input) return;
  const showing = input.type === 'password';
  input.type = showing ? 'text' : 'password';
  e.currentTarget.innerHTML = showing ? eyeSlashSvg : eyeOpenSvg;
  e.currentTarget.setAttribute('aria-label', showing ? 'Hide password' : 'Show password');
  e.currentTarget.setAttribute('aria-pressed', showing ? 'true' : 'false');
});
// Auth-card-cleanup, two-step sign-up (owner correction, Nov 4,
// 2026): the Name field does NOT sit on the sign-in card. Create
// account on the card only validates Email + Password, then moves
// to a separate name step (authNamePanel) inside view-auth —
// implemented as a panel toggle, not a new show() view, so boot()
// routing is untouched and Email/Password values survive (same
// DOM, nothing clears them). Only the name step calls signUp, and
// only with a non-empty name, so abandoning the step creates no
// account. Sign-in never shows the name step.
const showAuthPanel = (which) => {
  $('authSigninPanel')?.classList.toggle('hidden', which !== 'signin');
  $('authNamePanel')?.classList.toggle('hidden', which !== 'name');
};
$('signUpBtn').addEventListener('click', async () => {
  // Audit-merge fix (audit A finding 6): name the missing field
  // before moving on, instead of a generic failure. The 8-character
  // minimum is surfaced, not changed. No Supabase call happens here.
  const fail = (msg, field) => { $('authMsg').textContent = msg; if (field) field.focus(); };
  const signEmail = $('authEmail'); const signPw = $('authPassword');
  if (!signEmail?.value.trim()) { fail('Enter an email address to create an account.', signEmail); return; }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(signEmail.value.trim())) { fail('Enter a valid email address.', signEmail); return; }
  if (!signPw?.value) { fail('Enter a password of at least 8 characters.', signPw); return; }
  if (signPw.value.length < 8) { fail('Password must be at least 8 characters.', signPw); return; }
  $('authNameMsg').textContent = '';
  showAuthPanel('name');
  $('authName')?.focus();
});
$('authNameBackBtn')?.addEventListener('click', () => {
  // Back to the sign-in card with Email/Password intact (same DOM).
  showAuthPanel('signin');
  $('signUpBtn')?.focus();
});
$('authNameCreateBtn').addEventListener('click', async () => {
  // Delta3: same busy pattern as sign-in.
  const btn = $('authNameCreateBtn');
  if (btn) { btn.disabled = true; btn.textContent = 'Creating account…'; }
  const fail = (msg, field) => { $('authNameMsg').textContent = msg; if (field) field.focus(); if (btn) { btn.disabled = false; btn.textContent = 'Create account'; } };
  const signEmail = $('authEmail'); const signPw = $('authPassword'); const signName = $('authName');
  // Sign-up name requirement (owner, Nov 3, ~11:22 PM): a new
  // account must set a name, so the profile header has a display
  // name immediately. Empty name fails here, before any Supabase
  // call, with a named error and focus on the Name field. Sign-in
  // ignores the Name field entirely.
  if (!signName?.value.trim()) { fail('Enter a name for your new account.', signName); return; }
  const { error } = await supabase.auth.signUp({
    email: signEmail.value.trim(), password: signPw.value,
    options: { data: { full_name: signName.value.trim() } },
  });
  if (error) console.warn('sign-up failed:', error.message);
  $('authNameMsg').textContent = error ? 'Could not create the account. Try again.' : 'Account created. If email confirmation is on in Auth settings, confirm the email first, then sign in.';
  if (!error) await show('loading');
  if (!error) await boot();
  if (btn) { btn.disabled = false; btn.textContent = 'Create account'; }
});
$('signOutBtn').addEventListener('click', async () => {
  await supabase.auth.signOut(); household = null;
  // Do not leave credentials filled in on a shared device.
  if ($('authEmail')) $('authEmail').value = '';
  if ($('authPassword')) $('authPassword').value = '';
  // Auth-card-cleanup: a sign-out always lands back on the sign-in
  // panel, never stranded on the name step, with the name cleared.
  if ($('authName')) $('authName').value = '';
  showAuthPanel('signin');
  // Household naming: same reset for the household choice page.
  if ($('householdNameInput')) $('householdNameInput').value = '';
  showHouseholdPanel('choice');
  await show('auth');
});
// No header Refresh button anymore: tapping a tab refreshes.

// Household naming (owner, Nov 4, 2026): creating a household is
// two panels — choice, then an optional naming step. The choice
// button no longer calls the RPC; the naming step's button does.
// The join path is untouched and never sees the naming step.
const showHouseholdPanel = (which) => {
  $('householdChoicePanel')?.classList.toggle('hidden', which !== 'choice');
  $('householdNamePanel')?.classList.toggle('hidden', which !== 'name');
};
$('createHouseholdBtn').addEventListener('click', async () => {
  $('householdNameMsg').textContent = '';
  showHouseholdPanel('name');
  $('householdNameInput')?.focus();
});
$('householdNameBackBtn')?.addEventListener('click', () => {
  showHouseholdPanel('choice');
  $('createHouseholdBtn')?.focus();
});
$('householdNameCreateBtn').addEventListener('click', async () => {
  const btn = $('householdNameCreateBtn');
  if (btn) { btn.disabled = true; btn.textContent = 'Creating…'; }
  // Household creation is server-side only — but NOT via the Edge
  // Function anymore. The bootstrap-household function failed on Nov 1
  // (HTTP 500, valid JWT, service-role insert failed) because it reads
  // the deprecated legacy SUPABASE_SERVICE_ROLE_KEY, which this project
  // no longer provisions with a working value. The fix is the
  // create_household() SECURITY DEFINER RPC: it runs as the database
  // owner, acts only for auth.uid(), refuses if the caller already has
  // a household, and needs no secret key at all. The client must still
  // never grant itself admin directly — this RPC is the only path.
  // Naming: the name is OPTIONAL. A blank name passes NO p_name
  // argument, so both the old no-arg RPC and the new
  // create_household(p_name) (supabase/create-household-name.sql,
  // NOT yet applied — owner review first) create the default
  // 'Household'. A supplied name passes p_name, which requires the
  // new SQL; on the old RPC that call fails and the existing error
  // message shows — never a silent fallback through another path.
  const rawName = $('householdNameInput')?.value.trim() ?? '';
  const name = rawName.slice(0, 80);
  const args = name ? { p_name: name } : {};
  const { data, error } = await supabase.rpc('create_household', args);
  if (error) console.warn('create_household failed:', error.message);
  $('householdNameMsg').textContent = data
    ? 'Household created. Share the invite code from Settings so the second account can join as member.'
    : 'Could not create household. Try again.';
  // FIX (Nov 1, evening — reproduced by the beta test): do NOT re-read
  // the membership here. boot()'s loadMembership() returned null right
  // after creation (the RPC had just committed), so the app stayed on
  // the household screen until the user hit Refresh. The RPC already
  // proves the caller is the new household's admin, so set it directly
  // and go straight to the dashboard.
  if (data) {
    household = { household_id: data, role: 'admin' };
    // Leave the choice panel showing for any later return to this
    // page, with the name cleared.
    if ($('householdNameInput')) $('householdNameInput').value = '';
    showHouseholdPanel('choice');
    await show('app'); await refresh();
  }
  if (btn) { btn.disabled = false; btn.textContent = 'Create household'; }
});
$('joinHouseholdBtn').addEventListener('click', async () => {
  const btn = $('joinHouseholdBtn');
  const { data: { user } } = await supabase.auth.getUser();
  const code = $('joinId').value.trim();
  if (!user) { $('householdMsg').textContent = 'Sign in first.'; return; }
  if (!code) { $('householdMsg').textContent = 'Enter the invite code from the household owner.'; return; }
  if (btn) { btn.disabled = true; btn.textContent = 'Joining…'; }
  // Join takes an invite CODE, not a UUID. join_household_by_code returns
  // the household UUID, which the client stores for its own queries but
  // never displays or shares.
  const { data, error } = await supabase.rpc('join_household_by_code', { code });
  if (error) console.warn('join_household_by_code failed:', error.message);
  // A NULL return means the code was invalid (the function logs the
  // failed attempt and returns NULL instead of raising, so the log
  // survives — see supabase/n13-invite-rate-limit.sql). Treat it
  // exactly like the old exception: same generic message, no join.
  $('householdMsg').textContent = (error || !data) ? 'Join failed. Check the invite code and try again, or ask the household owner to share it again from Settings.' : 'Joined. Loading shared budget…';
  if (!error && data) { household = { household_id: data, role: 'member' }; await show('app'); await refresh(); }
  if (btn) { btn.disabled = false; btn.textContent = 'Join as member'; }
});

let manualSubmitting = false;
$('manualForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  // Double-tap guard (Nov 3 fix round): the duplicate check below
  // awaits a network call, so disabling the button only after it
  // cannot stop two rapid taps landing two rows. Disable first.
  if (manualSubmitting) return;
  manualSubmitting = true;
  const f = e.target;
  const submitBtn = f.querySelector('button[type="submit"]');
  if (submitBtn) submitBtn.disabled = true;
  const done = () => { manualSubmitting = false; if (submitBtn) submitBtn.disabled = false; };
  // UX-review-fix: field errors sit beside the form (inline, above
  // the buttons), not in a popup — so the user sees which field to
  // fix without losing the draft. The duplicate warning stays a
  // dialog because it is a decision, not a field error.
  const fieldErr = document.getElementById('manualFormError');
  const setFieldError = (msg, field) => { if (fieldErr) { fieldErr.textContent = msg; fieldErr.classList.remove('hidden'); } if (field) field.focus(); };
  if (fieldErr) fieldErr.classList.add('hidden');
  const amount = parseDollarsStrict(f.amount.value);
  if (amount === null || amount <= 0) { done(); setFieldError('Amount: enter a positive amount.', f.amount); return; }
  const suffix = f.suffix.value.trim();
  if (!/^\d{4}$/.test(suffix)) { done(); setFieldError('Card suffix: enter exactly 4 digits. Never enter a full card number.', f.suffix); return; }
  // Audit-merge fix (audit A finding 6): the date input is required,
  // so without novalidate the browser's own bubble was the only
  // feedback and this handler never ran for an empty date. The form
  // is now novalidate, so the merchant check below is the guard the
  // native required attribute used to provide for that field.
  if (!f.merchant.value.trim()) { done(); setFieldError('Merchant: enter a name for this transaction.', f.merchant); return; }
  if (!f.date.value) { done(); setFieldError('Date: pick the date of this transaction.', f.date); return; }
  const merchant = f.merchant.value.trim().toUpperCase();
  // Smarter entry: warn on an apparent duplicate instead of silently
  // creating a second copy of the same transaction.
  const { data: dupes } = await supabase.from('transactions')
    .select('merchant, amount_cents, date').eq('household_id', household.household_id)
    .eq('merchant', merchant).eq('amount_cents', amount).eq('date', f.date.value).limit(1);
  if ((dupes ?? []).length && !(await showConfirm('Possible duplicate', `A transaction already exists for ${merchant} ${formatCents(amount)} on ${fmtLong(f.date.value)}. Add it again anyway?`, 'Add anyway'))) { done(); return; }
  const hash = await sha(`${f.date.value}|${merchant}|${amount}|${suffix}`);
  const { error } = await supabase.from('transactions').insert({
    household_id: household.household_id, date: f.date.value, merchant,
    amount_cents: amount, card_suffix: suffix, source: 'manual',
    state: 'provisional', kind: 'charge', dedupe_hash: hash,
  });
  if (error) { console.warn('manual insert failed:', error.message); await showAlert('Could not save', 'Could not save this transaction. Try again.'); done(); return; }
  await audit('Transaction added by hand', `${merchant} ${formatCents(amount)} on ${fmtLong(f.date.value)} (••${suffix}).`);
  f.reset(); setAddForm(null); done(); await refresh();
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
  // Excluded-decisions (a) pre-Link warning: if the household already
  // has an ACTIVE connection, list it and warn that connecting the
  // same account again creates a duplicate. Cancel is the safe path
  // (the sheet's Cancel button comes first); only an explicit
  // "Connect anyway" proceeds. A failed read fails OPEN — it must
  // never block a first or legitimate connection.
  try {
    const { data: activeItems } = await supabase.from('plaid_items_public')
      .select('plaid_item_id, institution_name').eq('household_id', household.household_id).eq('status', 'active');
    if (activeItems && activeItems.length) {
      const { data: activeAccts } = await supabase.from('plaid_accounts')
        .select('plaid_item_id, name, mask').in('plaid_item_id', activeItems.map((i) => i.plaid_item_id));
      const lines = activeItems.map((item) => describeConnection(item, (activeAccts ?? []).filter((a) => a.plaid_item_id === item.plaid_item_id)));
      const proceed = await showConfirm('Already connected?', `You already have ${activeItems.length === 1 ? 'this bank connection' : 'these bank connections'}:\n${lines.join('\n')}\n\nConnecting the same account again will create a duplicate. You do not need to reconnect an account that is already syncing — only continue if you are connecting a different account.`, 'Connect anyway');
      if (!proceed) return;
    }
  } catch (e) { console.warn('duplicate-warning read failed, proceeding:', e); }
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

// Delta B3: one bank sync at a time. A repeat tap while a sync runs
// is ignored, and both sync buttons show progress (disabled, and the
// Home icon spins) until the sync finishes — the toast alone is not
// enough. The guard releases in finally, so a failed sync never
// leaves the buttons stuck.
async function runBankSync() {
  if (!syncGuard.tryStart()) return { skipped: true };
  const syncBtn = $('syncBankBtn');
  const homeBtn = $('homeSyncBtn');
  const savedSyncText = syncBtn ? syncBtn.textContent : '';
  if (syncBtn) { syncBtn.disabled = true; syncBtn.textContent = 'Syncing…'; }
  if (homeBtn) { homeBtn.disabled = true; homeBtn.classList.add('syncing'); homeBtn.setAttribute('aria-label', 'Syncing bank'); }
  try {
    showToast('Syncing bank transactions…');
    const out = await callFn('plaid-sync', { household_id: household.household_id });
    const text = out.error
      ? `Sync failed: ${out.error}`
      : `Sync done: ${out.added ?? 0} added, ${out.updated ?? 0} updated, ${out.skipped ?? 0} skipped across ${out.items ?? 0} connected account(s).${(out.duplicate_removed ?? []).length ? ` A duplicate bank connection was removed because those accounts are already connected on another connection. Past transactions stay.` : ''}`;
    showToast(text, !!out.error);
    // No localStorage sync/connection state: refresh() re-reads last_sync_at
    // from plaid_items, which is the server truth.
    return out;
  } finally {
    if (syncBtn) { syncBtn.disabled = false; syncBtn.textContent = savedSyncText; }
    if (homeBtn) { homeBtn.disabled = false; homeBtn.classList.remove('syncing'); homeBtn.setAttribute('aria-label', 'Sync bank'); }
    syncGuard.finish();
  }
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
    : 'Automatic sync enabled. New transactions will be pulled in on your next refresh.', failed.length > 0);
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
  purchases: ['section-manual', 'section-csv', 'section-charity-gift', 'section-transactions', 'section-history-filter', 'section-week-history', 'section-activity'],
  money: ['section-fund-balances', 'section-fund-more', 'section-fund-activity-more', 'section-fund-review-more', 'section-savings-more', 'section-fund-add', 'section-charity-income', 'section-fund-use', 'section-fund-ask'],
  // R2: Settings is reached from the profile menu, not a nav tab.
  // Connections (bank + email), Budget (allowance + temp increase)
  // and Account & household live here; Funds no longer shows them.
  settings: ['section-settings-head', 'section-profile', 'section-bank', 'section-email', 'settingsCard', 'section-settings-account'],
  activity: ['section-history-filter', 'section-week-history', 'section-activity'],
};
const ALL_VIEW_SECTIONS = Object.values(VIEWS).flat();
let currentView = resolveRestoredView(localStorage.getItem('hb-view'), null);
// Task 5: Settings IS persisted now (hb-view), so a reload from
// Settings restores Settings instead of Home. previousView (the
// page Settings Back returns to) persists separately in hb-prev-view;
// without it, Back after a reload falls back to Home.
let previousView = resolveRestoredView(localStorage.getItem(PREV_VIEW_STORAGE_KEY), null);
// R7: which Add state is open on the Transactions screen:
// null = list only (choice card hidden by default, UX-review-fix),
// 'choice' = choice card, 'manual' = hand form, 'csv' = import form.
let addFormOpen = null;
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
  // Task 5: save the outgoing page's scroll position before leaving
  // it, so a later reload can restore it (see boot()). Task 4: a
  // refresh never changes the page, so it must never scroll it.
  if (name !== currentView) {
    try { localStorage.setItem(scrollStorageKey(currentView), String(window.scrollY || 0)); } catch (e) { /* private mode */ }
  }
  // Record only the view left when entering Settings, so Back
  // returns there even after tab taps in between.
  if (name === 'settings' && currentView !== 'settings') {
    previousView = currentView;
    try { localStorage.setItem(PREV_VIEW_STORAGE_KEY, previousView); } catch (e) { /* private mode */ }
  }
  currentView = name;
  try { localStorage.setItem(VIEW_STORAGE_KEY, name); } catch (e) { /* private mode */ }
  // Success/error messages do NOT persist across tabs: a user-initiated
  // tab switch clears every in-app result message (refresh() calls
  // showView without opts, so messages set during a refresh survive).
  if (opts.clearMessages) {
    // Clear TRANSIENT messages only (by id) — never content lists such as
    // savingsList, savingsSummary, or the CSV preview, which refresh()
    // only repopulates on a timed refresh.
    for (const id of ['bankMsg', 'homeSyncMsg', 'settingsMsg', 'tempMsg', 'fundAllocateMsg', 'csvMsg']) {
      const el = document.getElementById(id); if (el) el.textContent = '';
    }
    hideToast();
    document.getElementById('weekError')?.classList.add('hidden');
    // A tab tap also closes the Transactions filter sheet (a plain
    // refresh does not, so editing filters survives live updates).
    document.getElementById('txFiltersSheet')?.classList.add('hidden');
    document.getElementById('txFiltersToggle')?.setAttribute('aria-expanded', 'false');
    syncScrollLock();
  }
  for (const id of ALL_VIEW_SECTIONS) {
    const el = document.getElementById(id);
    if (!el) continue;
    if (!VIEWS[name].includes(id)) { el.style.display = 'none'; continue; }
    if (id === 'settingsCard' || id === 'section-fund-add' || id === 'section-charity-income' || id === 'section-fund-use' || id === 'section-fund-review-more') { el.style.display = (household && household.role === 'admin') ? 'block' : 'none'; continue; }
    el.style.display = id === 'section-stats' ? 'grid' : 'block';
  }
  // Task 7 (owner, Nov 4, Option A): the Funds actions card, Review
  // card, and Past savings card are gone as cards. Their functions
  // live on: the three fund actions moved into the Extra Fund sheet
  // (see openFundSheet), and Review / Fund activity / Past savings
  // are quiet › rows on one More card, each toggling its section
  // below (no ▶ triangles, no explainer sentences). The More card
  // shows when no form is open, like the old actions card; each
  // form shows only when chosen. Admin gating stays: members see
  // only the Ask action in the sheet and only the Past savings row
  // here (Fund activity and Review content are admin-only reads).
  if (name === 'money') {
    const isAdmin = household && household.role === 'admin';
    const more = document.getElementById('section-fund-more');
    if (more) more.style.display = fundFormOpen ? 'none' : 'block';
    const moreShown = (id, open, allowed) => {
      const el = document.getElementById(id);
      if (el) el.style.display = (fundFormOpen || !open || !allowed) ? 'none' : 'block';
    };
    moreShown('section-fund-activity-more', moreFundActivityOpen, isAdmin);
    moreShown('section-fund-review-more', moreReviewOpen, isAdmin);
    moreShown('section-savings-more', moreSavingsOpen, true);
    const formShown = (id, which) => {
      const el = document.getElementById(id);
      if (el) el.style.display = fundFormOpen === which ? 'block' : 'none';
    };
    if (isAdmin) {
      formShown('section-fund-add', 'add');
      formShown('section-fund-use', 'use');
      formShown('section-charity-income', 'income');
    }
    formShown('section-fund-ask', 'ask');
    const setBtn = (id, visible) => {
      const b = document.getElementById(id);
      if (b) b.style.display = visible ? '' : 'none';
    };
    setBtn('moreFundActivityBtn', !!isAdmin);
    setBtn('moreReviewBtn', !!isAdmin);
    setBtn('moreSavingsBtn', true);
    document.getElementById('moreFundActivityBtn')?.setAttribute('aria-expanded', moreFundActivityOpen ? 'true' : 'false');
    document.getElementById('moreReviewBtn')?.setAttribute('aria-expanded', moreReviewOpen ? 'true' : 'false');
    document.getElementById('moreSavingsBtn')?.setAttribute('aria-expanded', moreSavingsOpen ? 'true' : 'false');
  }
  // UX audit 10: Settings must not promise members a Budget section
  // they never see, and admin-only action buttons must not appear
  // for members. Bank connect/sync are already hidden in refresh();
  // this covers the remaining buttons (auto-sync, email connect /
  // check, invite sharing) and the intro line. Read-only status
  // lines stay visible, and server authorization is untouched —
  // hiding here is presentation only, the RPCs still enforce it.
  if (name === 'settings' && household) {
    const isAdmin = household.role === 'admin';
    const setBtn = (id, visible) => {
      const b = document.getElementById(id);
      if (b) b.style.display = visible ? '' : 'none';
    };
    setBtn('registerWebhookBtn', isAdmin);
    setBtn('connectEmailBtn', isAdmin);
    setBtn('pollEmailBtn', isAdmin);
    setBtn('settingsShareIdBtn', isAdmin);
    // Send-live-bundle: the Settings subtitle is deleted (see
    // live.html); there is no settingsIntro element left to update.
  }
  // R7 + UX-review-fix (owner screenshot Nov 3, 7:54 PM): Add is
  // HIDDEN by default on the Transactions page — the list is the
  // page. addFormOpen is now: null = list only, 'options' = the
  // Add options popup, 'manual'/'csv'/'charity' = that form in the
  // popup. The Transactions header's blue + button is the only
  // entry point (owner design Nov 3, 9:49 PM); Back from a form
  // returns to the options, Cancel/submit returns to the list.
// (addFormOpen states are documented here; the popup sync lives
  // with setAddForm below.)
  if (name === 'purchases') {
    syncAddPopup(name);
    const man = document.getElementById('section-manual');
    if (man) man.style.display = addFormOpen === 'manual' ? 'block' : 'none';
    const csv = document.getElementById('section-csv');
    if (csv) csv.style.display = addFormOpen === 'csv' ? 'block' : 'none';
    // R13: the gift form is admin-only at the server; the button is
    // hidden from members here so it never promises what it refuses.
    const gift = document.getElementById('section-charity-gift');
    if (gift) gift.style.display = addFormOpen === 'charity' ? 'block' : 'none';
  }
  document.querySelectorAll('[data-view]').forEach((b) => {
    b.classList.toggle('active', b.dataset.view === name);
    b.setAttribute('aria-pressed', b.dataset.view === name ? 'true' : 'false');
  });
  // Home sync button lives inside the hero card now (not its own
  // section above it): gate the button itself, admin-only.
  const homeSync = document.getElementById('homeSyncBtn');
  if (homeSync) homeSync.style.display = (household && household.role === 'admin') ? '' : 'none';
  // Task 4: refresh() re-renders the same page, so it passes
  // preserveScroll and must not jump to the top. A real page change
  // (tab tap, Settings Back, sheet "Show transactions") still
  // scrolls to the top, as before.
  if (!opts.preserveScroll) window.scrollTo(0, 0);
}
document.querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', (e) => {
  if (b.tagName === 'A') e.preventDefault();
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
  if (menu && !menu.classList.contains('hidden') && !menu.contains(e.target) && e.target.id !== 'profileBtn' && !document.getElementById('profileBtn')?.contains(e.target)) {
    menu.classList.add('hidden');
    document.getElementById('profileBtn')?.setAttribute('aria-expanded', 'false');
  }
});
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  const menu = document.getElementById('profileMenu');
  if (menu && !menu.classList.contains('hidden')) {
    menu.classList.add('hidden');
    const btn = document.getElementById('profileBtn');
    btn?.setAttribute('aria-expanded', 'false');
    btn?.focus();
  }
});
async function shareInviteCode() {
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
}
async function deleteAccountFlow() {
  document.getElementById('profileMenu')?.classList.add('hidden');
  if (!household) { await showAlert('Not signed in', 'Sign in first.'); return; }
  // TWO-STEP confirmation: "Delete account" then "Yes, delete everything".
  if (!(await showConfirm('Delete account', 'Delete your account and remove yourself from this household? If you are the last member, the household is deleted too. This cannot be undone.', 'Delete account'))) return;
  if (!(await showConfirm('Delete everything?', 'This permanently deletes your account and, if you are the last member, the whole household. Are you sure?', 'Yes, delete everything'))) return;
  const out = await callFn('delete-account', {});
  if (out.error || !out.deleted) {
    console.warn('delete-account failed:', out.error, out.step);
    // Surface the failing step (Round 3, bug 9): a generic error hid
    // a half-deleted account. Nothing is deleted on failure now —
    // the server restores the membership first.
    await showAlert('Could not delete account', `Could not delete your account. Nothing was deleted — try again.${out.step ? ` (step: ${out.step})` : ''}`);
    return;
  }
  await supabase.auth.signOut(); household = null;
  if ($('authEmail')) $('authEmail').value = '';
  if ($('authPassword')) $('authPassword').value = '';
  await show('auth');
  $('authMsg').textContent = 'Your account was deleted.';
}
async function changePasswordFlow() {
  document.getElementById('profileMenu')?.classList.add('hidden');
  if (!household) { await showAlert('Not signed in', 'Sign in first.'); return; }
  const pw = await showSheet({ title: 'Change password', message: 'Enter a new password for this account. Password requirement: at least 8 characters.', inputLabel: 'New password', inputType: 'password', confirmLabel: 'Change password', cancelLabel: 'Cancel' });
  if (!pw) return;
  if (pw.length < 8) { await showAlert('Password too short', 'Enter a password of at least 8 characters.'); return; }
  const { error } = await supabase.auth.updateUser({ password: pw });
  if (error) console.warn('password change failed:', error.message);
  await showAlert(error ? 'Could not change password' : 'Password changed', error ? 'Could not change your password. Try again.' : 'Your password is updated.');
}
document.getElementById('menuSettingsBtn')?.addEventListener('click', () => {
  document.getElementById('profileMenu')?.classList.add('hidden');
  showView('settings');
});
// Profile editing lives only in the Settings Profile card
// (owner, Nov 3, ~11:20 PM): the avatar menu has no Edit-profile
// row. The Settings row opens the Settings view, where the
// Profile card sits. Membership, roles, invite, and deletion logic
// are untouched.
document.getElementById('saveProfileNameBtn')?.addEventListener('click', async () => {
  const input = document.getElementById('profileNameInput');
  const name = input?.value.trim() ?? '';
  if (!name) { showToast('Enter a name to save.', true); input?.focus(); return; }
  const { error } = await supabase.auth.updateUser({ data: { full_name: name } });
  if (error) { console.warn('profile name save failed:', error.message); showToast('Could not save your name. Try again.', true); return; }
  // Menu header shows the first name only (see refresh()).
  const pn = document.getElementById('profileName'); if (pn) pn.textContent = name.split(/\s+/)[0] || name;
  // A name is now set, so the header no longer falls back to the
  // email — the email line below it must show (it was hidden by
  // the no-duplication rule while no name was set).
  document.getElementById('profileEmail')?.classList.remove('hidden');
  showToast('Name saved — it now shows in your profile.');
});
document.getElementById('saveProfileEmailBtn')?.addEventListener('click', async () => {
  const input = document.getElementById('profileEmailInput');
  const email = input?.value.trim() ?? '';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { showToast('Enter a valid email address.', true); input?.focus(); return; }
  const { data: { user } } = await supabase.auth.getUser();
  if (user?.email && email === user.email) { showToast('That is already your sign-in email.'); return; }
  // The confirmation copy sits on the Profile card before this
  // button: a confirmation goes to the NEW address, and the sign-in
  // email does not change until it is confirmed. The displayed email
  // is deliberately NOT changed here.
  const { error } = await supabase.auth.updateUser({ email });
  if (error) { console.warn('profile email save failed:', error.message); showToast('Could not change your email. Try again.', true); return; }
  showToast(`Confirmation sent to ${email} — your sign-in email stays as it is until you confirm it.`);
});
document.getElementById('profilePasswordBtn')?.addEventListener('click', changePasswordFlow);
document.getElementById('settingsShareIdBtn')?.addEventListener('click', shareInviteCode);
document.getElementById('settingsPasswordBtn')?.addEventListener('click', changePasswordFlow);
document.getElementById('settingsDeleteBtn')?.addEventListener('click', deleteAccountFlow);
document.getElementById('settingsBackBtn')?.addEventListener('click', () => showView(previousView || 'week'));
// R5 + R6: Home cards — tap a card for a focused titled bottom
// sheet over the stationary Home screen. Opening or closing a sheet
// writes nothing and triggers no sync; it only reads the numbers
// already loaded by refresh().
// Excluded-decisions: the Weekly sheet used to open from the small
// stat card; it now opens from the hero number (see the hero target
// handlers below). Same rows, same handler — no duplication.
async function openWeeklySheet() {
    const w = currentWeekData;
    if (!w) { await showAlert('Weekly Budget', 'Weekly numbers are not loaded yet. Try again in a moment.'); return; }
    // Weekly-custom (owner approval, Nov 4): the sheet contains
    // exactly three rows, in order — Allowance, Spent, Balance.
    // Allowance is the total spending room left after previous
    // weeks' debt: baseAvailable (base room) + temp, so Allowance
    // − Spent = Balance always, including a temp week (base room
    // + temp − spent = availableCents, the engine's Left). Spent is
    // the week's spent total; Balance is availableCents (old Left).
    const weeklyAllowanceCents = (w.baseAvailableCents ?? w.baseRoomCents ?? 0) + (w.tempCents ?? 0);
    const weeklyRows = [
      ['Allowance', formatCents(weeklyAllowanceCents)],
      ['Spent', formatCents(w.chargesCents)],
      ['Balance', formatCents(w.availableCents)],
    ];
    const weeklyResult = await showSheet({ title: 'Weekly Budget', rows: weeklyRows, extraAction: { label: 'Show transactions', result: 'show-transactions' }, confirmLabel: 'Close' });
    // Weekly-sheet-simple: "Show transactions" closes the sheet and
    // opens Transactions filtered to the current week, reusing the
    // existing week-filter state (txWeekOnly) and render path — the
    // count line gains "· this week" and the removable "This week"
    // pill makes the filter obvious. Other active filters are left
    // alone; the week filter combines with them as it always has.
    // Focus lands on the Filters button at the top of the
    // Transactions view (the sheet's own focus-return to the hero
    // is overridden here, since the user has moved views).
    if (weeklyResult === 'show-transactions') {
      txWeekOnly = true;
      showView('purchases');
      await refresh();
      document.getElementById('txFiltersToggle')?.focus();
    }
}
// Hero number as the Weekly breakdown target. The hero already has a
// Sync button in its head row, so the number area — not the whole
// hero card — is the target: no button nested inside a button, and
// the Sync button keeps working on its own. Keyboard: Enter/Space.
const heroWeeklyTarget = document.getElementById('weeklyAvailable');
heroWeeklyTarget?.addEventListener('click', openWeeklySheet);
heroWeeklyTarget?.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openWeeklySheet(); }
});
// Funds-actions-three (owner choice, Nov 4, Option A): Record income
// moved out of the Funds actions card into the Charity breakdown
// sheet, admin-only. It is a charity action, not a fund action, so
// the actions card drops to exactly three buttons (Add / Use / Ask).
// Both charity sheets (Home card and Funds panel) share this opener.
// The Weekly sheet's extraAction precedent is reused: Record income
// renders primary, Close second; choosing it closes the sheet and
// then opens the existing Record income form via setFundForm('income').
// Members get no extra action, so the sheet renders exactly as before.
async function openCharitySheet() {
  const c = currentCharityData;
  if (!c) { await showAlert('Charity', 'Charity numbers are not loaded yet. Try again in a moment.'); return; }
  const isAdmin = household && household.role === 'admin';
  const result = await showSheet({ title: 'Charity · November 2026 onward', rows: charityBreakdownRows(c), extraAction: isAdmin ? { label: 'Record income', result: 'record-income' } : null, confirmLabel: 'Close' });
  if (result === 'record-income') setFundForm('income');
}
// Task 7: the Extra Fund sheet. From the Funds panel (withActions)
// it carries the three fund actions in their original order and
// treatments (Add primary, Use pale, Ask grey; members see Ask
// only) and opens the chosen form after the sheet closes. From the
// Home stat card it stays the read-only breakdown, as before.
async function openFundSheet(withActions) {
  const f = currentFundData;
  if (!f) { await showAlert('Extra Fund', 'Fund balances are not loaded yet. Try again in a moment.'); return; }
  const isAdmin = household && household.role === 'admin';
  const actions = !withActions ? null : isAdmin
    ? [
        { label: 'Add money', result: 'add', btnClass: 'btn btn-primary' },
        { label: 'Use fund money', result: 'use', btnClass: 'btn' },
        { label: 'Ask for fund money', result: 'ask', btnClass: 'btn btn-tertiary' },
      ]
    : [{ label: 'Ask for fund money', result: 'ask', btnClass: 'btn btn-tertiary' }];
  const result = await showSheet({ title: 'Extra Fund', rows: fundBreakdownRows(f), actions, confirmLabel: 'Close' });
  if (result === 'add') setFundForm('add');
  else if (result === 'use') setFundForm('use');
  else if (result === 'ask') setFundForm('ask');
}
document.querySelectorAll('[data-home-card]').forEach((el) => el.addEventListener('click', async () => {
  const kind = el.dataset.homeCard;
  if (kind === 'fund') {
    await openFundSheet(false);
  } else {
    await openCharitySheet();
  }
}));
// Button-card-fix: the labeled rows for the Extra Fund and Charity
// breakdown sheets. These are the SINGLE source for both the Home
// stat-card sheets and the Funds balance-card sheets, so a line moved
// off a Funds card face cannot go missing from either sheet.
// Fund sheet (owner, Nov 4): exactly three rows — Available, Pending
// (pending releases PLUS held weeks: everything not yet available),
// Total (Available + Pending). Released total, Spent from fund,
// Owed back, and the Held-for-review row were removed from this
// sheet; Review queue access stays on the Funds page (Review card).
function fundBreakdownRows(f) {
  const pending = (f.pending ?? 0) + (f.heldTotal ?? 0);
  return [
    [household.role === 'admin' ? 'Spendable available' : 'Available to request', formatCents(f.available)],
    ['Pending', formatCents(pending)],
    ['Total', formatCents(f.available + pending)],
  ];
}
function charityBreakdownRows(c) {
  // Charity sheet (owner, Nov 4): exactly three rows — Available
  // (remaining, signed, so the rows add up), Given, Total (Available
  // + Given = the old Committed). Committed, Default rate, and Period
  // rows were removed; the period stays in the sheet title and the
  // default rate stays on the Funds "Charity income & rate" card.
  return [
    ['Available', formatCents(c.remaining)],
    ['Given', formatCents(c.given)],
    ['Total', formatCents(c.remaining + c.given)],
  ];
}
// Button-card-fix: Funds balance cards — tap the whole card (click,
// Enter, or Space) for the same breakdown sheet as the Home card.
// The chevron at the bottom-right of the card, facing down, marks
// it as tappable (more below, not a link to another page). Opening or
// closing a sheet writes nothing and triggers no sync; it only reads
// the numbers already loaded by refresh().
document.querySelectorAll('[data-fund-card]').forEach((el) => {
  const open = async () => {
    const kind = el.dataset.fundCard;
    if (kind === 'fund') {
      await openFundSheet(true);
    } else {
      await openCharitySheet();
    }
  };
  el.addEventListener('click', open);
  el.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); } });
});
// HTML form of an amount with smaller cents, for the hero and stat
// numbers only (formatCents from the engine stays the plain-text form
// used in search, messages, and audit text).
function formatCentsHtml(cents) {
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(cents);
  return `${sign}$${Math.floor(abs / 100).toLocaleString('en-US')}<span class="cents">.${String(abs % 100).padStart(2, '0')}</span>`;
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
  // Send-live-bundle, jargon display-side only: "2000 basis points"
  // becomes "20%", "1000 basis points" becomes "10%". Stored rows
  // are untouched.
  d = d.replace(/(\d+) basis points/gi, (_, n) => `${(Number(n) / 100).toFixed(2).replace(/\.?0+$/, '')}%`);
  d = d.replace(/as provisional/g, 'as pending');
  // UX audit 09: household wording for the week-close summary and
  // dedupe wording (display only — stored rows are untouched).
  d = householdActivityText(d);
  d = d.replace(/\s{2,}/g, ' ').replace(/\.{2,}/g, '.').trim();
  // Declutter-cross-app, Task 3: plain-language detail, display
  // only — stored audit_log rows are untouched (see filterState).
  return simplifyActivityDetail(d);
}
function formatAuditAction(action) {
  // Old rows carry the pre-rename wording; display them under the new name too.
  return action === 'Manual provisional transaction added' || action === 'Purchase added by hand'
    ? 'Transaction added by hand' : action; // old rows
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
// Popup-padding-labels-fix (owner, Nov 4): popup scroll lock. While
// ANY scroll-blocking overlay is open, the page behind must not
// scroll — a scroll gesture inside a popup scrolls the popup only.
// The state is derived from the DOM on every open/close (not a
// counter), so every close path is covered, including tab-tap closes
// and sheets stacked over filters: as long as one overlay remains,
// the lock stays. Locking sets overflow hidden on both html and body
// (iOS Safari needs both); unlocking restores the page's scroll
// position, which the lock preserved. The profile menu is a small
// dropdown, not a scroll-blocking overlay, so it is deliberately not
// part of this lock; Escape/focus-trap/backdrop-close behavior is
// untouched — the lock only ever follows visibility.
let scrollLockApplied = false;
let scrollLockY = 0;
function anyOverlayOpen() {
  if (document.getElementById('sheetOverlay')) return true;
  const f = document.getElementById('txFiltersSheet');
  if (f && !f.classList.contains('hidden')) return true;
  const a = document.getElementById('addPopupOverlay');
  if (a && !a.classList.contains('hidden')) return true;
  return false;
}
function syncScrollLock() {
  const want = anyOverlayOpen();
  if (want === scrollLockApplied) return;
  scrollLockApplied = want;
  if (want) {
    scrollLockY = window.scrollY || 0;
    document.documentElement.style.overflow = 'hidden';
    document.body.style.overflow = 'hidden';
  } else {
    document.documentElement.style.overflow = '';
    document.body.style.overflow = '';
    window.scrollTo(0, scrollLockY);
  }
}
// Send-live-bundle, transaction Actions sheet: one Actions line in
// a detail opens this list sheet (same pattern as the Add popup).
// Exactly four actions: Charity, Extra Fund, Other, Delete.
// Charity = old Mark as charity (whole only, admin only, posted
// charge only). Extra Fund = old Use Extra Fund (charges only, a
// pending fund request, never instant cover). Other = old
// Reclassify (admin only, pick a type + reason). Delete:
// hand-written rows are permanently deleted; bank/email/file rows
// are moved to Trash (exclude_transaction + reason, toast exactly
// 'Moved to trash bin.'). Charity automatically excludes Extra
// Fund: charity rows list Delete only, and Extra Fund refuses
// charity rows outright. Members list Extra Fund only, on charges.
async function openTxActionsSheet(row) {
  const isAdmin = household && household.role === 'admin';
  const excluded = row.excluded === true || row.state === 'excluded';
  if (excluded) return;
  const actions = [];
  if (isAdmin && row.kind === 'charity') {
    actions.push({ id: 'delete', label: 'Delete', sub: row.source === 'manual' ? 'Permanently deletes this hand-entered row' : 'Moves this row to the Trash' });
  } else {
    if (isAdmin && row.kind === 'charge' && row.state === 'verified') actions.push({ id: 'charity', label: 'Charity', sub: 'Counts it as a charity gift, out of weekly spending' });
    if (row.kind === 'charge') actions.push({ id: 'extraFund', label: 'Extra Fund', sub: 'Ask for this charge to be covered from the fund' });
    if (isAdmin) actions.push({ id: 'other', label: 'Other', sub: 'Change how this transaction counts' });
    if (isAdmin) actions.push({ id: 'delete', label: 'Delete', sub: row.source === 'manual' ? 'Permanently deletes this hand-entered row' : 'Moves this row to the Trash' });
  }
  if (!actions.length) return;
  document.getElementById('sheetOverlay')?.remove();
  const overlay = document.createElement('div');
  overlay.id = 'sheetOverlay';
  overlay.innerHTML = `<div class="sheet" role="dialog" aria-modal="true" aria-label="Actions for ${esc(displayMerchant(row.merchant))}"><span class="sheet-handle" aria-hidden="true"></span>
    <div class="sheet-top"><button class="sheet-top-cancel" type="button" id="txActionsCancel">Cancel</button><h3>Actions</h3><span class="sheet-top-spacer"></span></div><p class="muted small">${esc(displayMerchant(row.merchant))} — ${formatCents(row.amount_cents)}</p>
    ${actions.map((a) => `<button class="tx-action-row" data-tx-action="${a.id}" type="button"><span><strong>${a.label}</strong><br><span class="muted small">${esc(a.sub)}</span></span><span aria-hidden="true">›</span></button>`).join('')}</div>`;
  document.body.appendChild(overlay);
  syncScrollLock();
  const close = () => { document.removeEventListener('keydown', escHandler); overlay.remove(); syncScrollLock(); };
  const escHandler = (e) => { if (e.key === 'Escape') { e.preventDefault(); close(); } };
  document.addEventListener('keydown', escHandler);
  overlay.querySelector('#txActionsCancel')?.addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  overlay.querySelectorAll('[data-tx-action]').forEach((btn) => btn.addEventListener('click', async () => {
    const id = btn.dataset.txAction;
    close();
    if (id === 'charity') await doTxCharity(row);
    else if (id === 'extraFund') await doTxExtraFund(row);
    else if (id === 'other') await doTxReclassify(row);
    else if (id === 'delete') await doTxDelete(row);
  }));
}
async function doTxCharity(row) {
  if (!row || !(await showConfirm('Mark as charity gift', `"${row.merchant}" ${formatCents(row.amount_cents)} — this moves the whole transaction out of weekly spending and counts it as charity given. If only part of it was a gift, do not mark it here: part-gifts are not supported yet.`, 'Mark as charity'))) return;
  const { error } = await supabase.rpc('mark_transaction_charity', { p_transaction_id: row.id });
  if (error) {
    console.warn('mark_transaction_charity failed:', error.message);
    const refusal = /locked|fund|posted|charge|November 2026|excluded/i.test(error.message || '');
    if (refusal) await showAlert('Cannot mark as charity', error.message);
    else showToast(/could not find|does not exist|schema cache/i.test(error.message || '') ? 'Charity isn\'t live yet — the database step still needs approval.' : 'Could not mark this as charity. Try again.', true);
    return;
  }
  showToast(`Marked as charity gift: ${formatCents(row.amount_cents)} to ${row.merchant}.`);
  await refresh();
}
async function doTxExtraFund(row) {
  // Charity automatically excludes Extra Fund, made explicit here
  // (the server already guards it): a charity row never reaches
  // this action from its sheet, and a stale call is refused.
  if (row.kind === 'charity') { await showAlert('Does not qualify', 'Charity gifts cannot be covered by the Extra Fund.'); return; }
  if (row.kind !== 'charge') { await showAlert('Does not qualify', 'Only a charge can be covered by the Extra Fund. This row does not count toward weekly spending, so there is nothing for the fund to cover.'); return; }
  const amountText = await showSheet({ title: 'Use Extra Fund', message: `Ask the admin to cover "${row?.merchant ?? 'this transaction'}" (${formatCents(row?.amount_cents ?? 0)}) from the Extra Fund?`, inputLabel: 'Amount ($)', inputValue: row ? (row.amount_cents / 100).toFixed(2) : '', confirmLabel: 'Send request', cancelLabel: 'Cancel' });
  if (amountText === null) return;
  const cents = parseDollarsStrict(amountText);
  if (cents === null || cents <= 0) { await showAlert('Invalid amount', 'Enter a positive amount.'); return; }
  const { data: { user } } = await supabase.auth.getUser();
  const { error } = await supabase.from('fund_requests').insert({
    household_id: household.household_id, requested_by: user.id,
    amount_cents: cents, note: '', status: 'pending', transaction_id: row.id,
  });
  if (error) { console.warn('fund request (use-fund) failed:', error.message); await showAlert('Could not send request', 'Could not send this request. Try again.'); return; }
  await audit('Extra Fund request created', `Requested ${formatCents(cents)} for ${row?.merchant ?? 'a transaction'}.`);
  await refresh();
}
async function doTxReclassify(row) {
  const newKind = await showSheet({ title: 'Reclassify transaction', message: 'Change how this transaction counts. Pick the new type, then give a reason.', inputLabel: 'New type', inputOptions: [{ value: 'charge', label: 'Charge' }, { value: 'refund', label: 'Refund' }, { value: 'fund_charge', label: 'Fund charge' }, { value: 'transfer', label: 'Transfer' }], confirmLabel: 'Continue', cancelLabel: 'Cancel' });
  if (newKind === null) return;
  const reason = await showSheet({ title: 'Reclassify transaction', message: 'Why reclassify this transaction?', inputLabel: 'Reason (required)', confirmLabel: 'Reclassify', cancelLabel: 'Cancel' });
  if (reason === null) return;
  if (!reason.trim()) { await showAlert('Reason required', 'Enter a reason for reclassifying this transaction.'); return; }
  const { error } = await supabase.rpc('reclassify_transaction', { txn_id: row.id, new_kind: newKind, reason: reason.trim() });
  if (error) { console.warn('reclassify_transaction failed:', error.message); await showAlert('Could not reclassify', 'Could not reclassify this transaction. Try again.'); return; }
  await audit('Transaction reclassified', `${row ? row.merchant : 'Transaction'} reclassified to ${newKind} — reason: ${reason.trim()}.`);
  await refresh();
}
async function doTxDelete(row) {
  if (row.source === 'manual') {
    if (!(await showConfirm('Delete transaction', `"${row.merchant}" ${formatCents(row.amount_cents)} — this removes the hand-entered transaction and cannot be undone.`, 'Delete'))) return;
    const { error } = await supabase.rpc('delete_transaction', { p_transaction_id: row.id });
    if (error) { console.warn('delete_transaction failed:', error.message); await showAlert('Could not delete', 'Could not delete this transaction. Try again.'); return; }
    await refresh();
    return;
  }
  // Bank/email/file rows: Delete moves the row to Trash (an
  // exclusion with a reason, never a true erase — the bank would
  // re-sync it). The row leaves the main list and is restored from
  // the Trash bin below the list.
  const reason = await showSheet({ title: 'Move to trash', message: `"${row?.merchant ?? 'This transaction'}" ${formatCents(row?.amount_cents ?? 0)} — this moves it to the Trash. The admin can bring it back from the Trash. Give a reason to continue.`, inputLabel: 'Reason (required)', confirmLabel: 'Delete', cancelLabel: 'Keep it' });
  if (reason === null) return;
  if (!reason.trim()) { await showAlert('Reason required', 'Enter a reason for moving this transaction to the Trash.'); return; }
  const { error } = await supabase.rpc('exclude_transaction', { txn_id: row.id, reason: reason.trim() });
  if (error) { console.warn('exclude_transaction (trash) failed:', error.message); await showAlert('Could not delete', 'Could not delete this transaction. Try again.'); return; }
  await audit('Transaction moved to trash', `${row.merchant} ${formatCents(row.amount_cents)} moved to trash — reason: ${reason.trim()}.`);
  showToast('Moved to trash bin.');
  await refresh();
}
function showSheet({ title, message, rows = null, disclosure = null, inputLabel, inputValue = '', inputType = 'text', inputOptions = null, confirmLabel = 'OK', cancelLabel = null, extraAction = null, actions = null }) {
  // SECURITY: EVERY interpolated value is escaped with esc() — title,
  // message, input label/value, option labels/values, and button labels.
  // No raw caller value reaches innerHTML through any showSheet path.
  // Messages are plain text (never HTML); the sheet CSS renders newlines.
  return new Promise((resolve) => {
    // Audit-merge fix (review B A1): focus returns to the opener when
    // the sheet closes. Captured before the overlay is built.
    const sheetOpener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    document.getElementById('sheetOverlay')?.remove();
    const safeType = ['text', 'password', 'number', 'email'].includes(inputType) ? inputType : 'text';
    const overlay = document.createElement('div');
    overlay.id = 'sheetOverlay';
    const inputHtml = !inputLabel ? '' : inputOptions
      ? `<label>${esc(inputLabel)}<select id="sheetInput">${inputOptions.map((o) => `<option value="${esc(o.value)}">${esc(o.label)}</option>`).join('')}</select></label>`
      : `<label>${esc(inputLabel)}<input id="sheetInput" type="${safeType}" value="${esc(inputValue)}"></label>`;
    // Delta3: labeled metric rows (Home breakdown sheets) render above
    // the message paragraph; the paragraph is omitted when empty so a
    // rows-only sheet has no blank line. Rows are [label, value] pairs.
    const rowsHtml = rows ? `<div class="sheet-rows">${rows.map(([label, value]) => `<div><span>${esc(label)}</span><span>${esc(value)}</span></div>`).join('')}</div>` : '';
    // UX-review-fix: an optional collapsed calculation, as a
    // <details> block — label + amount rows only, never a paragraph.
    // Used by the Weekly Budget sheet for its "how this adds up"
    // lines, which used to sit below the rows as a long sentence.
    const disclosureHtml = disclosure ? `<details class="sheet-disclosure"><summary>${esc(disclosure.label)}</summary><div class="sheet-rows">${disclosure.rows.map(([label, value]) => `<div><span>${esc(label)}</span><span>${esc(value)}</span></div>`).join('')}</div></details>` : '';
    // Weekly-sheet-simple: an optional extra primary action rendered
    // in the button row, below the rows and below the disclosure
    // (the button row already follows both). Two-button rule
    // (owner, Nov 4): in a two-button row the non-primary button is
    // grey tertiary, never pale — so a sheet with an extra action
    // renders its confirm as tertiary, and a confirm+cancel sheet
    // renders its cancel as tertiary. Single-button sheets keep
    // their primary confirm. The pale treatment is reserved for
    // three-button rows; a three-button sheet (cancel + extra +
    // confirm) therefore keeps its pale cancel, with primary and
    // grey beside it, so no two adjacent buttons share a color.
    const extraHtml = extraAction ? `<button class="btn btn-primary" type="button" id="sheetExtra">${esc(extraAction.label)}</button>` : '';
    // Task 7: Extra Fund sheet actions (Add / Use / Ask) — each keeps
    // its own treatment (primary / pale / grey) and returns its
    // result; Close is quiet so it cannot read as a money action.
    const actionsHtml = actions ? actions.map((a) => `<button class="${esc(a.btnClass)}" type="button" data-sheet-action="${esc(a.result)}">${esc(a.label)}</button>`).join('') : '';
    overlay.innerHTML = `<div class="sheet" role="dialog" aria-modal="true" aria-label="${esc(title)}"><span class="sheet-handle" aria-hidden="true"></span>
      <div class="sheet-top">${cancelLabel ? `<button class="sheet-top-cancel" type="button" id="sheetCancelTop">${esc(cancelLabel)}</button>` : '<span class="sheet-top-spacer"></span>'}<h3>${esc(title)}</h3><span class="sheet-top-spacer"></span></div>${rowsHtml}${disclosureHtml}${message ? `<p>${esc(message)}</p>` : ''}
      ${inputHtml}
      <div class="sheet-btns">
        ${extraHtml}
        ${actionsHtml}
        <button class="btn${actions ? ' btn-quiet' : extraAction ? ' btn-tertiary' : ' btn-primary'}" type="button" id="sheetConfirm">${esc(confirmLabel)}</button>
      </div></div>`;
    document.body.appendChild(overlay);
    syncScrollLock();
    // UX-review-fix, Show password (owner, Nov 3, 7:53 PM): every
    // password input gets a Show/Hide toggle. The sheet's only
    // password field is Change password; the toggle switches the
    // input type only, never logs or displays the value elsewhere,
    // and changes no auth logic or password policy.
    const sheetInputEl = document.getElementById('sheetInput');
    if (sheetInputEl && safeType === 'password') {
      const wrap = document.createElement('span'); wrap.className = 'password-row';
      sheetInputEl.replaceWith(wrap); wrap.appendChild(sheetInputEl);
      const tog = document.createElement('button'); tog.type = 'button'; tog.className = 'btn btn-quiet';
      tog.textContent = 'Show'; tog.setAttribute('aria-label', 'Show password'); tog.setAttribute('aria-pressed', 'false');
      tog.addEventListener('click', () => {
        const showing = sheetInputEl.type === 'password';
        sheetInputEl.type = showing ? 'text' : 'password';
        tog.textContent = showing ? 'Hide' : 'Show';
        tog.setAttribute('aria-label', showing ? 'Hide password' : 'Show password');
        tog.setAttribute('aria-pressed', showing ? 'true' : 'false');
      });
      wrap.appendChild(tog);
    }
    let settled = false;
    const done = (v) => {
      if (settled) return; settled = true;
      document.removeEventListener('keydown', sheetKeyHandler);
      overlay.remove();
      syncScrollLock();
      // A1 focus return: back to the opener when it is still on the
      // page (a refresh may have replaced it — then this is a no-op).
      if (sheetOpener && document.contains(sheetOpener)) sheetOpener.focus();
      resolve(v);
    };
    // Audit-merge fix (review B A1): Escape closes the sheet (same
    // result as Cancel/backdrop), Tab stays inside it. This handler
    // owns #sheetOverlay only — the filter sheet is a separate
    // element with its own handler, so when it is open it keeps
    // Escape/Tab and this handler stands aside rather than fighting
    // it. Read-only sheets get Close semantics via their confirm
    // button; form sheets keep Cancel.
    const sheetKeyHandler = (e) => {
      if (document.getElementById('sheetOverlay') !== overlay) return;
      const filtersOpen = (() => { const f = document.getElementById('txFiltersSheet'); return f && !f.classList.contains('hidden'); })();
      if (filtersOpen) return;
      if (e.key === 'Escape') { e.preventDefault(); done(inputLabel ? null : false); return; }
      if (e.key !== 'Tab') return;
      const focusables = [...overlay.querySelectorAll('button, input, select, textarea, summary, [tabindex]:not([tabindex="-1"])')].filter((el) => !el.disabled && el.offsetParent !== null);
      if (!focusables.length) return;
      const first = focusables[0]; const last = focusables[focusables.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    };
    document.addEventListener('keydown', sheetKeyHandler);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) done(inputLabel ? null : false); });
    overlay.querySelector('#sheetCancelTop')?.addEventListener('click', () => done(inputLabel ? null : false));
    overlay.querySelector('#sheetExtra')?.addEventListener('click', () => done(extraAction.result ?? 'extra'));
    overlay.querySelectorAll('[data-sheet-action]').forEach((b) => b.addEventListener('click', () => done(b.dataset.sheetAction)));
    overlay.querySelector('#sheetConfirm').addEventListener('click', () => {
      done(inputLabel ? document.getElementById('sheetInput').value : true);
    });
    if (inputLabel) document.getElementById('sheetInput').focus();
    else overlay.querySelector('#sheetConfirm')?.focus();
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
const applyTxSort = () => { localStorage.setItem('hb-tx-sort', txSort); refresh(); };
document.getElementById('txSortField')?.addEventListener('change', (e) => {
  const dir = txSort.endsWith('asc') ? 'asc' : 'desc';
  txSort = `${e.target.value}-${dir}`;
  applyTxSort();
});
document.getElementById('txSortDirBtn')?.addEventListener('click', () => {
  const field = txSort.startsWith('amount') ? 'amount' : 'date';
  const dir = txSort.endsWith('asc') ? 'desc' : 'asc';
  txSort = `${field}-${dir}`;
  applyTxSort();
});

// Add popup (owner design Nov 3, 9:49 PM): the Transactions header
// has one blue + button; tapping it opens an options popup —
// Purchase / Donation / Upload for admins, Purchase only for
// members (the owner's "regular user just purchase, no?" is YES:
// charity gifts are admin-only on the server, and Upload is gated
// admin-only here and at the CSV confirm path). Choosing an option
// MOVES that form's existing section into the popup slot — the
// section is moved, not copied, so its handlers, validation, draft,
// and CSV preview work exactly as they do inline. Back returns to
// the options; Cancel or a successful submit returns to the list.
// A tab switch hides the popup (the form section is display:none
// like any other off-view section) and returning to Transactions
// reopens it with its draft intact, as before.
const ADD_FORM_SECTIONS = { manual: 'section-manual', csv: 'section-csv', charity: 'section-charity-gift' };
const addPopupHomes = new Map();
function addPopupRestoreSection(id) {
  const el = document.getElementById(id); const home = addPopupHomes.get(id);
  if (!el || !home) return;
  if (home.next && document.contains(home.next)) home.parent.insertBefore(el, home.next);
  else home.parent.appendChild(el);
  addPopupHomes.delete(id);
}
function addPopupRestoreAll() { for (const id of Object.values(ADD_FORM_SECTIONS)) addPopupRestoreSection(id); }
function addPopupPlace(id) {
  const el = document.getElementById(id); const slot = document.getElementById('addPopupFormSlot');
  if (!el || !slot) return;
  if (!addPopupHomes.has(id)) addPopupHomes.set(id, { parent: el.parentNode, next: el.nextSibling });
  slot.appendChild(el);
}
function syncAddPopup(viewName) {
  const overlay = document.getElementById('addPopupOverlay');
  const optionsCard = document.getElementById('addOptionsCard');
  const slot = document.getElementById('addPopupFormSlot');
  if (!overlay || !optionsCard || !slot) return;
  const open = viewName === 'purchases' && addFormOpen !== null;
  overlay.classList.toggle('hidden', !open);
  syncScrollLock();
  if (!open) { addPopupRestoreAll(); return; }
  // Role gating for the options list itself: members see Purchase only.
  const isAdmin = household && household.role === 'admin';
  const don = document.getElementById('addOptionDonationBtn'); if (don) don.style.display = isAdmin ? '' : 'none';
  const up = document.getElementById('addOptionUploadBtn'); if (up) up.style.display = isAdmin ? '' : 'none';
  if (addFormOpen === 'options') {
    addPopupRestoreAll();
    optionsCard.classList.remove('hidden'); slot.classList.add('hidden');
    document.getElementById('addOptionPurchaseBtn')?.focus();
  } else {
    const sectionId = ADD_FORM_SECTIONS[addFormOpen];
    if (sectionId) addPopupPlace(sectionId);
    optionsCard.classList.add('hidden'); slot.classList.remove('hidden');
  }
}
// Escape closes the popup the way Back/Cancel does (form → options,
// options → list), and Tab stays inside it. This handler owns
// #addPopupOverlay only: when a generic sheet (#sheetOverlay) or the
// filter sheet is open on top of it, it stands aside for them.
document.addEventListener('keydown', (e) => {
  const overlay = document.getElementById('addPopupOverlay');
  if (!overlay || overlay.classList.contains('hidden')) return;
  if (document.getElementById('sheetOverlay')) return;
  const filtersOpen = (() => { const f = document.getElementById('txFiltersSheet'); return f && !f.classList.contains('hidden'); })();
  if (filtersOpen) return;
  if (e.key === 'Escape') { e.preventDefault(); if (addFormOpen === 'options') setAddForm(null); else setAddForm('options'); return; }
  if (e.key !== 'Tab') return;
  const focusables = [...overlay.querySelectorAll('button, input, select, textarea, [tabindex]:not([tabindex="-1"])')].filter((el) => !el.disabled && el.offsetParent !== null);
  if (!focusables.length) return;
  const first = focusables[0]; const last = focusables[focusables.length - 1];
  if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
  else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
});
document.getElementById('addPopupOverlay')?.addEventListener('click', (e) => { if (e.target.id === 'addPopupOverlay') setAddForm(null); });
$('txAddBtn')?.addEventListener('click', () => setAddForm('options'));
const setAddForm = (which) => {
  // Member gate at the entry point: only Purchase is offered to
  // members, and a member reaching a gated form any other way is
  // sent back to the options instead of into the form.
  if ((which === 'charity' || which === 'csv') && !(household && household.role === 'admin')) which = 'options';
  addFormOpen = which; showView('purchases');
};
$('addOptionPurchaseBtn')?.addEventListener('click', () => setAddForm('manual'));
$('addOptionDonationBtn')?.addEventListener('click', () => setAddForm('charity'));
$('addOptionUploadBtn')?.addEventListener('click', () => setAddForm('csv'));
$('addOptionsCloseBtn')?.addEventListener('click', () => setAddForm(null));
$('manualBackBtn')?.addEventListener('click', () => setAddForm('options'));
// UX audit 06: an explicit Cancel closes the form AND clears the
// draft. Back only returns to the Add choices — the draft stays,
// as the form hint now states. Purchases-only: no refund option
// here (owner decision Nov 3).
$('manualCancelBtn')?.addEventListener('click', () => {
  document.getElementById('manualForm')?.reset();
  document.getElementById('manualFormError')?.classList.add('hidden');
  setAddForm(null);
});
$('csvBackBtn')?.addEventListener('click', () => setAddForm('options'));
$('charityBackBtn')?.addEventListener('click', () => { document.getElementById('charityFormError')?.classList.add('hidden'); setAddForm('options'); });
// Task 7: Funds forms open from the Extra Fund sheet (see
// openFundSheet), one at a time. The More › rows toggle their
// sections in place without scrolling the page to the top.
const setFundForm = (which) => { fundFormOpen = which; showView('money'); };
const toggleMore = (which) => {
  if (which === 'activity') moreFundActivityOpen = !moreFundActivityOpen;
  else if (which === 'review') moreReviewOpen = !moreReviewOpen;
  else if (which === 'savings') moreSavingsOpen = !moreSavingsOpen;
  showView('money', { preserveScroll: true });
};
$('moreFundActivityBtn')?.addEventListener('click', () => toggleMore('activity'));
$('moreReviewBtn')?.addEventListener('click', () => toggleMore('review'));
$('moreSavingsBtn')?.addEventListener('click', () => toggleMore('savings'));
// Ask lives once, in the Funds actions card (the delta3 beside-button
// was removed for parity; the Funds balance card itself is a tap
// target for its breakdown sheet, not a button row).
// UX-review-fix P2: the held balance links straight to the Review
// queue. The button lives under the Funds balance cards and only
// shows when a held week exists; tapping it opens Funds, expands
// the Review section, and scrolls to it, so the held amount is never
// separated from the queue that explains it.
$('fundHeldLinkBtn')?.addEventListener('click', () => {
  fundFormOpen = null;
  moreReviewOpen = true;
  showView('money');
  document.getElementById('section-fund-review-more')?.scrollIntoView({ block: 'start' });
});
$('fundAddBackBtn')?.addEventListener('click', () => setFundForm(null));
$('fundUseBackBtn')?.addEventListener('click', () => setFundForm(null));
$('fundAskBackBtn')?.addEventListener('click', () => setFundForm(null));
$('charityIncomeBackBtn')?.addEventListener('click', () => setFundForm(null));
// Task 7: past savings records are the More › row above (toggleMore
// 'savings'); the old Past savings toggle button is gone with its
// card. Records stay read-only; the database rows are untouched.
// Delta B1: History date filter + Load more.
$('historyFilterApplyBtn')?.addEventListener('click', async () => {
  historyFilter = { from: $('historyFromInput')?.value ?? '', to: $('historyToInput')?.value ?? '' };
  auditLimit = 50;
  await refresh();
});
$('historyFilterClearBtn')?.addEventListener('click', async () => {
  const fi = $('historyFromInput'); if (fi) fi.value = '';
  const ti = $('historyToInput'); if (ti) ti.value = '';
  historyFilter = { from: '', to: '' };
  auditLimit = 50;
  await refresh();
});
$('historyLoadMoreBtn')?.addEventListener('click', async () => {
  auditLimit += 50;
  await refresh();
});
// R13 charity gift form: admin-only RPC, explicitly confirmed by
// entry, so the gift posts as verified (Given) at once and never
// enters weekly spending. Duplicate warning mirrors the manual form.
let giftSubmitting = false;
let lastGiftAttempt = null; // { key, merchant, amount, date, suffix } for gift idempotency retries
$('charityGiftForm')?.addEventListener('submit', async (e) => {
  e.preventDefault();
  // Same double-tap guard as the manual form: the duplicate check
  // below awaits a network call, so disable before it, not after.
  if (giftSubmitting) return;
  giftSubmitting = true;
  const f = e.target;
  const submitBtn = f.querySelector('button[type="submit"]');
  if (submitBtn) submitBtn.disabled = true;
  const done = () => { giftSubmitting = false; if (submitBtn) submitBtn.disabled = false; };
  // Audit-merge fix (audit A finding 6): field errors sit inline
  // beside the form, like the manual form's #manualFormError, instead
  // of popups. The form is novalidate so this handler runs even when
  // the native required date is empty (previously only a browser
  // bubble showed); the merchant check below is the guard the native
  // required attribute used to provide for that field.
  const giftErr = document.getElementById('charityFormError');
  const setGiftError = (msg, field) => { if (giftErr) { giftErr.textContent = msg; giftErr.classList.remove('hidden'); } if (field) field.focus(); };
  if (giftErr) giftErr.classList.add('hidden');
  const amount = parseDollarsStrict(f.amount.value);
  if (amount === null || amount <= 0) { done(); setGiftError('Amount: enter a positive amount.', f.amount); return; }
  if (!f.merchant.value.trim()) { done(); setGiftError('Organization: enter a name for this gift.', f.merchant); return; }
  if (!f.date.value) { done(); setGiftError('Date: pick the date of the gift.', f.date); return; }
  if (f.date.value < '2026-11-01') { done(); await showAlert('Charity starts November 2026', 'Gifts before November 2026 are outside the charity period.'); return; }
  const suffix = f.suffix.value.trim();
  if (suffix && !/^\d{4}$/.test(suffix)) { done(); setGiftError('Card suffix: enter exactly 4 digits, or leave it blank for a cash gift. Never enter a full card number.', f.suffix); return; }
  const merchant = f.merchant.value.trim().toUpperCase();
  const { data: dupes } = await supabase.from('transactions')
    .select('merchant, amount_cents, date').eq('household_id', household.household_id)
    .eq('merchant', merchant).eq('amount_cents', amount).eq('date', f.date.value).limit(1);
  if ((dupes ?? []).length && !(await showConfirm('Possible duplicate', `A transaction already exists for ${merchant} ${formatCents(amount)} on ${fmtLong(f.date.value)}. Record this gift anyway?`, 'Record anyway'))) { done(); return; }
  // The gift hash carries a per-submit nonce: two real identical
  // gifts on one day (the Nov 3 case: three $2 gifts to one org) must
  // not collide on the transactions unique hash, or the second gift
  // could never be recorded. The duplicate warning above is the
  // guard against accidental re-entry, not the hash.
  const nonce = (typeof crypto !== 'undefined' && crypto.randomUUID) ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`;
  const hash = await sha(`charity|${f.date.value}|${merchant}|${amount}|${suffix || '0000'}|${nonce}`);
  // Client-key idempotency (Round 3, bug 8 server half): a retry of
  // the same intended gift reuses its key, so the server replays
  // the original row instead of recording a second gift. A fresh
  // submit gets a fresh key, so real identical gifts stay distinct.
  const giftKey = (lastGiftAttempt && lastGiftAttempt.merchant === merchant && lastGiftAttempt.amount === amount && lastGiftAttempt.date === f.date.value && lastGiftAttempt.suffix === (suffix || '0000'))
    ? lastGiftAttempt.key
    : (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`);
  lastGiftAttempt = { key: giftKey, merchant, amount, date: f.date.value, suffix: suffix || '0000' };
  const { error } = await supabase.rpc('record_charity_gift', { p_household_id: household.household_id, p_merchant: merchant, p_amount_cents: amount, p_date: f.date.value, p_card_suffix: suffix || '0000', p_note: f.note.value.trim(), p_dedupe_hash: hash, p_client_key: giftKey });
  if (error) {
    console.warn('record_charity_gift failed:', error.message);
    const notLive = /could not find|does not exist|schema cache/i.test(error.message || '');
    showToast(notLive ? 'Charity isn\'t live yet — the database step still needs approval.' : error.message && /admin only/i.test(error.message) ? 'Only the admin can record charity gifts.' : 'Could not record this gift. Try again.', true);
    done();
    return;
  }
  f.reset(); document.getElementById('charityFormError')?.classList.add('hidden'); setAddForm(null); lastGiftAttempt = null; done();
  showToast(`Gift recorded: ${formatCents(amount)} to ${merchant}.`);
  await refresh();
});
// R13 charity rate + income forms (admin only, server-enforced).
// Rate inputs are percents; parseDollarsStrict turns "10.5" into
// 1050, which is exactly basis points, so no float math is needed.
function updateCharityIncomePreview() {
  const pv = $('charityIncomePreview'); if (!pv) return;
  const f = document.getElementById('charityIncomeForm'); if (!f) return;
  const cents = parseDollarsStrict(f.amount.value);
  if (cents === null || cents <= 0) { pv.textContent = 'Enter an amount to see what it commits.'; return; }
  if (!currentCharityData) { pv.textContent = 'Rate preview is unavailable until charity loads — the server still applies the saved default when you save.'; return; }
  const overrideBp = parseDollarsStrict(f.rate.value);
  const rateBp = overrideBp !== null ? overrideBp : currentCharityData.defaultRateBp;
  pv.textContent = `This commits ${formatCents(charityCommittedCents(cents, rateBp))} at ${(rateBp / 100).toFixed(2).replace(/\.?0+$/, '')}% — ${overrideBp !== null ? 'this entry only (the default rate for future incomes is unchanged).' : 'the default rate, applied to this entry.'}`;
}
document.querySelector('#charityIncomeForm input[name="amount"]')?.addEventListener('input', updateCharityIncomePreview);
document.querySelector('#charityIncomeForm input[name="rate"]')?.addEventListener('input', updateCharityIncomePreview);
$('charityRateForm')?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const bp = parseDollarsStrict(f.rate.value);
  if (bp === null || bp < 0 || bp > 10000) { showToast('Enter a rate between 0% and 100%.', true); return; }
  const submitBtn = f.querySelector('button[type="submit"]');
  if (submitBtn) submitBtn.disabled = true;
  const { error } = await supabase.rpc('set_charity_default_rate', { p_household_id: household.household_id, p_rate_bp: bp });
  if (submitBtn) submitBtn.disabled = false;
  if (error) { console.warn('set_charity_default_rate failed:', error.message); showToast(/could not find|does not exist|schema cache/i.test(error.message || '') ? 'Charity isn\'t live yet — the database step still needs approval.' : 'Could not save the default rate. Try again.', true); return; }
  f.reset();
  showToast(`Default charity rate saved: ${(bp / 100).toFixed(2).replace(/\.?0+$/, '')}% for future incomes.`);
  await refresh();
});
let correctingIncomeId = null;
$('charityIncomeCancelBtn')?.addEventListener('click', () => {
  correctingIncomeId = null;
  const f = document.getElementById('charityIncomeForm'); if (f) f.reset();
  const mode = $('charityIncomeMode'); if (mode) mode.textContent = 'Adding new income.';
  const cancel = $('charityIncomeCancelBtn'); if (cancel) cancel.style.display = 'none';
  updateCharityIncomePreview();
});
$('charityIncomeForm')?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const cents = parseDollarsStrict(f.amount.value);
  if (cents === null || cents <= 0) { showToast('Enter a positive amount.', true); return; }
  if (!f.date.value) { showToast('Pick the date of the income.', true); return; }
  if (f.date.value < '2026-11-01') { showToast('Charity starts November 2026 — income before then cannot accrue.', true); return; }
  const overrideBp = parseDollarsStrict(f.rate.value);
  if (overrideBp !== null && (overrideBp < 0 || overrideBp > 10000)) { showToast('Enter a rate between 0% and 100%, or leave it blank for the default.', true); return; }
  const submitBtn = f.querySelector('button[type="submit"]');
  if (submitBtn) submitBtn.disabled = true;
  let data = null; let error = null;
  if (correctingIncomeId) {
    ({ data, error } = await supabase.rpc('correct_charity_income', { p_income_id: correctingIncomeId, p_amount_cents: cents, p_income_date: f.date.value, p_source_label: f.source.value.trim(), p_rate_bp: overrideBp, p_note: f.note.value.trim() }));
  } else {
    ({ data, error } = await supabase.rpc('record_charity_income', { p_household_id: household.household_id, p_amount_cents: cents, p_income_date: f.date.value, p_source_label: f.source.value.trim(), p_rate_bp: overrideBp, p_note: f.note.value.trim() }));
  }
  if (submitBtn) submitBtn.disabled = false;
  if (error) {
    console.warn('charity income save failed:', error.message);
    showToast(/could not find|does not exist|schema cache/i.test(error.message || '') ? 'Charity isn\'t live yet — the database step still needs approval.' : 'Could not save this income. Try again.', true);
    return;
  }
  const wasCorrection = !!correctingIncomeId;
  correctingIncomeId = null;
  f.reset();
  const mode = $('charityIncomeMode'); if (mode) mode.textContent = 'Adding new income.';
  const cancel = $('charityIncomeCancelBtn'); if (cancel) cancel.style.display = 'none';
  updateCharityIncomePreview();
  showToast(wasCorrection ? `Income corrected — now commits ${formatCents(data?.committed_cents ?? 0)}. The old entry stays, marked reversed.` : `Income saved — commits ${formatCents(data?.committed_cents ?? 0)} to charity.`);
  await refresh();
});
// Delta B2: Transactions filters live in a bottom sheet. Opening
// snapshots every filter (month, card, bounds, sort, status, week,
// dates); Apply commits the sheet's status/week/date values (month,
// card, bounds, and sort already apply live, as before) and closes;
// Reset clears everything to defaults; Cancel restores the snapshot
// and leaves the list unchanged.
let txFiltersSnapshot = null;
const closeTxFilters = () => {
  const f = document.getElementById('txFiltersSheet');
  if (f) f.classList.add('hidden');
  const t = document.getElementById('txFiltersToggle');
  if (t) t.setAttribute('aria-expanded', 'false');
  syncScrollLock();
};
// UX-review-fix: the filter sheet is a dialog, so Escape closes it
// (like Cancel, preserving applied filters), Enter on Cancel closes
// it without submitting (Cancel is a plain button, never a submit),
// and Tab stays inside while it is open. Focus returns to Filters
// on close, so keyboard users do not lose their place. Scope is the
// filter sheet only: the generic showSheet dialogs are single-action
// popups that already close on backdrop/confirm/cancel, and changing
// their key handling in the same pass would risk the sheet-input
// forms (manual, charity, fund) that share showSheet.
document.addEventListener('keydown', (e) => {
  const f = document.getElementById('txFiltersSheet');
  if (!f || f.classList.contains('hidden')) return;
  if (e.key === 'Escape') { e.preventDefault(); document.getElementById('txFiltersCancelBtn')?.click(); document.getElementById('txFiltersToggle')?.focus(); return; }
  if (e.key !== 'Tab') return;
  const focusables = [...f.querySelectorAll('select, input, button')].filter((el) => !el.disabled && el.offsetParent !== null);
  if (!focusables.length) return;
  const first = focusables[0]; const last = focusables[focusables.length - 1];
  if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
  else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
});
const openTxFilters = () => {
  const f = document.getElementById('txFiltersSheet');
  if (!f) return;
  // UX-review-fix: focus moves inside on open, and returns to the
  // Filters button when the sheet closes (see closeTxFilters).
  const first = f.querySelector('select, input, button');
  if (first) setTimeout(() => first.focus(), 0);
  txFiltersSnapshot = {
    month: txMonth,
    card: txCard,
    min: document.getElementById('txMinAmount')?.value ?? '',
    max: document.getElementById('txMaxAmount')?.value ?? '',
    sort: txSort,
    status: txFilter,
    week: txWeekOnly,
    from: txFromDate,
    to: txToDate,
  };
  // The sheet mirrors state on open, so a stale control never shows.
  const statusSel = document.getElementById('txStatusSelect'); if (statusSel) statusSel.value = txFilter;
  const weekCheck = document.getElementById('txWeekCheck'); if (weekCheck) weekCheck.checked = txWeekOnly;
  const fromInput = document.getElementById('txFromDate'); if (fromInput) fromInput.value = txFromDate;
  const toInput = document.getElementById('txToDate'); if (toInput) toInput.value = txToDate;
  f.classList.remove('hidden');
  const t = document.getElementById('txFiltersToggle');
  if (t) t.setAttribute('aria-expanded', 'true');
  syncScrollLock();
};
$('txFiltersToggle')?.addEventListener('click', () => {
  const f = document.getElementById('txFiltersSheet');
  if (!f) return;
  if (f.classList.contains('hidden')) openTxFilters();
  else closeTxFilters();
});
$('txFiltersSheet')?.addEventListener('click', (e) => {
  // Tapping the backdrop closes without applying (like Cancel).
  if (e.target.id === 'txFiltersSheet') {
    document.getElementById('txFiltersCancelBtn')?.click();
  }
});
$('txFiltersApplyBtn')?.addEventListener('click', () => {
  // Commit the sheet-held values, then re-render.
  const statusSel = document.getElementById('txStatusSelect');
  if (statusSel) txFilter = statusSel.value;
  // Audit-merge fix (audit A finding 2): always read the This week
  // checkbox, whatever the status. The old code forced the flag off
  // when Status was All, silently wiping a box the user had just
  // ticked in the same sheet. Reset/Cancel still restore the
  // snapshot, so a stale flag cannot linger that way.
  const weekCheck = document.getElementById('txWeekCheck');
  if (weekCheck) txWeekOnly = weekCheck.checked;
  txFromDate = document.getElementById('txFromDate')?.value ?? '';
  txToDate = document.getElementById('txToDate')?.value ?? '';
  closeTxFilters();
  refresh();
});
$('txFiltersCancelBtn')?.addEventListener('click', () => {
  if (txFiltersSnapshot) {
    // Month/card are state variables refresh() renders from, so
    // restoring the DOM alone would not restore the list — restore
    // the variables (and their persisted values) too.
    txMonth = txFiltersSnapshot.month; localStorage.setItem('hb-tx-month', txMonth);
    txCard = txFiltersSnapshot.card; localStorage.setItem('hb-tx-card', txCard);
    const mn = document.getElementById('txMinAmount'); if (mn) mn.value = txFiltersSnapshot.min;
    const mx = document.getElementById('txMaxAmount'); if (mx) mx.value = txFiltersSnapshot.max;
    txSort = txFiltersSnapshot.sort; localStorage.setItem('hb-tx-sort', txSort);
    txFilter = txFiltersSnapshot.status;
    txWeekOnly = txFiltersSnapshot.week;
    txFromDate = txFiltersSnapshot.from;
    txToDate = txFiltersSnapshot.to;
    refresh();
  }
  closeTxFilters();
});
$('txFiltersResetBtn')?.addEventListener('click', () => {
  txMonth = 'all'; localStorage.setItem('hb-tx-month', txMonth);
  txCard = 'all'; localStorage.setItem('hb-tx-card', txCard);
  const mn = document.getElementById('txMinAmount'); if (mn) mn.value = '';
  const mx = document.getElementById('txMaxAmount'); if (mx) mx.value = '';
  txSort = 'date-desc'; localStorage.setItem('hb-tx-sort', txSort);
  txFilter = 'all'; txWeekOnly = false; txFromDate = ''; txToDate = '';
  refresh(); closeTxFilters();
});
let txSearchTimer = null;
$('txSearch')?.addEventListener('input', () => {
  clearTimeout(txSearchTimer);
  txSearchTimer = setTimeout(() => { refresh(); }, 250);
});
// R8 amount bounds apply live, like search (debounced, not persisted
// like month/card/sort) — typing a bound re-filters the list.
let txAmountTimer = null;
for (const id of ['txMinAmount', 'txMaxAmount']) {
  document.getElementById(id)?.addEventListener('input', () => {
    clearTimeout(txAmountTimer);
    txAmountTimer = setTimeout(() => { refresh(); }, 250);
  });
}

$('addTempBtn')?.addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  // Send-live-bundle, weekly allowance override (owner, Nov 4):
  // the amount entered is a NEW TOTAL weekly allowance, not an
  // extra on top of the base, and it repeats for the chosen number
  // of weeks (1-4, default 1). Each week gets its own override row
  // via set_weekly_allowance_override — never add_temp_increase,
  // which cannot represent a lower total and must not be used as a
  // fallback. If the RPC is missing (SQL not yet applied), the
  // error toast below is shown and nothing is written.
  const cents = parseDollarsStrict($('tempIncreaseInput').value);
  if (cents === null || cents < 0) { showToast('Enter a valid amount.', true); return; }
  const weeksRaw = parseInt($('tempIncreaseWeeks')?.value ?? '1', 10);
  const weeks = Number.isFinite(weeksRaw) ? Math.min(4, Math.max(1, weeksRaw)) : 1;
  const ny = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/New_York' }));
  const sunday = new Date(ny); sunday.setDate(ny.getDate() - ny.getDay());
  // R1 busy control: a double tap must not set the override twice.
  if (btn) btn.disabled = true;
  let error = null;
  for (let i = 0; i < weeks; i += 1) {
    const d = new Date(Date.UTC(sunday.getFullYear(), sunday.getMonth(), sunday.getDate() + 7 * i));
    const weekStart = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
    const res = await supabase.rpc('set_weekly_allowance_override', { p_household_id: household.household_id, p_week_start: weekStart, p_allowance_cents: cents });
    if (res.error) { error = res.error; break; }
  }
  if (btn) btn.disabled = false;
  if (error) console.warn('set_weekly_allowance_override failed:', error.message);
  showToast(error ? 'Could not set the weekly allowance. Try again.' : `Weekly allowance set to ${formatCents(cents)} for ${weeks} week${weeks === 1 ? '' : 's'}.`, !!error);
  if (!error) await refresh();
});

$('saveAllowanceBtn')?.addEventListener('click', async (e) => {
  const btn = e.currentTarget;
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
    ? `Set the weekly allowance to ${formatCents(cents)}? (The current allowance could not be read, so no old value is shown.)\nThis applies from the current week onward (${currentWeekData?.weekStart ? `week of ${fmtLong(currentWeekData.weekStart)}` : 'this week'}). It does not rewrite closed weeks.`
    : `Change the weekly allowance from ${formatCents(oldCents)} to ${formatCents(cents)}?\nThis applies from the current week onward (${currentWeekData?.weekStart ? `week of ${fmtLong(currentWeekData.weekStart)}` : 'this week'}). It does not rewrite closed weeks.`, confirmLabel: 'Change allowance', cancelLabel: 'Keep current' });
  if (!confirmed) return;
  // R1 busy control: block repeat taps while the allowance is saving.
  if (btn) btn.disabled = true;
  const { error } = await supabase.rpc('set_base_allowance', { p_household_id: household.household_id, p_cents: cents });
  if (btn) btn.disabled = false;
  if (error) console.warn('set_base_allowance failed:', error.message);
  showToast(error ? 'Could not save allowance. Try again.' : 'Allowance saved.', !!error);
  if (!error) await refresh();
});

// R12 Add Money preview: shortfall-first split from the last loaded
// fund balances, using the shared engine helper (same rule the server
// applies). Informational only — the server split is authoritative.
function updateFundTopupPreview() {
  const pv = $('fundTopupPreview'); if (!pv) return;
  const amtEl = document.querySelector('#fundTopupForm input[name="amount"]');
  const cents = parseDollarsStrict(amtEl?.value ?? '');
  if (cents === null || cents <= 0) { pv.textContent = 'Enter an amount to see the split.'; return; }
  const shortfall = currentFundData?.shortfall;
  if (shortfall === undefined || shortfall === null) { pv.textContent = 'Fund balance has not loaded yet — the server still covers anything owed back first when you save.'; return; }
  const s = applyShortfallToRelease(cents, shortfall);
  const covered = cents - s.releasedToFund;
  pv.textContent = `Split: ${formatCents(s.releasedToFund)} added to fund · ${formatCents(covered)} covers owed back · Owed back after ${formatCents(s.remainingShortfall)}.`;
}
document.querySelector('#fundTopupForm input[name="amount"]')?.addEventListener('input', updateFundTopupPreview);
// R12 Add Money submit: admin only (server-enforced), unchecked-by-
// default confirmation, busy control, and a per-submit client key so
// a double-tap or a retried submit after a network failure replays
// the same top-up instead of crediting twice.
let lastTopupAttempt = null; // { key, cents } for the in-flight/failed submit
$('fundTopupForm')?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const cents = parseDollarsStrict(f.amount.value);
  if (cents === null || cents <= 0) { showToast('Enter a positive amount.', true); return; }
  if (!$('fundTopupConfirm')?.checked) { showToast('Check the box to confirm you already put this money in checking.', true); return; }
  const submitBtn = f.querySelector('button[type="submit"]');
  if (submitBtn) submitBtn.disabled = true;
  const key = (lastTopupAttempt && lastTopupAttempt.cents === cents) ? lastTopupAttempt.key
    : (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`);
  lastTopupAttempt = { key, cents };
  const { data, error } = await supabase.rpc('add_fund_money', { p_household_id: household.household_id, p_amount_cents: cents, p_note: f.note.value.trim(), p_client_key: key });
  if (submitBtn) submitBtn.disabled = false;
  if (error) {
    console.warn('add_fund_money failed:', error.message);
    const notLive = /could not find|does not exist|schema cache/i.test(error.message || '');
    showToast(notLive ? 'Add money isn\'t live yet — the database step still needs approval.' : 'Could not save this top-up. Try again.', true);
    return;
  }
  lastTopupAttempt = null;
  f.reset();
  updateFundTopupPreview();
  const covered = data?.shortfall_covered_cents ?? null;
  const added = data?.fund_added_cents ?? null;
  showToast((covered !== null && added !== null)
    ? `Top-up saved: ${formatCents(covered)} covered owed back, ${formatCents(added)} added to fund.`
    : 'Top-up saved.');
  await refresh();
});
$('fundAllocateForm')?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const cents = parseDollarsStrict(f.amount.value);
  if (cents === null || cents <= 0) { showToast('Enter a positive amount.', true); return; }
  // R1 busy control: block repeat submits while the allocation (and
  // any override retry) is in flight, so one tap cannot spend twice.
  const submitBtn = f.querySelector('button[type="submit"]');
  if (submitBtn) submitBtn.disabled = true;
  let { error } = await supabase.rpc('allocate_fund', { p_household_id: household.household_id, p_amount_cents: cents, p_note: f.note.value.trim(), p_override_reason: null });
  if (error && /insufficient fund/i.test(error.message)) {
    const reason = await showSheet({ title: 'Fund is short', message: `The fund does not cover ${formatCents(cents)}. Record it anyway with a typed reason — it will be logged.`, inputLabel: 'Reason for overriding', confirmLabel: 'Record anyway', cancelLabel: 'Cancel' });
    if (reason === null) { if (submitBtn) submitBtn.disabled = false; return; }
    ({ error } = await supabase.rpc('allocate_fund', { p_household_id: household.household_id, p_amount_cents: cents, p_note: f.note.value.trim(), p_override_reason: reason.trim() }));
  }
  if (submitBtn) submitBtn.disabled = false;
  if (error) console.warn('allocate_fund failed:', error.message);
  showToast(error ? 'Could not record fund spending. Try again.' : 'Fund spending recorded.', !!error);
  if (!error) { f.reset(); await refresh(); }
});
$('fundRequestForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const cents = parseDollarsStrict(f.amount.value);
  if (cents === null || cents <= 0) { await showAlert('Invalid amount', 'Enter a positive amount.'); return; }
  // R1 busy control: block repeat submits while the request is saving.
  const submitBtn = f.querySelector('button[type="submit"]');
  if (submitBtn) submitBtn.disabled = true;
  const { data: { user } } = await supabase.auth.getUser();
  const { error } = await supabase.from('fund_requests').insert({
    household_id: household.household_id, requested_by: user.id,
    amount_cents: cents, note: f.note.value.trim(), status: 'pending',
  });
  if (error) { console.warn('fund request insert failed:', error.message); await showAlert('Could not save request', 'Could not save this request. Try again.'); if (submitBtn) submitBtn.disabled = false; return; }
  await audit('Extra Fund request created', `Requested ${formatCents(cents)}.`);
  f.reset(); if (submitBtn) submitBtn.disabled = false; await refresh();
});


// Task 5: save the current page's scroll position when the app is
// closed or refreshed, so the next load can restore it (see boot()).
window.addEventListener('beforeunload', () => {
  try { localStorage.setItem(scrollStorageKey(currentView), String(window.scrollY || 0)); } catch (e) { /* private mode */ }
});

boot();
