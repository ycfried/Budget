// Household Budget PWA — demo front end. Uses the SAME engine as the server
// (engine.mjs). No external network calls, no analytics, no real data.
// State lives in localStorage under 'hb-demo-v1' and is fake demo data only.
import {
  computeWeek, weekStartOf, addDays, weekStartsBetween, surplusReleaseDate,
  applyShortfallToRelease, nyTodayString, formatCents, isWeekLocked,
} from './engine.mjs';

const KEY = 'hb-demo-v1';
const $ = (id) => document.getElementById(id);
const uid = () => `demo_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
const dollarsToCents = (s) => Math.round(Number(s) * 100);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// --- Seeded demo data (fake merchants, suffixes only) -----------------------
// Weeks: 2026-10-11 (surplus $75, released 2026-10-25), 2026-10-18 (surplus
// $55, released 2026-11-01), 2026-10-25 (surplus $92.35, pending to 2026-11-08),
// current week 2026-11-01 (charges $138.05 gross, $20 refund -> net $118.05).
function seed() {
  const tx = (date, merchant, amountCents, suffix, source, state, kind = 'charge') => ({
    id: uid(), date, merchant, amountCents, suffix, source, state, kind,
    fundAllocation: 0, excluded: false, excludeReason: '', late: false,
  });
  const transactions = [
    tx('2026-10-12', 'FAKE CORNER MARKET', 18400, '1005', 'csv', 'verified'),
    tx('2026-10-14', 'FAKE FUEL STOP', 6200, '1005', 'csv', 'verified'),
    tx('2026-10-16', 'FAKE PHARMACY', 5400, '2007', 'csv', 'verified'),
    tx('2026-10-19', 'FAKE GROCERY OUTLET', 19800, '1005', 'csv', 'verified'),
    tx('2026-10-21', 'FAKE FUEL STOP', 5800, '2007', 'csv', 'verified'),
    tx('2026-10-23', 'FAKE HARDWARE', 6400, '1005', 'csv', 'verified'),
    tx('2026-10-26', 'FAKE CORNER MARKET', 8240, '1005', 'csv', 'verified'),
    tx('2026-10-27', 'FAKE FUEL STOP', 4500, '1005', 'email-alert', 'provisional'),
    tx('2026-10-28', 'FAKE SNACK STAND', 1500, '2007', 'csv', 'verified'),
    tx('2026-10-29', 'FAKE PHARMACY', 3215, '2007', 'csv', 'verified'),
    tx('2026-10-30', 'FAKE RESTAURANT', 6890, '1005', 'csv', 'verified'),
    tx('2026-10-31', 'FAKE CORNER MARKET', 5420, '1005', 'csv', 'verified'),
    tx('2026-10-30', 'FAKE CORNER MARKET RETURN', -1500, '1005', 'csv', 'verified', 'refund'),
    tx('2026-11-01', 'FAKE CORNER MARKET', 9630, '1005', 'email-alert', 'provisional'),
    tx('2026-11-01', 'FAKE COFFEE STAND', 4175, '2007', 'manual', 'provisional'),
    tx('2026-11-01', 'FAKE GROCERY RETURN', -2000, '1005', 'csv', 'verified', 'refund'),
  ];
  return {
    role: null,
    settings: { baseAllowance: 37500, temp: { amount: 0, reason: '', weekStart: null } },
    transactions,
    allocations: [],
    fundRequests: [{
      id: uid(), txId: transactions[12].id, amountCents: 4000, note: 'Demo request: pay part of groceries from the fund',
      status: 'pending', by: 'member', createdAt: new Date().toISOString(), decisionNote: '',
    }],
    savings: { confirmedTransfers: 7500, actualBalance: 7500, interest: 0 },
    shortfall: 0,
    importedHashes: [],
    lastSync: new Date().toISOString(),
    audit: [
      { at: new Date().toISOString(), actor: 'system', action: 'Demo data seeded', detail: 'Fake transactions spanning weeks 2026-10-11 to 2026-11-01.' },
      { at: new Date().toISOString(), actor: 'member', action: 'Extra Fund request created', detail: 'Request $40.00 against FAKE CORNER MARKET (2026-11-01).' },
    ],
  };
}

let state = load();
function load() {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return JSON.parse(raw);
  } catch { /* corrupted demo state: reseed */ }
  const s = seed();
  localStorage.setItem(KEY, JSON.stringify(s));
  return s;
}
function save() { localStorage.setItem(KEY, JSON.stringify(state)); }
function audit(actor, action, detail) {
  state.audit.unshift({ at: new Date().toISOString(), actor, action, detail });
  save();
}
const actorName = () => (state.role === 'admin' ? 'admin' : 'member');
const isAdmin = () => state.role === 'admin';

// --- Week computation (single chain, engine.mjs only) ------------------------
function weekGroups() {
  const today = nyTodayString();
  const currentWeek = weekStartOf(today);
  const groups = {}; // weekStart -> { gross, refunds, txs }
  for (const t of state.transactions) {
    if (t.excluded) continue;
    let w = weekStartOf(t.date);
    let late = false;
    if (w !== currentWeek && isWeekLocked(w, currentWeek)) {
      // Locked-week rule: keeps its true date, posts as an adjustment in the
      // current week; locked history never changes.
      w = currentWeek; late = true;
    }
    groups[w] = groups[w] || { gross: 0, refunds: 0, txs: [] };
    const effective = t.kind === 'refund'
      ? t.amountCents
      : Math.max(0, t.amountCents - (t.fundAllocation || 0));
    if (t.kind === 'refund') groups[w].refunds += Math.abs(t.amountCents);
    else groups[w].gross += effective;
    groups[w].txs.push({ ...t, late });
  }
  return { groups, currentWeek, today };
}

function computeAll() {
  const { groups, currentWeek, today } = weekGroups();
  const weekList = Object.keys(groups);
  const firstWeek = weekList.length
    ? weekList.sort()[0]
    : currentWeek;
  const weeks = weekStartsBetween(firstWeek < currentWeek ? firstWeek : currentWeek, currentWeek);
  let D = 0; // No credit chain in the demo: week inputs are B/T/D/C only.
  const results = {};
  for (const w of weeks) {
    const g = groups[w] || { gross: 0, refunds: 0 };
    const net = g.gross - g.refunds;
    const C = Math.max(0, net);
    const B = w === currentWeek ? state.settings.baseAllowance : 37500;
    const temp = state.settings.temp;
    const T = temp && temp.weekStart === w ? temp.amount : 0;
    // Excess refunds (X) create no credit in the demo: they are not
    // passed to the engine and are not displayed anywhere.
    const res = computeWeek({ B, T, D, C });
    results[w] = { ...res, weekStart: w, gross: g.gross, refunds: g.refunds };
    D = res.outgoingDebt;
  }
  // Fund releases (closed weeks only), in chronological order, netting any
  // outstanding shortfall before money becomes spendable.
  let shortfall = state.shortfall || 0;
  let releasedTotal = 0, pendingTotal = 0;
  const releases = [];
  for (const w of weeks) {
    if (w >= currentWeek) continue;
    const amount = results[w].earnedSurplus;
    if (amount <= 0) continue;
    const releaseDate = surplusReleaseDate(w);
    if (today >= releaseDate) {
      const net = applyShortfallToRelease(amount, shortfall);
      shortfall = net.remainingShortfall;
      releasedTotal += net.releasedToFund;
      releases.push({ weekStart: w, amount, releaseDate, status: 'released', releasedToFund: net.releasedToFund });
    } else {
      pendingTotal += amount;
      releases.push({ weekStart: w, amount, releaseDate, status: 'pending', releasedToFund: 0 });
    }
  }
  const fundSpent = state.allocations.reduce((s, a) => s + a.amountCents, 0);
  const fundAvailable = Math.max(0, releasedTotal - fundSpent);
  return {
    current: results[currentWeek], results, weeks, currentWeek, today,
    fund: { available: fundAvailable, pending: pendingTotal, spent: fundSpent, shortfall, releases },
  };
}

// --- Rendering ----------------------------------------------------------------
function render() {
  const signedIn = !!state.role;
  $('view-signin').classList.toggle('hidden', signedIn);
  document.querySelectorAll('.tabpane').forEach((el) => el.classList.toggle('hidden', !signedIn || el.id !== `tab-${currentTab}`));
  $('roleBadge').textContent = signedIn ? (isAdmin() ? 'DEMO · ADMIN' : 'DEMO · MEMBER') : 'DEMO';
  // Member never sees the Settings tab; server enforces this too.
  document.querySelectorAll('.admin-tab').forEach((el) => { el.style.display = isAdmin() || !signedIn ? '' : 'none'; });
  if (!signedIn) return;
  const all = computeAll();
  const cur = all.current;
  $('weekLabel').textContent = `Week of ${all.currentWeek} (Sun–Sat, America/New_York)`;
  const availEl = $('weeklyAvailable');
  availEl.textContent = formatCents(cur.available);
  availEl.classList.toggle('negative', cur.available < 0);
  $('statAllowance').textContent = formatCents(cur.B);
  $('statSpent').textContent = formatCents(cur.C);
  $('statDebt').textContent = formatCents(cur.D);
  $('statFund').textContent = formatCents(all.fund.available);
  $('statPending').textContent = formatCents(all.fund.pending);
  $('lastSync').textContent = new Date(state.lastSync).toLocaleString();
  const prov = state.transactions.filter((t) => t.state === 'provisional').length;
  const ver = state.transactions.filter((t) => t.state === 'verified').length;
  $('sourceCounts').textContent = `${prov} provisional, ${ver} verified, ${state.transactions.length} total`;
  $('syncList').innerHTML = [
    `<li>Amex alerts (demo): <strong>not connected</strong> — synthetic samples only</li>`,
    `<li>Plaid / CSV sync: <strong>CSV available, Plaid not connected</strong></li>`,
    `<li>Last refresh: ${esc(new Date(state.lastSync).toLocaleString())}</li>`,
    `<li>Fund releases: ${all.fund.releases.map((r) => `${r.weekStart} ${formatCents(r.amount)} → ${r.status} ${r.releaseDate}`).join(' · ') || 'none yet'}</li>`,
  ].join('');
  $('fundAvailable').textContent = formatCents(all.fund.available);
  $('fundPending').textContent = formatCents(all.fund.pending);
  $('fundSpent').textContent = formatCents(all.fund.spent);
  $('fundShortfall').textContent = formatCents(all.fund.shortfall);
  $('savFund').textContent = formatCents(all.fund.available);
  $('savEarned').textContent = formatCents(all.fund.available - state.savings.confirmedTransfers);
  $('savActual').textContent = formatCents(state.savings.actualBalance);
  $('savInterest').textContent = formatCents(state.savings.interest);
  document.querySelectorAll('.admin-only-card').forEach((el) => { el.style.display = isAdmin() ? '' : 'none'; });
  renderTransactions(all);
  renderFund(all);
  renderAudit();
  renderSettings();
}

let currentTab = 'dashboard';
function showTab(name) {
  currentTab = name;
  document.querySelectorAll('.tab').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
  render();
}
document.querySelectorAll('.tab').forEach((b) => b.addEventListener('click', () => showTab(b.dataset.tab)));

function txRow(t) {
  const fundNote = t.fundAllocation ? ` · Fund: ${formatCents(t.fundAllocation)}` : '';
  const lateNote = t.late ? ' · LATE (locked-week adjustment)' : '';
  const actions = [];
  if (!t.excluded) {
    if (!isAdmin()) actions.push(`<button class="btn btn-small" data-req="${t.id}" type="button">Request fund</button>`);
    if (isAdmin()) {
      actions.push(`<button class="btn btn-small" data-alloc="${t.id}" type="button">Allocate from fund</button>`);
      actions.push(`<button class="btn btn-small" data-excl="${t.id}" type="button">Exclude</button>`);
    }
  } else {
    actions.push(`<span class="pill warn">EXCLUDED</span>`);
    if (isAdmin()) actions.push(`<button class="btn btn-small" data-restore="${t.id}" type="button">Restore</button>`);
  }
  return `<li><div><strong>${esc(t.merchant)}</strong>
    <span class="pill ${t.state === 'provisional' ? 'warn' : 'ok'}">${t.state.toUpperCase()}</span>
    <span class="pill">${esc(t.source.toUpperCase())}</span></div>
    <div><span class="tx-amount ${t.amountCents < 0 ? 'negative' : ''}">${formatCents(t.amountCents)}</span>
    · ${esc(t.date)} · ••${esc(t.suffix)}${fundNote}${lateNote}</div>
    <div>${actions.join(' ')}</div></li>`;
}

function renderTransactions() {
  const q = ($('txSearch').value || '').toLowerCase();
  const f = $('txFilter').value;
  const { currentWeek } = weekGroups();
  let list = [...state.transactions].sort((a, b) => (b.date < a.date ? -1 : b.date > a.date ? 1 : 0));
  if (q) list = list.filter((t) => t.merchant.toLowerCase().includes(q));
  if (f === 'current') list = list.filter((t) => weekStartOf(t.date) === currentWeek);
  if (f === 'provisional') list = list.filter((t) => t.state === 'provisional');
  if (f === 'verified') list = list.filter((t) => t.state === 'verified');
  if (f === 'refunds') list = list.filter((t) => t.kind === 'refund');
  if (f === 'fund') list = list.filter((t) => (t.fundAllocation || 0) > 0);
  $('txList').innerHTML = list.length ? list.map(txRow).join('') : '<li>No transactions match.</li>';
  $('txList').querySelectorAll('[data-req]').forEach((b) => b.addEventListener('click', () => {
    const t = state.transactions.find((x) => x.id === b.dataset.req);
    const amt = window.prompt(`Request how much from the Extra Fund for ${t.merchant}? (dollars)`, '40');
    if (amt === null) return;
    const cents = dollarsToCents(amt);
    if (!(cents > 0)) return;
    state.fundRequests.unshift({ id: uid(), txId: t.id, amountCents: cents, note: 'Requested from transaction row', status: 'pending', by: 'member', createdAt: new Date().toISOString(), decisionNote: '' });
    audit('member', 'Extra Fund request created', `Requested ${formatCents(cents)} for ${t.merchant}.`);
    save(); render();
  }));
  $('txList').querySelectorAll('[data-alloc]').forEach((b) => b.addEventListener('click', () => {
    const t = state.transactions.find((x) => x.id === b.dataset.alloc);
    const amt = window.prompt(`Allocate how much from the Extra Fund to ${t.merchant}? (dollars)`, '40');
    if (amt === null) return;
    allocate(t, dollarsToCents(amt), 'Direct admin allocation');
  }));
  $('txList').querySelectorAll('[data-excl]').forEach((b) => b.addEventListener('click', () => {
    const t = state.transactions.find((x) => x.id === b.dataset.excl);
    const reason = window.prompt(`Exclude ${t.merchant} — reason (required):`, '');
    if (!reason) return;
    t.excluded = true; t.excludeReason = reason;
    audit('admin', 'Transaction excluded', `${t.merchant} ${formatCents(t.amountCents)} — reason: ${reason}`);
    save(); render();
  }));
  $('txList').querySelectorAll('[data-restore]').forEach((b) => b.addEventListener('click', () => {
    const t = state.transactions.find((x) => x.id === b.dataset.restore);
    t.excluded = false; t.excludeReason = '';
    audit('admin', 'Transaction restored', `${t.merchant} restored to the budget.`);
    save(); render();
  }));
  // Fund request transaction dropdown
  $('fundTxSelect').innerHTML = state.transactions
    .filter((t) => t.kind !== 'refund' && !t.excluded)
    .map((t) => `<option value="${t.id}">${esc(t.date)} · ${esc(t.merchant)} · ${formatCents(t.amountCents)}</option>`).join('');
}

function allocate(t, cents, note) {
  const all = computeAll();
  if (!(cents > 0)) { alert('Amount must be positive.'); return; }
  if (cents > all.fund.available) {
    alert(`Blocked: the Extra Fund has ${formatCents(all.fund.available)} available, which is less than ${formatCents(cents)}. Allocation blocked with explanation (no override without a typed reason, logged).`);
    audit('admin', 'Fund allocation blocked', `Tried ${formatCents(cents)} for ${t.merchant}; fund available ${formatCents(all.fund.available)}.`);
    save(); render(); return;
  }
  t.fundAllocation = (t.fundAllocation || 0) + cents;
  state.allocations.unshift({ id: uid(), txId: t.id, amountCents: cents, by: 'admin', at: new Date().toISOString(), note });
  audit('admin', 'Fund allocation approved', `${formatCents(cents)} allocated to ${t.merchant}. ${note}`);
  save(); render();
}

function renderFund() {
  const all = computeAll();
  $('fundQueue').innerHTML = state.fundRequests.length ? state.fundRequests.map((r) => {
    const t = state.transactions.find((x) => x.id === r.txId);
    const controls = r.status === 'pending' && isAdmin()
      ? `<div><input class="alloc-amt" data-id="${r.id}" type="number" step="0.01" min="0.01" value="${(r.amountCents / 100).toFixed(2)}">
         <button class="btn btn-small" data-approve="${r.id}" type="button">Approve / split</button>
         <button class="btn btn-small" data-decline="${r.id}" type="button">Decline</button></div>`
      : `<span class="pill ${r.status === 'approved' ? 'ok' : r.status === 'declined' ? 'warn' : ''}">${r.status.toUpperCase()}</span>${r.decisionNote ? ` · ${esc(r.decisionNote)}` : ''}`;
    return `<li><strong>${t ? esc(t.merchant) : 'Unknown transaction'}</strong> — requested ${formatCents(r.amountCents)} · ${esc(r.note || '')}<br>${controls}</li>`;
  }).join('') : '<li>No fund requests.</li>';
  $('fundQueue').querySelectorAll('[data-approve]').forEach((b) => b.addEventListener('click', () => {
    const r = state.fundRequests.find((x) => x.id === b.dataset.approve);
    const input = document.querySelector(`.alloc-amt[data-id="${r.id}"]`);
    const cents = dollarsToCents(input.value);
    const t = state.transactions.find((x) => x.id === r.txId);
    if (cents > r.amountCents) { alert('Split allocation cannot exceed the requested amount.'); return; }
    const before = computeAll().fund.available;
    if (cents > before) { alert(`Blocked: fund available is ${formatCents(before)}.`); return; }
    r.status = 'approved'; r.decisionNote = `Approved ${formatCents(cents)} of ${formatCents(r.amountCents)}.`;
    t.fundAllocation = (t.fundAllocation || 0) + cents;
    state.allocations.unshift({ id: uid(), txId: t.id, amountCents: cents, by: 'admin', at: new Date().toISOString(), note: 'Approved member request' });
    audit('admin', 'Fund request approved', `${formatCents(cents)} for ${t.merchant} (requested ${formatCents(r.amountCents)}).`);
    save(); render();
  }));
  $('fundQueue').querySelectorAll('[data-decline]').forEach((b) => b.addEventListener('click', () => {
    const r = state.fundRequests.find((x) => x.id === b.dataset.decline);
    r.status = 'declined'; r.decisionNote = 'Declined by admin.';
    audit('admin', 'Fund request declined', `Request ${formatCents(r.amountCents)} declined.`);
    save(); render();
  }));
  $('fundAllocations').innerHTML = state.allocations.length ? state.allocations.map((a) => {
    const t = state.transactions.find((x) => x.id === a.txId);
    return `<li>${formatCents(a.amountCents)} → ${t ? esc(t.merchant) : 'unknown'} · ${esc(new Date(a.at).toLocaleString())} · ${esc(a.note)}</li>`;
  }).join('') : '<li>No allocations yet.</li>';
  // Member request form visibility: members request, admins approve.
  $('fundRequestCard').style.display = isAdmin() ? 'none' : '';
}

function renderAudit() {
  $('auditList').innerHTML = state.audit.map((a) =>
    `<li><strong>${esc(a.action)}</strong> <span class="muted">(${esc(a.actor)} · ${esc(new Date(a.at).toLocaleString())})</span><br>${esc(a.detail)}</li>`).join('');
}

function renderSettings() {
  if (!isAdmin()) return;
  $('settingsForm').base.value = (state.settings.baseAllowance / 100).toFixed(0);
  $('settingsForm').temp.value = state.settings.temp.amount ? (state.settings.temp.amount / 100).toFixed(0) : '';
  $('settingsForm').tempReason.value = state.settings.temp.reason || '';
  $('excludedList').innerHTML = state.transactions.filter((t) => t.excluded).map((t) =>
    `<li>${esc(t.merchant)} ${formatCents(t.amountCents)} — reason: ${esc(t.excludeReason)}</li>`).join('') || '<li>None excluded.</li>';
}

// --- Events -------------------------------------------------------------------
$('signinAdmin').addEventListener('click', () => { state.role = 'admin'; audit('admin', 'Demo sign-in', 'Signed in as Owner (admin) — demo only.'); save(); showTab('dashboard'); });
$('signinMember').addEventListener('click', () => { state.role = 'member'; audit('member', 'Demo sign-in', 'Signed in as Spouse (member) — demo only.'); save(); showTab('dashboard'); });
$('switchUserBtn').addEventListener('click', () => { state.role = null; save(); render(); });
$('refreshBtn').addEventListener('click', () => { state.lastSync = new Date().toISOString(); save(); render(); });
$('txSearch').addEventListener('input', render);
$('txFilter').addEventListener('change', render);

$('manualForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const f = e.target;
  const amount = dollarsToCents(f.amount.value);
  const suffix = f.suffix.value.trim();
  if (!/^\d{4}$/.test(suffix)) { alert('Card suffix must be exactly 4 digits. Never enter a full card number.'); return; }
  state.transactions.unshift({
    id: uid(), date: f.date.value, merchant: f.merchant.value.trim().toUpperCase(),
    amountCents: amount, suffix, source: 'manual', state: 'provisional', kind: 'charge',
    fundAllocation: 0, excluded: false, excludeReason: '', late: false,
  });
  audit(actorName(), 'Manual provisional purchase added', `${f.merchant.value.trim()} ${formatCents(amount)} on ${f.date.value} (••${suffix}).`);
  f.reset(); save(); render();
});

// CSV import
function fnvHash(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return (h >>> 0).toString(16);
}
function parseAmount(raw) {
  let s = String(raw).trim().replace(/[$,]/g, '');
  let neg = false;
  if (s.startsWith('(') && s.endsWith(')')) { neg = true; s = s.slice(1, -1); }
  const n = Number(s);
  if (!Number.isFinite(n)) return null;
  return Math.round(Math.abs(n) * 100) * (neg || n < 0 ? -1 : 1);
}
function parseCsv(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim());
  if (lines.length < 2) return { added: 0, skipped: 0, errors: ['CSV needs a header row and at least one data row.'] };
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
  if (di < 0 || mi < 0 || ai < 0) return { added: 0, skipped: 0, errors: ['Header must include Date, Description, and Amount columns.'] };
  let added = 0, skipped = 0; const errors = [];
  for (const line of lines.slice(1)) {
    const cols = split(line);
    const dateRaw = cols[di] || '';
    const merchant = (cols[mi] || '').toUpperCase();
    const cents = parseAmount(cols[ai] || '');
    const suffixMatch = si >= 0 ? String(cols[si] || '').match(/(\d{4})\s*$/) : null;
    const suffix = suffixMatch ? suffixMatch[1] : '0000';
    // Normalize date to YYYY-MM-DD (accepts YYYY-MM-DD and MM/DD/YYYY).
    let date = dateRaw;
    const mdy = dateRaw.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
    if (mdy) date = `${mdy[3]}-${mdy[1].padStart(2, '0')}-${mdy[2].padStart(2, '0')}`;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !merchant || cents === null) { errors.push(`Skipped unparseable row: ${line}`); continue; }
    const hash = fnvHash(`${date}|${merchant}|${cents}|${suffix}`);
    if (state.importedHashes.includes(hash) || state.transactions.some((t) => fnvHash(`${t.date}|${t.merchant}|${t.amountCents}|${t.suffix}`) === hash)) { skipped++; continue; }
    state.importedHashes.push(hash);
    state.transactions.unshift({
      id: uid(), date, merchant, amountCents: cents, suffix, source: 'csv', state: 'verified',
      kind: cents < 0 ? 'refund' : 'charge', fundAllocation: 0, excluded: false, excludeReason: '', late: false,
    });
    added++;
  }
  return { added, skipped, errors };
}
$('csvFile').addEventListener('change', async (e) => {
  const file = e.target.files[0]; if (!file) return;
  const text = await file.text();
  const res = parseCsv(text);
  $('csvResult').textContent = `Import result: ${res.added} added, ${res.skipped} skipped as duplicates.${res.errors.length ? `\n${res.errors.join('\n')}` : ''}`;
  $('csvResult').classList.toggle('error', res.errors.length > 0);
  audit(actorName(), 'CSV import', `${res.added} added, ${res.skipped} duplicates skipped.`);
  save(); render();
});
$('csvSampleBtn').addEventListener('click', () => {
  const sample = `Date,Description,Amount,Card Ending\n2026-11-01,FAKE SAMPLE STORE,23.50,1005\n2026-11-01,FAKE SAMPLE STORE,23.50,1005\n`;
  const res = parseCsv(sample);
  $('csvResult').textContent = `Sample CSV result: ${res.added} added, ${res.skipped} skipped as duplicates (the second identical row is a duplicate — re-running this sample adds 0).`;
  audit(actorName(), 'CSV import (sample)', `${res.added} added, ${res.skipped} duplicates skipped.`);
  save(); render();
});

// Synthetic alert ingest — fails closed.
$('alertSampleBtn').addEventListener('click', () => {
  $('alertText').value = 'AMEX ALERT: A purchase of $42.18 at FAKE CORNER MARKET on November 1, 2026 using your card ending ••1005 was approved. SYNTHETIC SAMPLE — not a live email.';
});
$('alertParseBtn').addEventListener('click', () => {
  const text = $('alertText').value;
  const amt = text.match(/\$([\d,]+\.\d{2})/);
  const merch = text.match(/at\s+([A-Z][A-Za-z0-9 '&.\-]{2,60}?)(?:\s+on\s+|\s+using\s+|\s+was\s+|\.|$)/);
  const dateM = text.match(/on\s+([A-Z][a-z]+ \d{1,2}, \d{4})/) || text.match(/(\d{4}-\d{2}-\d{2})/);
  const suf = text.match(/ending\s+•*(\d{4})/) || text.match(/••(\d{4})/);
  if (!amt || !merch || !dateM || !suf) {
    $('alertResult').textContent = 'QUARANTINED — could not parse amount, merchant, date, and card suffix confidently. No transaction created. (Parser fails closed; ambiguous messages are never guessed.)';
    $('alertResult').classList.add('error');
    audit(actorName(), 'Synthetic alert quarantined', 'Unparseable sample alert text; nothing created.');
    save(); return;
  }
  let date = dateM[1];
  if (!/^\d{4}-/.test(date)) {
    const d = new Date(date);
    date = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }
  const cents = dollarsToCents(amt[1].replace(/,/g, ''));
  const merchant = merch[1].trim().toUpperCase();
  const hash = fnvHash(`${date}|${merchant}|${cents}|${suf[1]}`);
  if (state.importedHashes.includes(hash)) {
    $('alertResult').textContent = 'Duplicate synthetic alert — already imported. No second transaction created.';
    save(); render(); return;
  }
  state.importedHashes.push(hash);
  state.transactions.unshift({
    id: uid(), date, merchant, amountCents: cents, suffix: suf[1], source: 'synthetic-alert',
    state: 'provisional', kind: 'charge', fundAllocation: 0, excluded: false, excludeReason: '', late: false,
  });
  $('alertResult').textContent = `Parsed as PROVISIONAL: ${merchant} ${formatCents(cents)} on ${date} (••${suf[1]}). Source: SYNTHETIC SAMPLE — not a live Gmail alert.`;
  $('alertResult').classList.remove('error');
  audit(actorName(), 'Synthetic alert ingested', `${merchant} ${formatCents(cents)} on ${date} (••${suf[1]}) as PROVISIONAL.`);
  save(); render();
});

$('fundRequestForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const f = e.target;
  const cents = dollarsToCents(f.amount.value);
  state.fundRequests.unshift({ id: uid(), txId: f.txId.value, amountCents: cents, note: f.note.value.trim(), status: 'pending', by: 'member', createdAt: new Date().toISOString(), decisionNote: '' });
  const t = state.transactions.find((x) => x.id === f.txId.value);
  audit('member', 'Extra Fund request created', `Requested ${formatCents(cents)} for ${t ? t.merchant : 'a transaction'}.`);
  f.reset(); save(); render();
});

$('settingsForm').addEventListener('submit', (e) => {
  e.preventDefault();
  if (!isAdmin()) { alert('Admin only.'); return; }
  const f = e.target;
  const oldBase = state.settings.baseAllowance;
  state.settings.baseAllowance = dollarsToCents(f.base.value);
  const tempAmt = f.temp.value ? dollarsToCents(f.temp.value) : 0;
  state.settings.temp = tempAmt > 0
    ? { amount: tempAmt, reason: f.tempReason.value.trim(), weekStart: weekStartOf(nyTodayString()) }
    : { amount: 0, reason: '', weekStart: null };
  audit('admin', 'Settings saved', `Base allowance ${formatCents(oldBase)} → ${formatCents(state.settings.baseAllowance)}; temporary increase ${formatCents(tempAmt)} (${f.tempReason.value.trim() || 'no reason'}).`);
  save(); render();
});
$('inviteBtn').addEventListener('click', () => {
  audit('admin', 'Invite placeholder used', 'Member invite placeholder viewed — no email was sent (demo).');
  alert('Demo placeholder: no invitation was sent. The real invite flow is not wired in this prototype.');
  save(); render();
});

function savingsMove(kind, cents) {
  if (!isAdmin()) { alert('Admin only.'); return; }
  if (kind === 'in') { state.savings.confirmedTransfers += cents; state.savings.actualBalance += cents; }
  if (kind === 'out') { state.savings.confirmedTransfers -= cents; state.savings.actualBalance -= cents; }
  if (kind === 'interest') { state.savings.interest += cents; state.savings.actualBalance += cents; }
  audit('admin', `Savings ${kind} recorded`, `${formatCents(cents)} (manual attestation, demo). This app never moves money.`);
  save(); render();
}
$('savInForm').addEventListener('submit', (e) => { e.preventDefault(); savingsMove('in', dollarsToCents(e.target.amount.value)); e.target.reset(); });
$('savOutForm').addEventListener('submit', (e) => { e.preventDefault(); savingsMove('out', dollarsToCents(e.target.amount.value)); e.target.reset(); });
$('savInterestForm').addEventListener('submit', (e) => { e.preventDefault(); savingsMove('interest', dollarsToCents(e.target.amount.value)); e.target.reset(); });

// Service worker (PWA installability). Fails silently on file:// previews.
if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}

render();
