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
let txWeekOnly = false; // spec B5: transactions filter by week (client-side, current Sun–Sat week)
let lastBankSyncText = null; // last Sync button result, this session only
let lastBankSyncTime = null;
// Generic display labels for transaction sources. Database values are
// unchanged (e.g. 'plaid'); only what the user sees is bank-agnostic.
const sourceLabel = (s) => ({ plaid: 'BANK', manual: 'MANUAL', csv: 'FILE', amex_alert: 'EMAIL ALERT' }[s] ?? String(s).toUpperCase());

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
    actor_name: household.role,
    action, detail,
  });
  if (error) console.warn('audit insert blocked (expected until insert policies land):', error.message);
}

async function refresh() {
  if (!household) return;
  // Webhook-triggered auto-sync happens first, so the numbers and
  // list below already include any purchases Plaid just announced.
  await autoSyncIfWebhookPending();
  $('householdId').textContent = household.household_id;
  $('roleText').textContent = household.role;
  $('roleBadge').textContent = `LIVE · ${household.role.toUpperCase()}`;
  $('lastSync').textContent = new Date().toLocaleString();

  const { data: { session: s } } = await supabase.auth.getSession();
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
  // Week numbers from the server.
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/compute-week`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
      body: JSON.stringify({ household_id: household.household_id, T: tempTotal }),
    });
    const week = await res.json();
    if (week.result) {
      $('weekLabel').textContent = `Week of ${week.week_start} (Sun–Sat, America/New_York)`;
      $('weeklyAvailable').textContent = formatCents(week.result.available);
      // Spec: a negative available balance must be shown clearly.
      $('weeklyAvailable').classList.toggle('negative', week.result.available < 0);
      $('statAllowance').textContent = formatCents(week.result.B);
      $('statSpent').textContent = formatCents(week.result.C);
      $('statDebt').textContent = formatCents(week.result.D);
      $('statCredit').textContent = formatCents(week.result.outgoingCredit);
      $('finRefundNote').style.display = week.not_production_certified ? '' : 'none';
    }
  } catch (e) { console.warn('compute-week failed:', e); }

  const { data: txns } = await supabase.from('transactions')
    .select('*').eq('household_id', household.household_id)
    .order('date', { ascending: false }).limit(100);
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
  const shown = all.filter((t) => byFilter(t) && (!txWeekOnly || inThisWeek(t)) && (!q
    || t.merchant.toLowerCase().includes(q)
    || String(t.date).includes(q)
    || formatCents(t.amount_cents).toLowerCase().includes(q)));
  const countEl = $('txCount');
  if (countEl) countEl.textContent = `Showing ${shown.length} of ${all.length} transactions${txWeekOnly ? ' · this week only' : ''}`;
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
    : 'No transactions here yet — add a manual purchase below, or connect a bank account and sync.';
  $('txList').innerHTML = shown.length
    ? shown.map((t) => {
        const excluded = t.excluded === true || t.state === 'excluded';
        // Spec A7: only the admin excludes or reverses. UI-gated here;
        // server-side enforcement still needs an RPC (see report).
        const isAdmin = household.role === 'admin';
        const action = !isAdmin ? ''
          : excluded
          ? `<button class="btn btn-small" data-restore="${t.id}" type="button" aria-label="Restore ${esc(t.merchant)} to the week">Restore</button>`
          : `<button class="btn btn-small" data-exclude="${t.id}" type="button" aria-label="Exclude ${esc(t.merchant)} from the week">Exclude</button>`;
        const neg = t.amount_cents < 0 ? ' negative' : '';
        return `<li class="tx-row ${excluded ? 'tx-excluded' : ''}"><div class="tx-line1"><strong class="tx-name" title="${esc(t.merchant)}" data-expand-name aria-label="Show full merchant name">${esc(t.merchant)}</strong><span class="tx-amount${neg}">${formatCents(t.amount_cents)}</span></div>
        <div class="tx-line2"><span class="pill ${t.state === 'provisional' ? 'warn' : 'ok'}">${excluded ? 'EXCLUDED' : esc(t.state.toUpperCase())}</span>
        <span class="pill">${esc(sourceLabel(t.source))}</span>
        <span class="muted small tx-meta">${esc(t.date)} · ••${esc(t.card_suffix)}</span> ${action}</div></li>`;
      }).join('')
    : `<li class="tx-empty">${emptyHint}</li>`;
  // Tap a truncated merchant name to expand it in place (title attr
  // covers long-press / hover on devices that support it).
  document.querySelectorAll('[data-expand-name]').forEach((el) => el.addEventListener('click', () => {
    el.classList.toggle('expanded');
  }));
  document.querySelectorAll('[data-exclude]').forEach((b) => b.addEventListener('click', async () => {
    // Spec A7: exclusion needs a reason, recorded in the audit log.
    const reason = (window.prompt('Why exclude this purchase? (optional — left blank it is recorded without a reason)') ?? '').trim();
    const row = all.find((t) => t.id === b.dataset.exclude);
    const { error } = await supabase.from('transactions')
      .update({ state: 'excluded', excluded: true }).eq('id', b.dataset.exclude);
    if (error) { alert(`Could not exclude: ${error.message}`); return; }
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
    if (error) { alert(`Could not restore: ${error.message}`); return; }
    await audit('Transaction restored', `${row ? row.merchant : 'Purchase'} returned to the week as ${state}.`);
    await refresh();
  }));

  const { data: reqs } = await supabase.from('fund_requests')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(50);
  $('fundQueue').innerHTML = (reqs ?? []).length
    ? (reqs ?? []).map((r) => {
        const btns = (household.role === 'admin' && r.status === 'pending')
          ? ` <button class="btn btn-small" data-approve="${r.id}" type="button" aria-label="Approve this Extra Fund request">Approve</button> <button class="btn btn-small" data-decline="${r.id}" type="button" aria-label="Decline this Extra Fund request">Decline</button>`
          : '';
        return `<li>${formatCents(r.amount_cents)} · ${esc(r.status.toUpperCase())} · ${esc(r.note || '')}${btns}</li>`;
      }).join('')
    : '<li>No fund requests yet.</li>';
  document.querySelectorAll('[data-approve]').forEach((b) => b.addEventListener('click', async () => {
    const { error } = await supabase.rpc('approve_fund_request', { p_request_id: b.dataset.approve });
    if (error) alert(`Could not approve: ${error.message}`); else await refresh();
  }));
  document.querySelectorAll('[data-decline]').forEach((b) => b.addEventListener('click', async () => {
    const { error } = await supabase.rpc('decline_fund_request', { p_request_id: b.dataset.decline });
    if (error) alert(`Could not decline: ${error.message}`); else await refresh();
  }));
  // Settings card: admin only.
  $('settingsCard').style.display = household.role === 'admin' ? '' : 'none';
  // Savings: latest attestations (read) + admin form.
  const { data: sav } = await supabase.from('savings_ledger')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(20);
  $('savingsList').innerHTML = (sav ?? []).length
    ? `<ul>${(sav ?? []).map((s) => `<li>Attested balance ${formatCents(s.actual_balance_cents ?? 0)} · ${new Date(s.created_at).toLocaleString()} · ${esc(s.note || '')}</li>`).join('')}</ul>`
    : '<p class="muted small">No savings attestations yet.</p>';
  $('savingsFormWrap').style.display = household.role === 'admin' ? '' : 'none';

  // Connections card: only real, observed values — the last Sync
  // button result from this session and the page's refresh time.
  // No sync time is invented for the email poller.
  const connBank = $('connBankStatus');
  if (connBank) connBank.textContent = lastBankSyncText
    ? `${lastBankSyncText} (${lastBankSyncTime})`
    : 'Not synced yet in this session.';
  const connRefresh = $('connLastRefresh');
  if (connRefresh) connRefresh.textContent = new Date().toLocaleString();

  const { data: auditRows } = await supabase.from('audit_log')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(50);
  $('auditList').innerHTML = (auditRows ?? []).length
    ? (auditRows ?? []).map((a) => `<li><strong>${esc(a.action)}</strong> <span class="muted">(${esc(a.actor_name)} · ${esc(new Date(a.created_at).toLocaleString())})</span><br>${esc(a.detail)}</li>`).join('')
    : '<li>No audit entries yet.</li>';
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
$('refreshBtn').addEventListener('click', refresh);

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
  if (!/^\d{4}$/.test(suffix)) { alert('Card suffix must be exactly 4 digits. Never enter a full card number.'); return; }
  const merchant = f.merchant.value.trim().toUpperCase();
  const hash = await sha(`${f.date.value}|${merchant}|${amount}|${suffix}`);
  const { error } = await supabase.from('transactions').insert({
    household_id: household.household_id, date: f.date.value, merchant,
    amount_cents: amount, card_suffix: suffix, source: 'manual',
    state: 'provisional', kind: 'charge', dedupe_hash: hash,
  });
  if (error) { alert(`Could not save: ${error.message}`); return; }
  await audit('Manual provisional purchase added', `${merchant} ${formatCents(amount)} on ${f.date.value} (••${suffix}).`);
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
      if (ex.connected) await refresh();
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
  lastBankSyncText = text;
  lastBankSyncTime = new Date().toLocaleString();
  return out;
}

$('syncBankBtn')?.addEventListener('click', async () => {
  await runBankSync();
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

// Transaction filters: chips combine with the search box; refresh()
// re-renders the list with both applied.
document.querySelectorAll('[data-tx-filter]').forEach((c) => c.addEventListener('click', async () => {
  txFilter = c.dataset.txFilter;
  await refresh();
}));
$('txWeekToggle')?.addEventListener('click', async () => {
  txWeekOnly = !txWeekOnly;
  await refresh();
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
  $('savingsMsg').textContent = error ? `Could not attest: ${error.message}` : 'Balance attested.';
  if (!error) await refresh();
});

$('saveAllowanceBtn')?.addEventListener('click', async () => {
  const cents = dollarsToCents($('baseAllowanceInput').value);
  if (cents === null || cents < 0) { $('settingsMsg').textContent = 'Enter a valid allowance.'; return; }
  const { error } = await supabase.rpc('set_base_allowance', { p_household_id: household.household_id, p_cents: cents });
  $('settingsMsg').textContent = error ? `Could not save: ${error.message}` : 'Allowance saved.';
  if (!error) await refresh();
});

$('fundRequestForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const { data: { user } } = await supabase.auth.getUser();
  const { error } = await supabase.from('fund_requests').insert({
    household_id: household.household_id, requested_by: user.id,
    amount_cents: dollarsToCents(f.amount.value), note: f.note.value.trim(), status: 'pending',
  });
  if (error) { alert(`Could not save request: ${error.message}`); return; }
  await audit('Extra Fund request created', `Requested ${formatCents(dollarsToCents(f.amount.value))}.`);
  f.reset(); await refresh();
});

boot();
