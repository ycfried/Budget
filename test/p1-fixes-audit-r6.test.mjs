// R6 audit P1 fixes (Nov 11, 2026) — static tests + pure-function
// mirrors. No DOM, no network, no database, no money math changes.
// P1-1: the Weekly sheet could not reconcile a $0 allowance —
// Settings showed the stored base, Home showed the effective
// allowance, and nothing on screen said why. Reconciliation rows
// now appear in the sheet exactly when debt or temp changes the
// number. P1-2: refresh() had try/finally with no catch, so a throw
// before the transaction-list render left stale rows on screen as
// if they were the filtered result. refresh() now catches, logs
// loudly, and still renders the list (or its error state), and the
// Weekly/Past-Weeks shortcuts clear stale filters first.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const sw = readFileSync(new URL('../live-sw.js', import.meta.url), 'utf8');

const sheetFn = js.slice(
  js.indexOf('async function openWeeklySheet()'),
  js.indexOf('const heroWeeklyTarget'),
);
assert.ok(sheetFn.length > 0, 'openWeeklySheet body found');

const refreshFn = js.slice(
  js.indexOf('async function refresh()'),
  js.indexOf("} finally {\n    // A failed read must not blank the page"),
);
assert.ok(refreshFn.length > 0, 'refresh body found');

const openWeekFn = js.slice(
  js.indexOf('const openWeek = async () => {'),
  js.indexOf("el.addEventListener('click', openWeek)"),
);
assert.ok(openWeekFn.length > 0, 'openWeek body found');

test('pins: live.js v68 / styles v53, service-worker cache tracks live.js', () => {
  assert.ok(html.includes('live.js?v=68'), 'live.html pins live.js v68');
  assert.ok(html.includes('styles.css?v=53'), 'live.html pins styles v53');
  assert.ok(sw.includes("CACHE = 'onbudget-live-v68'"), 'service-worker cache tracks the live.js pin');
  assert.ok(sw.includes('(v68)'), 'service-worker comment names the current pin');
});

// ---- P1-1: reconciliation rows in the Weekly sheet ----

test('P1-1: reconciliation rows exist and are gated on debt/temp changing the number', () => {
  assert.ok(sheetFn.includes("const hasTemp = (w.tempCents ?? 0) > 0;"), 'temp flag');
  assert.ok(sheetFn.includes("const hasDebt = (w.carriedDebtCents ?? 0) > 0;"), 'debt flag');
  assert.ok(sheetFn.includes("if (Number.isInteger(w.baseAllowanceCents) && (hasTemp || hasDebt)) weeklyRows.push(['Base allowance', formatCents(w.baseAllowanceCents)]);"), 'Base allowance row, only when the base is known and debt or temp applies');
  assert.ok(sheetFn.includes("if (hasTemp) weeklyRows.push(['Temporary increases', formatCents(w.tempCents)]);"), 'Temporary increases row, only when temp > 0');
  assert.ok(sheetFn.includes("if (hasDebt) weeklyRows.push(['Carried debt', formatCents(w.carriedDebtCents)]);"), 'Carried debt row, only when debt > 0');
  // Reconciliation rows come first, then the three base rows.
  const order = ["['Base allowance'", "['Temporary increases'", "['Carried debt'", "['Allowance'", "['Spent'", "['Balance'"];
  const idx = order.map((label) => sheetFn.indexOf(label));
  for (let i = 0; i < idx.length; i++) assert.ok(idx[i] > 0, `${order[i]} present in the sheet`);
  for (let i = 1; i < idx.length; i++) assert.ok(idx[i] > idx[i - 1], `${order[i]} follows ${order[i - 1]}`);
});

// Mirror of the sheet's row-label logic (same gates, same order) so
// the row sets per week shape are asserted as behaviour, not text.
function sheetRowLabels(w) {
  const labels = [];
  const hasTemp = (w.tempCents ?? 0) > 0;
  const hasDebt = (w.carriedDebtCents ?? 0) > 0;
  if (Number.isInteger(w.baseAllowanceCents) && (hasTemp || hasDebt)) labels.push('Base allowance');
  if (hasTemp) labels.push('Temporary increases');
  if (hasDebt) labels.push('Carried debt');
  labels.push('Allowance', 'Spent', 'Balance');
  return labels;
}

