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
