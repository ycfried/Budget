// Delta package (Nov 3, 2026) — pure helpers for the live app's new
// Transactions filter labels, History period line, and sync guard.
// No DOM, no network: live.js imports these, and the Node tests
// import them directly, so the tested code IS the shipped code.

// Active-filter labels for the Transactions sheet (B2). Each entry is
// { key, label }: key is what clearing that one label resets, label is
// the exact text shown. Only filters that actually narrow the list
// appear — 'all' status, 'all' month/card, blank bounds, and an unset
// week/date range produce no label, so the label row never claims a
// filter is active when it is not.
const STATUS_LABELS = {
  pending: 'Pending',
  posted: 'Posted',
  refunds: 'Refunds',
  charity: 'Charity',
  excluded: 'Excluded',
};
export function activeFilterLabels(f) {
  const labels = [];
  if (f.status && f.status !== 'all') {
    labels.push({ key: 'status', label: STATUS_LABELS[f.status] ?? f.status });
  }
  if (f.monthLabel) labels.push({ key: 'month', label: f.monthLabel });
  if (f.cardLabel) labels.push({ key: 'card', label: f.cardLabel });
  if (f.minLabel != null) labels.push({ key: 'min', label: `From ${f.minLabel}` });
  if (f.maxLabel != null) labels.push({ key: 'max', label: `Up to ${f.maxLabel}` });
  if (f.weekOnly) labels.push({ key: 'week', label: 'This week' });
  if (f.fromDate) labels.push({ key: 'from', label: `From ${f.fromDate}` });
  if (f.toDate) labels.push({ key: 'to', label: `Up to ${f.toDate}` });
  return labels;
}

// History period line (B1). States the active period so a filter can
// never silently make records disappear; with no filter it says so.
export function historyPeriodLabel(from, to) {
  if (!from && !to) return 'Showing all recorded history.';
  if (from && to) return `Showing ${from} to ${to}.`;
  if (from) return `Showing from ${from} onward.`;
  return `Showing up to ${to}.`;
}

// Filter rows by a YYYY-MM-DD date string (week closes by week_start,
// audit rows by the date part of created_at). A blank bound means no
// limit on that side; rows without a parseable date are kept, never
// silently dropped by the filter.
export function filterRowsByDate(rows, getDate, from, to) {
  if (!from && !to) return rows;
  return rows.filter((r) => {
    const d = getDate(r);
    if (!d || !/^\d{4}-\d{2}-\d{2}/.test(String(d))) return true;
    const day = String(d).slice(0, 10);
    if (from && day < from) return false;
    if (to && day > to) return false;
    return true;
  });
}

// Sync guard (B3): only one bank sync runs at a time. tryStart()
// returns false while a sync is in flight, so a repeat tap is ignored
// instead of starting a second sync; finish() releases the guard.
// A thrown sync must still release it, so callers use try/finally.
export function createSyncGuard() {
  let running = false;
  return {
    isRunning: () => running,
    tryStart: () => {
      if (running) return false;
      running = true;
      return true;
    },
    finish: () => { running = false; },
  };
}

// UX audit fixes (Nov 3, 2026) — pure helpers, tested in
// test/ux-audit-fixes.test.mjs. No DOM, no network.

// Plural helper for household-facing counts ("1 week", "2 weeks").
export function plural(n, one, many) {
  return n === 1 ? one : many;
}

// Weekly reconciliation (audit 02). Mirrors engine.mjs computeWeek
// exactly — this is display arithmetic over the server's numbers,
// never a second money engine:
//   baseRoom = max(0, allowance - carried debt)
//   left = baseRoom + temp - spent
//   outgoing = max(0, carried - allowance) + max(0, spent - baseRoom - temp)
// Callers pass the server's baseAvailable as `spent` is the server's
// charges total; `allowance` is the household allowance (or, if that
// read failed, baseAvailable + carried, which recovers the allowance
// exactly whenever allowance >= carried).
export function weeklyReconciliation({ allowance, carried, temp, spent }) {
  const B = Math.max(0, allowance ?? 0);
  const D = Math.max(0, carried ?? 0);
  const T = Math.max(0, temp ?? 0);
  const C = Math.max(0, spent ?? 0);
  const baseRoom = Math.max(0, B - D);
  const left = baseRoom + T - C;
  const unabsorbed = Math.max(0, D - B);
  const newDebt = Math.max(0, C - baseRoom - T);
  return { baseRoom, left, unabsorbed, newDebt, outgoing: unabsorbed + newDebt };
}

// Household wording for stored activity text (audit 09). Display
// mapping only — stored audit rows are never edited. Translates the
// week-close "N week(s) closed, M release(s)..." summary and any
// "canonical" dedupe wording into plain household language.
export function householdActivityText(detail) {
  let d = String(detail ?? '');
  d = d.replace(/(\d+) week\(s\) closed/g, (_, n) => `${n} ${plural(Number(n), 'week', 'weeks')} closed`);
  d = d.replace(/(\d+) release\(s\)/g, (_, n) => `${n} ${plural(Number(n), 'surplus', 'surpluses')} released`);
  d = d.replace(/(\d+) restoration\(s\)/g, (_, n) => `${n} ${plural(Number(n), 'refund', 'refunds')} restored`);
  d = d.replace(/(\d+) held refund\(s\)/g, (_, n) => `${n} ${plural(Number(n), 'refund', 'refunds')} held for review`);
  d = d.replace(/week\(s\)/g, 'weeks');
  d = d.replace(/canonical Plaid row/gi, 'bank row');
  d = d.replace(/into canonical/gi, 'into the original bank row');
  d = d.replace(/\bcanonical\b/gi, 'original');
  return d;
}

// Group repeated weekly-processing events inside one day's activity
// (audit 09). Only the weekly-processing action collapses — user
// actions never collapse, even when two look identical, because they
// may be distinct events. Entries are already formatted
// { action, detail, actor, time }; the returned entries carry `count`
// (1 for a single event) and keep the first occurrence's time.
const GROUPABLE_ACTIVITY_ACTIONS = new Set(['Weeks processed']);
export function groupDayActivity(entries) {
  const out = [];
  const seen = new Map();
  for (const e of entries) {
    if (GROUPABLE_ACTIVITY_ACTIONS.has(e.action)) {
      const key = `${e.action}\n${e.detail}`;
      if (seen.has(key)) { seen.get(key).count += 1; continue; }
      const entry = { ...e, count: 1 };
      seen.set(key, entry);
      out.push(entry);
    } else {
      out.push({ ...e, count: 1 });
    }
  }
  return out;
}
