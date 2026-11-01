// Household Budget — LIVE front end (Supabase).
// This is a first working slice, not a rewrite of the demo:
//   * Real Supabase Auth (email + password, two accounts only).
//   * First account creates the household as admin; second joins by ID.
//   * Transactions, fund requests, and audit log read/write the shared DB.
//   * Week numbers come from the server (compute-week Edge Function),
//     never from client-side math alone.
//   * Writes that RLS does not yet allow (admin-only allocations, settings,
//     savings attestation) are NOT faked here — they land in later slices
//     behind Edge Functions with explicit role checks.
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
  $('householdId').textContent = household.household_id;
  $('roleText').textContent = household.role;
  $('roleBadge').textContent = `LIVE · ${household.role.toUpperCase()}`;
  $('lastSync').textContent = new Date().toLocaleString();

  const { data: { session: s } } = await supabase.auth.getSession();
  const token = s?.access_token ?? '';
  // Week numbers from the server.
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/compute-week`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
      body: JSON.stringify({ household_id: household.household_id }),
    });
    const week = await res.json();
    if (week.result) {
      $('weekLabel').textContent = `Week of ${week.week_start} (Sun–Sat, America/New_York)`;
      $('weeklyAvailable').textContent = formatCents(week.result.available);
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
  const q = ($('txSearch')?.value ?? '').trim().toLowerCase();
  const shown = (txns ?? []).filter((t) => !q
    || t.merchant.toLowerCase().includes(q)
    || String(t.date).includes(q)
    || formatCents(t.amount_cents).toLowerCase().includes(q));
  $('txList').innerHTML = shown.length
    ? shown.map((t) => `<li><strong>${esc(t.merchant)}</strong>
        <span class="pill ${t.state === 'provisional' ? 'warn' : 'ok'}">${esc(t.state.toUpperCase())}</span>
        <span class="pill">${esc(t.source.toUpperCase())}</span><br>
        ${formatCents(t.amount_cents)} · ${esc(t.date)} · ••${esc(t.card_suffix)}</li>`).join('')
    : '<li>No transactions yet — add one below, or import via CSV in the demo (live CSV lands next).</li>';

  const { data: reqs } = await supabase.from('fund_requests')
    .select('*').eq('household_id', household.household_id)
    .order('created_at', { ascending: false }).limit(50);
  $('fundQueue').innerHTML = (reqs ?? []).length
    ? (reqs ?? []).map((r) => {
        const btns = (household.role === 'admin' && r.status === 'pending')
          ? ` <button class="btn btn-small" data-approve="${r.id}" type="button">Approve</button> <button class="btn btn-small" data-decline="${r.id}" type="button">Decline</button>`
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
  $('bankMsg').textContent = 'Getting a secure Plaid link…';
  const out = await callFn('plaid-link', { household_id: household.household_id });
  if (!out.link_token) {
    $('bankMsg').textContent = `Could not start Plaid Link: ${out.error ?? 'unknown error'}. If it says "not configured," the Plaid server keys are not set yet — no bank can be connected until then.`;
    return;
  }
  const handler = window.Plaid.create({
    token: out.link_token,
    onSuccess: async (publicToken, metadata) => {
      $('bankMsg').textContent = 'Amex approved — finishing the secure connection…';
      const ex = await callFn('plaid-exchange', {
        household_id: household.household_id,
        public_token: publicToken,
        institution_name: metadata?.institution?.name ?? null,
      });
      $('bankMsg').textContent = ex.connected
        ? `Connected: ${metadata?.institution?.name ?? 'Amex'}. Tap "Sync bank transactions now" to pull transactions.`
        : `Connection could not be finished: ${ex.error ?? 'unknown error'}`;
      if (ex.connected) await refresh();
    },
    onExit: (err) => {
      if (err) $('bankMsg').textContent = `Plaid closed: ${err.error_message ?? err.error_code ?? 'cancelled'}`;
    },
  });
  handler.open();
});

$('syncBankBtn')?.addEventListener('click', async () => {
  $('bankMsg').textContent = 'Syncing bank transactions…';
  const out = await callFn('plaid-sync', { household_id: household.household_id });
  $('bankMsg').textContent = out.error
    ? `Sync failed: ${out.error}`
    : `Sync done: ${out.added ?? 0} added, ${out.updated ?? 0} updated, ${out.skipped ?? 0} skipped across ${out.items ?? 0} connected item(s).`;
  await refresh();
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