test('P1-1: row sets per week shape (mirror)', () => {
  // Normal week: the approved three rows, nothing else.
  assert.deepEqual(sheetRowLabels({ baseAllowanceCents: 37500, tempCents: 0, carriedDebtCents: 0 }), ['Allowance', 'Spent', 'Balance']);
  // Debt ate the base (the $0-allowance case): Base + Carried debt
  // explain the $0 before the Allowance row shows it.
  assert.deepEqual(sheetRowLabels({ baseAllowanceCents: 37500, tempCents: 0, carriedDebtCents: 40000 }), ['Base allowance', 'Carried debt', 'Allowance', 'Spent', 'Balance']);
  // Temporary increase only.
  assert.deepEqual(sheetRowLabels({ baseAllowanceCents: 37500, tempCents: 5000, carriedDebtCents: 0 }), ['Base allowance', 'Temporary increases', 'Allowance', 'Spent', 'Balance']);
  // Both debt and temp: all six, in reconciliation order.
  assert.deepEqual(sheetRowLabels({ baseAllowanceCents: 37500, tempCents: 5000, carriedDebtCents: 10000 }), ['Base allowance', 'Temporary increases', 'Carried debt', 'Allowance', 'Spent', 'Balance']);
  // Base unknown: the Base row is skipped, the changing lines
  // still show.
  assert.deepEqual(sheetRowLabels({ baseAllowanceCents: null, tempCents: 5000, carriedDebtCents: 0 }), ['Temporary increases', 'Allowance', 'Spent', 'Balance']);
});

// ---- P1-2: refresh() can never abort before the list renders ----

test('P1-2: refresh() has a catch that surfaces the error and renders the list error state', () => {
  assert.ok(refreshFn.includes("} catch (e) {"), 'refresh has a catch before its finally');
  assert.ok(refreshFn.includes("console.error('refresh failed:', e);"), 'the catch logs loudly');
  assert.ok(refreshFn.includes("showToast(\"Couldn't finish loading — check your connection and try again.\", true);"), 'the catch shows an error toast');
  assert.ok(refreshFn.includes("if (!txListRendered) {"), 'the catch only overwrites a list that never rendered');
  assert.ok(refreshFn.includes("countEl.textContent = 'Could not load transactions — try again.';"), 'count line carries the load error');
  assert.ok(refreshFn.includes("txListEl.innerHTML = '<li class=\"tx-empty error\">Could not load transactions — try again.</li>';"), 'list carries the inline load error');
  assert.ok(refreshFn.includes("heroCount.textContent = 'N/A';"), 'hero purchase count falls back to N/A');
});

test('P1-2: the list-rendered flag is declared before try and set right after the list render', () => {
  assert.ok(refreshFn.includes('let txListRendered = false;'), 'flag declared in refresh');
  assert.ok(refreshFn.includes('txListRendered = true;'), 'flag set after the render');
  assert.ok(
    refreshFn.indexOf('txListRendered = true;') > refreshFn.indexOf("$('txList').innerHTML ="),
    'flag is set after the txList assignment, not before it',
  );
});

test('P1-2: the three pre-render throw points are guarded', () => {
  // Auto-sync race: guarded, logs loudly, refresh continues.
  assert.match(refreshFn, /try \{\s*await Promise\.race\(\[autoSyncIfWebhookPending\(\)/);
  assert.ok(refreshFn.includes("console.error('auto-sync before refresh failed:', e);"), 'auto-sync failure is logged');
  // Temp preview: best-effort, never aborts the refresh.
  assert.ok(refreshFn.includes("try { updateTempPreview(); } catch (e) { console.error('temp preview failed:', e); }"), 'temp preview is guarded');
  // Transactions fetch: a network rejection becomes the guarded
  // read-failure state instead of escaping refresh().
  assert.ok(refreshFn.includes('let txns = null;'), 'txns is let-bound for the guard');
  assert.ok(refreshFn.includes('let txErr = null;'), 'txErr is let-bound for the guard');
  assert.ok(refreshFn.includes('catch (e) { txErr = e; }'), 'a rejected fetch becomes a read error');
});

test('P1-2: Weekly shortcut clears the leftover date range and resets the page', () => {
  assert.match(sheetFn, /if \(weeklyResult === 'show-transactions'\) \{\s*txWeekOnly = true;[\s\S]*?txFromDate = '';\s*txToDate = '';\s*resetTxLimit\(\);\s*showView\('purchases'\);\s*await refresh\(\);/);
});

test('P1-2: Past-Weeks jump clears search and amount bounds', () => {
  assert.ok(openWeekFn.includes("const txSearchInput = $('txSearch'); if (txSearchInput) txSearchInput.value = '';"), 'search cleared');
  assert.ok(openWeekFn.includes("const txMinInput = $('txMinAmount'); if (txMinInput) txMinInput.value = '';"), 'min amount cleared');
  assert.ok(openWeekFn.includes("const txMaxInput = $('txMaxAmount'); if (txMaxInput) txMaxInput.value = '';"), 'max amount cleared');
});
