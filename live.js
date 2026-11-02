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
// The demo (index.html / app.js) is untouched and still runs on fake data.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';
import { formatCents, weekStartOf, nyTodayString } from './engine.mjs';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const dollarsToCents = (s) => Math.round(Number(s) * 100);
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
let currentWeekInputs = null;
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
  // Temporary increases for the current week (sum of grants) are passed
  // as T to compute-week; without this the engine defaults T to 0.
  let tempTotal = 0;
  let weekStartForTemp = null;
  try {
    // Current Sunday in America/New_York, computed client-side so the
    // temp sum is available BEFORE compute-week runs (its response is
    // what sets the week label, so reading the label here is circular).
    const ny = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/New_York' }));
    const sunday = new Date(ny); sunday.setDate(ny.getDate() - ny.getDay());
    weekStartForTemp = `${sunday.getFullYear()}-${String(sunday.getMonth() + 1).padStart(2, '0')}-${String(sunday.getDate()).padStart(2, '0')}`;
    if (weekStartForTemp) {
      const { data: temps } = await supabase.from('temp_increases')
        .select('amount_cents').eq('household_id', household.household_id)
        .eq('week_start', weekStartForTemp);
      tempTotal = (temps ?? []).reduce((sum, r) => sum + (r.amount_cents || 0), 0);
    }
  } catch (e) { console.warn('temp increase read failed:', e); }
  // Weeks close themselves now (admin only, once per session): no more
  // "Process completed weeks" button for the user to remember. A failed
  // run retries on the next refresh instead of silently giving up.
  if (household.role === 'admin' && !weekCloseRan) {
    try {
      const out = await callFn('week-close', { household_id: household.household_id });
      if (!out.error) weekCloseRan = true;
    } catch (e) { /* retry next refresh */ }
  }
  // Week chain: the previous closed week's outgoing debt/credit carry
  // into this week (before this, every week wrongly started at $0).
  // A missing week_closes table (before the fund SQL lands) just means
  // the chain starts at zero — never a crash.
  let chainD = 0, chainR = 0;
  try {
    const { data: prev } = await supabase.from('week_closes')
      .select('outgoing_debt_cents, outgoing_credit_cents, week_start')
      .eq('household_id', household.household_id)
      .lt('week_start', weekStartForTemp ?? '9999-12-31')
      .order('week_start', { ascending: false }).limit(1).maybeSingle();
    if (prev) { chainD = prev.outgoing_debt_cents || 0; chainR = prev.outgoing_credit_cents || 0; }
  } catch (e) { /* chain unavailable; start at zero */ }
  // Week numbers from the server.
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/compute-week`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
      body: JSON.stringify({ household_id: household.household_id, T: tempTotal, D: chainD, R_in: chainR }),
    });
    const week = await res.json();
    const weekErr = document.getElementById('weekError');
    if (weekErr) {
      if (!week.result) { weekErr.textContent = "Couldn't update this week's numbers — switch tabs or reopen the app to try again."; weekErr.classList.remove('hidden'); }
      else weekErr.classList.add('hidden');
    }
    if (week.result) {
      $('weekLabel').textContent = `Week of ${fmtLong(week.week_start)} (Sun–Sat)`;
      $('weeklyAvailable').innerHTML = formatCentsHtml(week.result.available);
      // Spec: a negative available balance must be shown clearly.
      $('weeklyAvailable').classList.toggle('negative', week.result.available < 0);
      $('statAllowance').innerHTML = formatCentsHtml(week.result.B);
      $('statSpent').innerHTML = formatCentsHtml(week.result.C);
      $('statDebt').innerHTML = formatCentsHtml(week.result.D);
      $('statCredit').innerHTML = formatCentsHtml(week.result.outgoingCredit);
      currentWeekData = week.result; currentWeekInputs = { B: week.result.B, T: tempTotal, D: chainD, R_in: chainR };
      // Hero progress: spent this week against the weekly allowance.
      const budget = week.result.B + tempTotal;
      const pct = budget > 0 ? Math.min(100, Math.round((week.result.C / budget) * 100)) : 0;
      const bar = document.getElementById('weekProgressBar');
      if (bar) bar.style.width = `${pct}%`;
      const pt = document.getElementById('weekProgressText');
      if (pt) pt.textContent = `Spent ${formatCents(week.result.C)} of ${formatCents(budget)} allowance`;
      lastRefreshAt = Date.now();
      const allowInput = document.getElementById('baseAllowanceInput');
      if (allowInput && document.activeElement !== allowInput) allowInput.value = (week.result.B / 100).toFixed(2);
      $('finRefundNote').style.display = week.not_production_certified ? 'block' : 'none';
    }
  } catch (e) {
    console.warn('compute-week failed:', e);
    const weekErr2 = document.getElementById('weekError');
    if (weekErr2) { weekErr2.textContent = "Couldn't update this week's numbers — check your connection and try again."; weekErr2.classList.remove('hidden'); }
  }

  const { data: txns } = await supabase.from('transactions')
    .select('*').eq('household_id', household.household_id)
    .order('date', { ascending: false }).limit(txLimit);
  const all = txns ?? [];
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
    'amount-asc': (a, b) => a.amount_cents - b.amount_cents,
    'amount-desc': (a, b) => b.amount_cents - a.amount_cents,
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
      return `<option value="${m}"${m === txMonth ? ' selected' : ''}>${label}</option>`;
    }).join('');
  }
  const cardSel = $('txCard');
  if (cardSel) {
    const cards = [...new Set(all.map((t) => String(t.card_suffix)))].sort();
    const cur = cards.includes(txCard) ? txCard : 'all';
    if (cur !== txCard) { txCard = cur; localStorage.setItem('hb-tx-card', cur); }
    cardSel.innerHTML = '<option value="all">All cards</option>' + cards.map((c) =>
      `<option value="${c}"${c === txCard ? ' selected' : ''}>••${c}</option>`).join('');
  }
  const thisWeekTxns = all.filter((t) => inThisWeek(t) && !(t.excluded === true || t.state === 'excluded'));
  const emptyHintEl = document.getElementById('weekEmptyHint');
  if (emptyHintEl) emptyHintEl.classList.toggle('hidden', thisWeekTxns.length > 0);
  const countEl = $('txCount');
  if (countEl) {
    const shownTotal = shown.reduce((s, t) => s + t.amount_cents, 0);
    const capped = all.length >= txLimit ? ' of loaded purchases — tap Load more for older ones' : ' of loaded purchases';
    countEl.textContent = `Showing ${shown.length}${capped}${txWeekOnly ? ' · this week only' : ''} · total ${formatCents(shownTotal)}`;
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
  $('txList').innerHTML = shown.length
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
        const action = !isAdmin ? fundBtn
          : excluded
          ? `<div class="btn-row"><button class="btn btn-small" data-restore="${t.id}" type="button" aria-label="Restore ${esc(t.merchant)} to the week">Restore</button> ${deleteBtn}</div>`
          : `<div class="btn-row"><button class="btn btn-small" data-exclude="${t.id}" type="button" aria-label="Exclude ${esc(t.merchant)} from the week">Exclude</button> ${deleteBtn} ${fundBtn}</div>`;
        const neg = t.amount_cents < 0 ? ' negative' : '';
        return `<li class="tx-row ${excluded ? 'tx-excluded' : ''}"><div class="tx-head" data-tx-head="${t.id}" role="button" tabindex="0" aria-label="Show detail for ${esc(t.merchant)}"><div class="tx-line1"><span class="tx-icon" aria-hidden="true">${esc(t.merchant.charAt(0).toUpperCase())}</span><strong class="tx-name" title="${esc(t.merchant)}">${esc(t.merchant)}</strong><span class="tx-amount${neg}">${formatCents(t.amount_cents)}</span></div>
        <div class="tx-line2"><span class="pill ${t.state === 'provisional' ? 'warn' : 'ok'}">${excluded ? 'Excluded' : (t.state === 'provisional' ? 'Pending' : 'Posted')}</span>
        <span class="pill">${esc(sourceLabel(t.source))}</span>
        <span class="muted small tx-meta">${fmtShort(t.date)} · ••${esc(t.card_suffix)}</span> <span class="muted small">Tap for detail ▾</span></div></div>
        <div class="tx-detail hidden" id="tx-detail-${t.id}">
          <p class="small"><strong>${esc(t.merchant)}</strong> — ${formatCents(t.amount_cents)} (${t.kind === 'refund' ? 'Refund' : 'Purchase'})</p>
          <p class="small muted">Date: ${fmtLong(t.date)} · Counts in week: ${weekRangeOf(t.date)} (Sun–Sat)<br>
          Card: ••${esc(t.card_suffix)} · Source: ${esc(sourceLabel(t.source))} · Status: ${excluded ? 'excluded from week math' : (t.state === 'provisional' ? 'pending' : 'posted')}<br>
          ${excluded ? 'This purchase is kept for the record but does not count toward any week.' : 'This purchase counts toward its week unless excluded.'}</p>
          <div>${action}</div>
        </div></li>`;
      }).join('')
    : `<li class="tx-empty">${emptyHint}</li>`;
  // Home preview: the 4 newest purchases, tapping one jumps to Purchases.
  const recentEl = $('recentList');
  if (recentEl) {
    const recent = [...all].sort((a, b) => b.date.localeCompare(a.date)).slice(0, 4);
    recentEl.innerHTML = recent.length
      ? recent.map((t) => {
          const excluded = t.excluded === true || t.state === 'excluded';
          return `<li class="tx-row"><div class="tx-head" data-view="purchases" role="button" tabindex="0" aria-label="See ${esc(t.merchant)} in Purchases"><div class="tx-line1"><span class="tx-icon" aria-hidden="true">${esc(t.merchant.charAt(0).toUpperCase())}</span><strong class="tx-name" title="${esc(t.merchant)}">${esc(t.merchant)}</strong><span class="tx-amount${t.amount_cents < 0 ? ' negative' : ''}">${formatCents(t.amount_cents)}</span></div>
          <div class="tx-line2"><span class="pill ${t.state === 'provisional' ? 'warn' : 'ok'}">${excluded ? 'Excluded' : (t.state === 'provisional' ? 'Pending' : 'Posted')}</span>
          <span class="muted small tx-meta">${fmtShort(t.date)} · ••${esc(t.card_suffix)}</span></div></div></li>`;
        }).join('')
      : '<li class="muted small">No purchases yet.</li>';
    // Rows added after load need the same tab-switch handler as the nav.
    recentEl.querySelectorAll('[data-view]').forEach((el) => el.addEventListener('click', () => {
      showView(el.dataset.view);
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
    const counted = all.filter((t) => !(t.excluded === true || t.state === 'excluded'));
    const bySrc = {};
    for (const t of counted) bySrc[t.source] = (bySrc[t.source] ?? 0) + t.amount_cents;
    const refundTotal = counted.filter((t) => t.kind === 'refund').reduce((s, t) => s + t.amount_cents, 0);
    const panels = {
      allowance: `<strong>Weekly allowance ${formatCents(w.B)}</strong> plus ${formatCents(currentWeekInputs?.T ?? 0)} in temporary increases this week.`,
      spent: `<strong>Where this spending came from:</strong><br>${Object.entries(bySrc).map(([s, v]) => `${esc(sourceLabel(s))}: ${formatCents(v)}`).join(' · ') || 'nothing yet'}<br>Refunds in this list: ${formatCents(refundTotal)} · Excluded purchases kept out of the math: ${all.length - counted.length}`,
      debt: w.D > 0
        ? `<strong>${formatCents(w.D)} carried over</strong> from earlier weeks — it comes off the top of this week's allowance before anything else.`
        : 'No carried-over overspending: this week starts with the full allowance.',
      credit: w.outgoingCredit > 0
        ? `<strong>${formatCents(w.outgoingCredit)} in refund credit</strong> is still available — it covers spending after the allowance and any temporary increases run out.`
        : 'No refund credit available right now.',
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
    const cents = dollarsToCents(amountText);
    if (cents === null || cents <= 0) { await showAlert('Invalid amount', 'Enter a positive amount.'); return; }
    const { data: { user } } = await supabase.auth.getUser();
    const { error } = await supabase.from('fund_requests').insert({
      household_id: household.household_id, requested_by: user.id,
      amount_cents: cents, note: '', status: 'pending', transaction_id: b.dataset.useFund,
    });
    if (error) { await showAlert('Could not send request', error.message); return; }
    await audit('Extra Fund request created', `Requested ${formatCents(cents)} for ${row?.merchant ?? 'a purchase'}.`);
    await refresh();
  }));
  document.querySelectorAll('[data-exclude]').forEach((b) => b.addEventListener('click', async () => {
    // Spec A7: exclusion needs a reason, recorded in the audit log.
    const reason = ((await showSheet({ title: 'Exclude purchase', message: 'Why exclude this purchase? It stays in the list but stops counting toward the week.', inputLabel: 'Reason (optional)', confirmLabel: 'Exclude', cancelLabel: 'Keep it' })) ?? '').trim();
    const row = all.find((t) => t.id === b.dataset.exclude);
    const { error } = await supabase.from('transactions')
      .update({ state: 'excluded', excluded: true }).eq('id', b.dataset.exclude);
    if (error) { await showAlert('Could not exclude', error.message); return; }
    await audit('Transaction excluded', `${row ? row.merchant : 'Purchase'} ${row ? formatCents(row.amount_cents) : ''}${reason ? ` — reason: ${reason}` : ' — no reason given'}.`);
    await refresh();
  }));
  document.querySelectorAll('[data-restore]').forEach((b) => b.addEventListener('click', async () => {
    // Restore rule (documented choice): there is no stored pre-exclude
    // state, so a transaction dated before today is treated as posted
    // and today's (or future) as pending. A pending row restored this
    // way still becomes verified once the bank confirms it.
    const row = all.find((t) => t.id === b.dataset.restore);
    const today = nyTodayString();
    const state = row && row.date < today ? 'verified' : 'provisional';
    const { error } = await supabase.from('transactions')
      .update({ state, excluded: false }).eq('id', b.dataset.restore);
    if (error) { await showAlert('Could not restore', error.message); return; }
    await audit('Transaction restored', `${row ? row.merchant : 'Purchase'} returned to the week as ${state === 'provisional' ? 'pending' : 'posted'}.`);
    await refresh();
  }));

  document.querySelectorAll('[data-delete-tx]').forEach((b) => b.addEventListener('click', async () => {
    const row = all.find((t) => t.id === b.dataset.deleteTx);
    if (!row || !(await showConfirm('Delete purchase', `"${row.merchant}" ${formatCents(row.amount_cents)} — this removes the hand-entered purchase and cannot be undone.`, 'Delete'))) return;
    const { error } = await supabase.rpc('delete_transaction', { p_transaction_id: b.dataset.deleteTx });
    if (error) { await showAlert('Could not delete', error.message); return; }
    await refresh();
  }));
  document.querySelectorAll('[data-remove-tx]').forEach((b) => b.addEventListener('click', async () => {
    const row = all.find((t) => t.id === b.dataset.removeTx);
    if (!row || !(await showConfirm('Remove from budget', `"${row.merchant}" ${formatCents(row.amount_cents)} — the bank record stays with the bank; this only stops it counting here.`, 'Remove'))) return;
    const { error } = await supabase.from('transactions')
      .update({ state: 'excluded', excluded: true }).eq('id', b.dataset.removeTx);
    if (error) { await showAlert('Could not remove', error.message); return; }
    await audit('Transaction removed from budget', `${row.merchant} ${formatCents(row.amount_cents)} excluded from week math.`);
    await refresh();
  }));

  const { data: reqs } = await supabase.from('fund_requests')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(50);
  $('fundQueue').innerHTML = (reqs ?? []).length
    ? (reqs ?? []).map((r) => {
        const btns = (household.role === 'admin' && r.status === 'pending')
          ? `<div class="btn-row"><button class="btn btn-small btn-primary" data-approve="${r.id}" type="button" aria-label="Approve this Extra Fund request">Approve</button> <button class="btn btn-small btn-quiet" data-decline="${r.id}" type="button" aria-label="Decline this Extra Fund request">Decline</button></div>`
          : '';
        return `<li><div data-fund-head="${r.id}" role="button" tabindex="0" aria-label="Show detail for this Extra Fund request">${formatCents(r.amount_cents)} · ${esc(r.status.toUpperCase())} · ${esc(r.note || '')} <span class="muted small">Tap for detail ▾</span></div>
        <div class="tx-detail hidden" id="fund-detail-${r.id}">
          <p class="small muted">Amount: ${formatCents(r.amount_cents)} · Status: ${esc(r.status)}<br>
          Note: ${esc(r.note || '—')}<br>
          Requested: ${fmtDateTime(r.created_at)}<br>
          ${r.status === 'pending' ? 'Waiting on the admin decision.' : r.status === 'approved' ? 'Approved — the fund balance above already reflects it.' : 'Declined by the admin.'}</p>
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
    const cents = dollarsToCents(amountText);
    if (cents === null || cents <= 0) { await showAlert('Invalid amount', 'Enter a positive amount.'); return; }
    let { error } = await supabase.rpc('approve_and_allocate', { p_request_id: b.dataset.approve, p_amount_cents: cents, p_override_reason: null });
    if (error && /insufficient fund/i.test(error.message)) {
      const reason = await showSheet({ title: 'Fund is short', message: `The fund does not cover ${formatCents(cents)}. You can still approve with a typed reason — it will be logged.`, inputLabel: 'Reason for overriding', confirmLabel: 'Approve anyway', cancelLabel: 'Cancel' });
      if (reason === null) return;
      ({ error } = await supabase.rpc('approve_and_allocate', { p_request_id: b.dataset.approve, p_amount_cents: cents, p_override_reason: reason.trim() }));
    }
    if (error) await showAlert('Could not approve', error.message); else await refresh();
  }));
  document.querySelectorAll('[data-decline]').forEach((b) => b.addEventListener('click', async () => {
    const { error } = await supabase.rpc('decline_fund_request', { p_request_id: b.dataset.decline });
    if (error) await showAlert('Could not decline', error.message); else await refresh();
  }));
  // Settings card: admin only.
  $('settingsCard').style.display = household.role === 'admin' ? '' : 'none';
  // Savings: latest attestations (read) + admin form.
  const { data: sav } = await supabase.from('savings_ledger')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(20);
  $('savingsList').innerHTML = (sav ?? []).length
    ? `<ul>${(sav ?? []).map((s) => `<li>Recorded balance ${formatCents(s.actual_balance_cents ?? 0)} · ${fmtDateTime(s.created_at)} · ${esc(s.note || '')}</li>`).join('')}</ul>${(sav ?? []).length >= 20 ? '<p class="muted small">Showing the latest 20 records.</p>' : ''}`
    : '<p class="muted small">No savings records yet.</p>';
  $('savingsFormWrap').style.display = household.role === 'admin' ? '' : 'none';

  // Bank sync line: persisted across visits (localStorage), never the
  // old "not synced yet in this session" confession on reopen.
  const syncKey = `hb-last-sync-${household.household_id}`;
  const storedSync = localStorage.getItem(syncKey);
  const syncLine = $('bankSyncLine');
  if (syncLine) syncLine.textContent = storedSync ? `Last synced ${storedSync}` : 'Not synced yet.';
  const ls = document.getElementById('lastSync'); if (ls) ls.textContent = fmtDateTime(new Date().toISOString());
  // Bank button states: once connected, Connect quiets down and Sync
  // becomes the primary action; the webhook button shows its on-state.
  const connected = localStorage.getItem(`hb-bank-connected-${household.household_id}`) === '1';
  const cb = $('connectBankBtn');
  if (cb && connected) { cb.classList.remove('btn-primary'); cb.textContent = 'Connected ✓'; cb.disabled = true; }
  const sb = $('syncBankBtn');
  if (sb && connected) sb.classList.add('btn-primary');
  const wb = $('registerWebhookBtn');
  if (wb && localStorage.getItem(`hb-webhook-on-${household.household_id}`) === '1') { wb.textContent = 'Automatic sync is on ✓'; wb.disabled = true; }
  // Extra Fund summary: balances from the fund ledger + pending releases.
  // Before the fund SQL lands these queries fail — show an honest note.
  try {
    const { data: ledger } = await supabase.from('fund_ledger').select('kind, amount_cents').eq('household_id', household.household_id);
    const { data: releases } = await supabase.from('surplus_releases').select('surplus_cents, released_cents, status').eq('household_id', household.household_id);
    const { data: hh } = await supabase.from('households').select('fund_shortfall_cents').eq('id', household.household_id).maybeSingle();
    if (ledger) {
      const sum = (k) => (ledger ?? []).filter((r) => r.kind === k).reduce((s, r) => s + r.amount_cents, 0);
      const available = (ledger ?? []).reduce((s, r) => s + r.amount_cents, 0);
      const spent = Math.abs(sum('allocation') + sum('override_allocation'));
      const pending = (releases ?? []).filter((r) => r.status === 'pending').reduce((s, r) => s + r.surplus_cents, 0);
      const held = (releases ?? []).filter((r) => r.status === 'held').length;
      const shortfall = hh?.fund_shortfall_cents ?? 0;
      const fs = $('fundSummary');
      if (fs) fs.innerHTML = `<p class="fund-balance">Available <strong>${formatCents(available)}</strong></p>
        <p class="muted small">Leftover money from weeks you spent under budget.</p>${pending > 0 ? `<p class="muted small">Another ${formatCents(pending)} is on its way.</p>` : ''}${shortfall > 0 ? `<p class="muted small">Owed back to the fund: ${formatCents(shortfall)}.</p>` : ''}`;
    } else {
      const fs = $('fundSummary');
      if (fs) fs.innerHTML = '<p class="muted small">Fund balances will appear once the fund setup is complete.</p>';
    }
  } catch (e) {
    const fs = $('fundSummary');
    if (fs) fs.innerHTML = '<p class="muted small">Fund balances will appear once the fund setup is complete.</p>';
  }
  const faw = $('fundAdminWrap');
  if (faw) faw.style.display = household.role === 'admin' ? '' : 'none';

  showView(currentView);
  const { data: auditRows } = await supabase.from('audit_log')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(50);
  $('auditList').innerHTML = (auditRows ?? []).length
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
  await refresh();
}

$('signInBtn').addEventListener('click', async () => {
  const { error } = await supabase.auth.signInWithPassword({
    email: $('authEmail').value.trim(), password: $('authPassword').value,
  });
  $('authMsg').textContent = error ? error.message : 'Signed in.';
  if (!error) await boot();
});
$('signUpBtn').addEventListener('click', async () => {
  const { error } = await supabase.auth.signUp({
    email: $('authEmail').value.trim(), password: $('authPassword').value,
  });
  $('authMsg').textContent = error ? error.message : 'Account created. If email confirmation is on in Auth settings, confirm the email first, then sign in.';
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
  $('householdMsg').textContent = data
    ? `Household created: ${data}. Share this ID with your spouse so they can join as member.`
    : `Could not create household: ${error?.message ?? 'unknown error'}`;
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
  const id = $('joinId').value.trim();
  if (!user || !id) return;
  const { error } = await supabase.from('household_members')
    .insert({ household_id: id, user_id: user.id, role: 'member' });
  $('householdMsg').textContent = error ? `Join failed: ${error.message}` : 'Joined. Loading shared budget…';
  // Same direct-navigation fix as create: the insert just proved the
  // caller is a member of this household, so do not re-read first.
  if (!error) { household = { household_id: id, role: 'member' }; await show('app'); await refresh(); }
});

$('manualForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const amount = dollarsToCents(f.amount.value);
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
  if (error) { await showAlert('Could not save', error.message); return; }
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
  $('bankMsg').textContent = 'Getting a secure bank connection…';
  const out = await callFn('plaid-link', { household_id: household.household_id });
  if (!out.link_token) {
    $('bankMsg').textContent = `Could not start the bank connection: ${out.error ?? 'unknown error'}. If it says "not configured," the bank connection is not set up on the server yet.`;
    return;
  }
  const handler = window.Plaid.create({
    token: out.link_token,
    onSuccess: async (publicToken, metadata) => {
      $('bankMsg').textContent = 'Bank approved — finishing the secure connection…';
      const ex = await callFn('plaid-exchange', {
        household_id: household.household_id,
        public_token: publicToken,
        institution_name: metadata?.institution?.name ?? null,
      });
      $('bankMsg').textContent = ex.connected
        ? 'Connected. Tap "Sync bank transactions now" to pull transactions.'
        : `Connection could not be finished: ${ex.error ?? 'unknown error'}`;
      if (ex.connected) { localStorage.setItem(`hb-bank-connected-${household.household_id}`, '1'); await refresh(); }
    },
    onExit: (err) => {
      if (err) $('bankMsg').textContent = `Bank connection closed: ${err.error_message ?? err.error_code ?? 'cancelled'}`;
    },
  });
  handler.open();
});

async function runBankSync() {
  $('bankMsg').textContent = 'Syncing bank transactions…';
  const out = await callFn('plaid-sync', { household_id: household.household_id });
  const text = out.error
    ? `Sync failed: ${out.error}`
    : `Sync done: ${out.added ?? 0} added, ${out.updated ?? 0} updated, ${out.skipped ?? 0} skipped across ${out.items ?? 0} connected account(s).`;
  $('bankMsg').textContent = text;
  if (!out.error) {
    localStorage.setItem(`hb-last-sync-${household.household_id}`, fmtDateTime(new Date().toISOString()));
    localStorage.setItem(`hb-bank-connected-${household.household_id}`, '1');
  }
  return out;
}

$('syncBankBtn')?.addEventListener('click', async () => {
  await runBankSync();
  await refresh();
});
$('homeSyncBtn')?.addEventListener('click', async () => {
  const msg = $('homeSyncMsg');
  if (msg) msg.textContent = 'Syncing bank transactions…';
  await runBankSync();
  if (msg) msg.textContent = $('bankMsg')?.textContent ?? '';
  await refresh();
});

$('registerWebhookBtn')?.addEventListener('click', async () => {
  $('bankMsg').textContent = 'Enabling automatic sync…';
  const out = await callFn('plaid-webhook-register', { household_id: household.household_id });
  if (out.error) { $('bankMsg').textContent = `Could not enable automatic sync: ${out.error}`; return; }
  const failed = (out.results ?? []).filter((r) => !r.ok);
  $('bankMsg').textContent = failed.length
    ? `Automatic sync partly enabled — ${failed.length} connection(s) failed: ${failed.map((r) => r.error).join('; ')}`
    : 'Automatic sync enabled. New purchases will be pulled in on your next refresh.';
  if (!failed.length) { localStorage.setItem(`hb-webhook-on-${household.household_id}`, '1'); await refresh(); }
});

// Automatic sync: if a verified webhook event is waiting for this
// household's items, run a sync at the start of refresh (once —
// plaid-sync marks events processed, so this does not loop).
let autoSyncDoneThisLoad = false;
async function autoSyncIfWebhookPending() {
  if (autoSyncDoneThisLoad || !household) return;
  autoSyncDoneThisLoad = true;
  const { data: items } = await supabase.from('plaid_items')
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
  week: ['section-week', 'section-stats', 'section-hint', 'section-recent', 'finRefundNote'],
  purchases: ['section-manual', 'section-transactions'],
  money: ['section-bank', 'settingsCard', 'section-savings', 'section-fund'],
  activity: ['section-activity'],
};
const ALL_VIEW_SECTIONS = Object.values(VIEWS).flat();
let currentView = localStorage.getItem('hb-view') || 'week';
if (!VIEWS[currentView]) currentView = 'week';
function showView(name) {
  if (!VIEWS[name]) name = 'week';
  currentView = name;
  localStorage.setItem('hb-view', name);
  for (const id of ALL_VIEW_SECTIONS) {
    const el = document.getElementById(id);
    if (!el) continue;
    if (!VIEWS[name].includes(id)) { el.style.display = 'none'; continue; }
    if (id === 'settingsCard') { el.style.display = (household && household.role === 'admin') ? 'block' : 'none'; continue; }
    if (id === 'finRefundNote') continue; // refresh() already sets this from the server flag
    el.style.display = id === 'section-stats' ? 'grid' : 'block';
  }
  document.querySelectorAll('[data-view]').forEach((b) => {
    b.classList.toggle('active', b.dataset.view === name);
    b.setAttribute('aria-pressed', b.dataset.view === name ? 'true' : 'false');
  });
  window.scrollTo(0, 0);
}
document.querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', () => {
  showView(b.dataset.view);
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
  await showSheet({ title: 'Household ID', message: `Share this ID with the second account so they can join as a member:<br><strong style="overflow-wrap:anywhere">${household?.household_id ?? ''}</strong>`, inputLabel: null, confirmLabel: 'Done' });
});
document.getElementById('menuPasswordBtn')?.addEventListener('click', async () => {
  document.getElementById('profileMenu')?.classList.add('hidden');
  const pw = await showSheet({ title: 'Change password', message: 'Enter a new password for this account.', inputLabel: 'New password', inputType: 'password', confirmLabel: 'Change password', cancelLabel: 'Cancel' });
  if (!pw) return;
  const { error } = await supabase.auth.updateUser({ password: pw });
  await showAlert(error ? 'Could not change password' : 'Password changed', error ? error.message : 'Your password is updated.');
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
function showSheet({ title, message, inputLabel, inputValue = '', inputType = 'text', confirmLabel = 'OK', cancelLabel = null }) {
  return new Promise((resolve) => {
    document.getElementById('sheetOverlay')?.remove();
    const overlay = document.createElement('div');
    overlay.id = 'sheetOverlay';
    overlay.innerHTML = `<div class="sheet" role="dialog" aria-modal="true" aria-label="${title.replace(/"/g, '')}">
      <h3>${title}</h3><p>${message}</p>
      ${inputLabel ? `<label>${inputLabel}<input id="sheetInput" type="${inputType}" value="${String(inputValue).replace(/"/g, '')}"></label>` : ''}
      <div class="sheet-btns">
        ${cancelLabel ? `<button class="btn" type="button" id="sheetCancel">${cancelLabel}</button>` : ''}
        <button class="btn btn-primary" type="button" id="sheetConfirm">${confirmLabel}</button>
      </div></div>`;
    document.body.appendChild(overlay);
    const done = (v) => { overlay.remove(); resolve(v); };
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
  const cents = dollarsToCents($('tempIncreaseInput').value);
  if (cents === null || cents <= 0) { $('tempMsg').textContent = 'Enter a positive amount.'; return; }
  const ny = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/New_York' }));
  const sunday = new Date(ny); sunday.setDate(ny.getDate() - ny.getDay());
  const weekStart = `${sunday.getFullYear()}-${String(sunday.getMonth() + 1).padStart(2, '0')}-${String(sunday.getDate()).padStart(2, '0')}`;
  const { error } = await supabase.rpc('add_temp_increase', { p_household_id: household.household_id, p_week_start: weekStart, p_amount_cents: cents, p_note: '' });
  $('tempMsg').textContent = error ? `Could not add: ${error.message}` : 'Temporary increase added — dashboard will reflect it on refresh.';
  if (!error) await refresh();
});

$('attestSavingsBtn')?.addEventListener('click', async () => {
  const cents = dollarsToCents($('savingsBalanceInput').value);
  if (cents === null || cents < 0) { $('savingsMsg').textContent = 'Enter a valid balance.'; return; }
  const { error } = await supabase.rpc('attest_savings', { p_household_id: household.household_id, p_actual_balance_cents: cents, p_note: $('savingsNoteInput').value.trim() });
  $('savingsMsg').textContent = error ? `Could not record: ${error.message}` : 'Balance recorded.';
  if (!error) await refresh();
});

$('saveAllowanceBtn')?.addEventListener('click', async () => {
  const cents = dollarsToCents($('baseAllowanceInput').value);
  if (cents === null || cents < 0) { $('settingsMsg').textContent = 'Enter a valid allowance.'; return; }
  const { error } = await supabase.rpc('set_base_allowance', { p_household_id: household.household_id, p_cents: cents });
  $('settingsMsg').textContent = error ? `Could not save: ${error.message}` : 'Allowance saved.';
  if (!error) await refresh();
});

$('fundAllocateForm')?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const cents = dollarsToCents(f.amount.value);
  if (cents === null || cents <= 0) { $('fundAllocateMsg').textContent = 'Enter a positive amount.'; return; }
  let { error } = await supabase.rpc('allocate_fund', { p_household_id: household.household_id, p_amount_cents: cents, p_note: f.note.value.trim(), p_override_reason: null });
  if (error && /insufficient fund/i.test(error.message)) {
    const reason = await showSheet({ title: 'Fund is short', message: `The fund does not cover ${formatCents(cents)}. Record it anyway with a typed reason — it will be logged.`, inputLabel: 'Reason for overriding', confirmLabel: 'Record anyway', cancelLabel: 'Cancel' });
    if (reason === null) return;
    ({ error } = await supabase.rpc('allocate_fund', { p_household_id: household.household_id, p_amount_cents: cents, p_note: f.note.value.trim(), p_override_reason: reason.trim() }));
  }
  $('fundAllocateMsg').textContent = error ? `Could not record: ${error.message}` : 'Fund spending recorded.';
  if (!error) { f.reset(); await refresh(); }
});
$('fundRequestForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const { data: { user } } = await supabase.auth.getUser();
  const { error } = await supabase.from('fund_requests').insert({
    household_id: household.household_id, requested_by: user.id,
    amount_cents: dollarsToCents(f.amount.value), note: f.note.value.trim(), status: 'pending',
  });
  if (error) { await showAlert('Could not save request', error.message); return; }
  await audit('Extra Fund request created', `Requested ${formatCents(dollarsToCents(f.amount.value))}.`);
  f.reset(); await refresh();
});

boot();
