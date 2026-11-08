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
// Filters-compact (Nov 3, 2026) — one consistent labeling system:
// From/To always means dates, Min/Max always means amounts. The old
// pills collided: amount min was "From $X" while date from was
// "From YYYY-MM-DD", and both amount max and date to were "Up to …".
// Pill dates use the app's short "Oct 1" style, not YYYY-MM-DD:
// the year is added only when the date is not in the current year
// (e.g. "Oct 1, 2025"), so current-year pills stay short and clear.
// A non-YYYY-MM-DD value is returned unchanged, never dropped.
export function formatShortDate(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso ?? ''));
  if (!m) return String(iso ?? '');
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const monthName = new Date(Date.UTC(year, month - 1, 1))
    .toLocaleString('en-US', { month: 'short', timeZone: 'UTC' });
  if (year === new Date().getFullYear()) return `${monthName} ${day}`;
  return `${monthName} ${day}, ${year}`;
}
// Native-style-live (owner, Nov 4): display-only merchant/date
// wording. Stored values are never changed: bank names arrive in
// ALL CAPS, dates as YYYY-MM-DD; the screen shows Title Case and
// Today/Yesterday for today/yesterday (NY date, via the caller's
// today string). Words that are already mixed-case are left alone
// except for an all-caps run, so "McDonald's" style names are not
// mangled by a blind title-caser.
export function titleCaseMerchant(name) {
  const s = String(name ?? '');
  if (!s) return s;
  return s.split(/(\s+|[-/])/).map((part) => {
    if (/^\s+$/.test(part) || part === '-' || part === '/') return part;
    if (part !== part.toUpperCase() || part.length <= 1) return part;
    return part.charAt(0).toUpperCase() + part.slice(1).toLowerCase();
  }).join('');
}
export function relativeDayLabel(iso, todayIso) {
  const d = String(iso ?? '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(d) || !todayIso) return null;
  const t = String(todayIso).slice(0, 10);
  if (d === t) return 'Today';
  const dt = new Date(`${t}T12:00:00Z`);
  dt.setUTCDate(dt.getUTCDate() - 1);
  const y = `${dt.getUTCFullYear()}-${String(dt.getUTCMonth() + 1).padStart(2, '0')}-${String(dt.getUTCDate()).padStart(2, '0')}`;
  if (d === y) return 'Yesterday';
  return null;
}
export function activeFilterLabels(f) {
  const labels = [];
  if (f.status && f.status !== 'all') {
    labels.push({ key: 'status', label: STATUS_LABELS[f.status] ?? f.status });
  }
  if (f.monthLabel) labels.push({ key: 'month', label: f.monthLabel });
  if (f.cardLabel) labels.push({ key: 'card', label: f.cardLabel });
  if (f.minLabel != null) labels.push({ key: 'min', label: `Min ${f.minLabel}` });
  if (f.maxLabel != null) labels.push({ key: 'max', label: `Max ${f.maxLabel}` });
  if (f.weekOnly) labels.push({ key: 'week', label: 'This week' });
  if (f.fromDate) labels.push({ key: 'from', label: `From ${formatShortDate(f.fromDate)}` });
  if (f.toDate) labels.push({ key: 'to', label: `To ${formatShortDate(f.toDate)}` });
  return labels;
}

// History period line (B1). States the active period so a filter can
// never silently make records disappear; with no filter it says so.
export function historyPeriodLabel(from, to) {
  // Declutter-cross-app, Task 1: with no filter there is nothing to
  // state — the period line stays empty instead of repeating
  // "Showing all recorded history." on every History visit.
  if (!from && !to) return '';
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

// Send-live-bundle, activity timeline dots (display only): charity
// rows get green, system rows (week closes, household creation) get
// grey, everything else money-related gets brand blue.
export function activityDotClass(action, detail) {
  const text = `${action ?? ''} ${detail ?? ''}`;
  if (/charity/i.test(text)) return 'charity';
  if (/weeks processed|week.*closed|household created/i.test(text)) return 'system';
  return 'money';
}

// Send-live-bundle, activity title (display only): a collapsed
// "Weeks processed ×N" group reads as "N weeks closed", never with
// the internal "processed" wording or the × count suffix.
export function activityTitle(action, count) {
  if (action === 'Weeks processed') return `${count} ${count === 1 ? 'week' : 'weeks'} closed`;
  return action;
}


// Declutter-cross-app, Task 3 (owner, Nov 4): plain-language activity
// detail, display only — stored audit_log rows are never edited.
// Input is the already-formatted detail (cents -> $, dates -> long
// form, basis points -> %, "canonical" -> "original"). Output is one
// short line: the merchant/amount appears once, never twice; no
// "excluded, not deleted", no "Note: merge/separate", no internal
// split labels (surplus / debt reduction / fund / held become plain
// words), and zero-amount parts are dropped.
const KIND_WORDS = {
  charge: 'a charge', refund: 'a refund', fund_charge: 'Extra Fund spending',
  transfer: 'a transfer', payment: 'a card payment', cashback: 'cash back',
};
function isZeroAmount(a) {
  return /^-?\$0\.00$/.test(String(a ?? '').trim());
}
export function simplifyActivityDetail(detail) {
  let d = String(detail ?? '').trim();
  if (!d) return d;
  // Duplicate merged (the owner's screenshot case): "Merged duplicate
  // (TOIREMORG CHARITY $1.00) into the original bank row (TOIREMORG
  // $1.00). Duplicate excluded, not deleted. Note: merge" -> one
  // merchant/amount, counted once. The trailing note is always the
  // default 'merge'/'separate' (the app never prompts for a note
  // here), so dropping it loses nothing a user typed.
  let m = d.match(/^Merged duplicate \(([^)]+)\) into (?:the original bank row|original) \([^)]+\)[^.]*\.?/i);
  if (m) return `Counted once: ${m[1].trim()}.`;
  // Duplicate kept separate: "Kept <id> and <id> as separate
  // purchases. Note: separate" (ids already stripped upstream) ->
  // plain, no ids, no note.
  if (/^Kept .*as separate purchases/i.test(d)) return 'Kept as two separate purchases.';
  // Weeks processed summary: drop zero parts, join the rest plainly.
  // "2 weeks closed, 1 surplus released, 0 refunds restored, 0 refunds
  // held for review." -> "2 weeks closed · 1 surplus released."
  if (/week(s)? closed/i.test(d) && /release/i.test(d)) {
    const parts = d.replace(/\.$/, '').split(',').map((x) => x.trim()).filter((x) => !/^0\b/.test(x));
    if (parts.length) return `${parts.join(' · ')}.`;
  }
  // Surplus released: "Surplus $X for week Oct 25, 2026 released to
  // the Extra Fund." -> "$X to the Extra Fund · Week of Oct 25, 2026."
  m = d.match(/^Surplus (\$[\d,]+\.\d{2}) for week (.+?) released to the Extra Fund\.?$/i);
  if (m) return `${m[1]} to the Extra Fund · Week of ${m[2].trim()}.`;
  // Refund restoration: "Refund ... for purchase week Oct 25, 2026:
  // surplus $X, debt reduction $Y, fund $Z, held $W." -> plain parts,
  // zero parts dropped, internal labels translated.
  m = d.match(/^Refund .*for purchase week (.+?): surplus (\$[\d,]+\.\d{2}), debt reduction (\$[\d,]+\.\d{2}), fund (\$[\d,]+\.\d{2}), held (\$[\d,]+\.\d{2})\.?$/i);
  if (m) {
    const plain = [
      [m[2], 'left to spend'], [m[3], 'paid off debt'],
      [m[4], 'to the Extra Fund'], [m[5], 'held for review'],
    ].filter(([amt]) => !isZeroAmount(amt)).map(([amt, word]) => `${amt.trim()} ${word}`);
    return plain.length
      ? `Refund for the week of ${m[1].trim()}: ${plain.join(' · ')}.`
      : `Refund for the week of ${m[1].trim()}.`;
  }
  // Transaction excluded / restored / reclassified / deleted / trash.
  m = d.match(/^(.+?) excluded(?: — reason: (.+?)| — no reason given)?\.?$/i);
  if (m) {
    const reason = (m[2] ?? '').trim();
    return reason && !/no reason given/i.test(reason)
      ? `Removed from the week: ${m[1].trim()} (${reason}).`
      : `Removed from the week: ${m[1].trim()}.`;
  }
  m = d.match(/^(.+?) restored to the week as (?:posted|pending)\.?$/i);
  if (m) return `Back in the week: ${m[1].trim()}.`;
  m = d.match(/^(.+?) reclassified from (\w+) to (\w+)(?: — reason: (.+?)| — no reason given)?\.?$/i);
  if (m) {
    const to = KIND_WORDS[m[3]] ?? m[3];
    return (m[4] && !/no reason given/i.test(m[4]))
      ? `Now counts as ${to}: ${m[1].trim()} (${m[4].trim()}).`
      : `Now counts as ${to}: ${m[1].trim()}.`;
  }
  m = d.match(/^(.+?) \(manual entry\) deleted by admin\.?$/i);
  if (m) return `Deleted for good: ${m[1].trim()}.`;
  m = d.match(/^(.+?) moved to trash(?: — reason: (.+?))?\.?$/i);
  if (m) return `Moved to the Trash: ${m[1].trim()}.`;
  // Charity / fund / household / allowance: strip internal wording,
  // keep the fact in one short line.
  d = d.replace(/^Default charity rate set to ([^ ]+)( \(applies to future incomes only\))?\.?$/i, 'Charity rate: $1 for future income.');
  d = d.replace(/^Income (.+?) at ([^ ]+) commits (.+?) to charity\.?$/i, 'Income $1 — $3 to charity.');
  d = d.replace(/^Gift (.+?) on (.+?)\.?$/i, 'Gift given: $1 on $2.');
  d = d.replace(/^Fund spending (.+?)( \(override: .+?\))?\.?$/i, 'Spent from the Extra Fund: $1.');
  d = d.replace(/^Request.*approved for (.+?)( \(split; remainder .+?\))?( \(override: .+?\))?\.?$/i, 'Extra Fund request approved: $1.');
  d = d.replace(/^Request.*approved\.?$/i, 'Extra Fund request approved.');
  d = d.replace(/^Request.*declined\.?$/i, 'Extra Fund request declined.');
  d = d.replace(/^Base allowance set to (.+?)\.?$/i, 'Weekly allowance: $1.');
  d = d.replace(/^Weekly allowance set to (.+?) for week (.+?)\.?$/i, 'Weekly allowance: $1 for the week of $2.');
  d = d.replace(/^Temporary increase (.+?) for week (.+?)\.?$/i, 'Weekly allowance raised by $1 for the week of $2.');
  d = d.replace(/^Fund shortfall changed from (.+?) to (.+?)\.?$/i, 'Extra Fund shortfall: $2.');
  d = d.replace(/^Created via create_household RPC.*$/i, 'Household created.');
  d = d.replace(/^Joined via invite code\.?$/i, 'Joined the household.');
  d = d.replace(/\s{2,}/g, ' ').replace(/\.{2,}/g, '.').trim();
  return d;
}

// Declutter-cross-app, Task 5 (owner, Nov 4): last-view restore.
// MAIN_VIEWS are the pages a reload may open. Settings is included
// now (it was previously never persisted, so a reload from Settings
// landed on Home). A sheet/popup is never a restored view: callers
// pass the underlying page, never the popup. Trash is a sub-view of
// Transactions and is admin-only: a member restoring it falls back
// to the Transactions list, not the Trash.
export const MAIN_VIEWS = ['week', 'purchases', 'money', 'activity', 'settings', 'prevweeks']; // Merged-audit B3: Previous Weeks is a restorable page, like Activity.
export const VIEW_STORAGE_KEY = 'hb-view';
export const PREV_VIEW_STORAGE_KEY = 'hb-prev-view';
export function scrollStorageKey(view) {
  return `hb-scroll-${view}`;
}
export function resolveRestoredView(saved, role) {
  if (!MAIN_VIEWS.includes(saved)) return 'week';
  return saved;
}
export function resolveRestoredSubView(view, sub, role) {
  if (view === 'purchases' && sub === 'trash' && role === 'admin') return 'trash';
  return null;
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

// Delta3: week-close activity-log condition, mirrored from
// supabase/functions/week-close/index.ts. The server writes a "Weeks
// processed" row ONLY when the run actually changed something; this
// helper is the client-side/testable copy of that condition. Legacy
// held releases are deliberately NOT here: they are counted, never
// changed, so observing one is not "something happened".
export function shouldLogWeekClose({ weeksClosed = 0, releasesDone = 0, restorations = 0, heldCreated = 0 } = {}) {
  return weeksClosed > 0 || releasesDone > 0 || restorations > 0 || heldCreated > 0;
}

// Delta3: client week-close due-check. The app stores the week start
// of the last successful week-close check (localStorage, per
// household). A new check is due when there is no stored check, or
// when the calendar week has rolled over since the stored one — i.e.
// a week may have completed since the last check. Within the same
// week the call is skipped: the server would be a silent no-op
// anyway, and skipping avoids the reload-spam call entirely. When
// due-ness cannot be determined (no current week start loaded) the
// caller falls back to calling, because the server no-op is silent.
// Week starts are YYYY-MM-DD, so plain string comparison orders them.
export function isWeekCloseCheckDue({ lastCheckedWeekStart = null, currentWeekStart = null } = {}) {
  if (!currentWeekStart) return true;
  if (!lastCheckedWeekStart) return true;
  return lastCheckedWeekStart < currentWeekStart;
}

// Delta3: CSV import kind, kept consistent with the server
// classifyKind transfer-first rule (canonical.ts). An INTERNAL
// TRANSFER row in a CSV file imports as kind='transfer' (excluded
// from week math), never as a charge or a refund by sign. Every other
// row keeps the old sign rule.
// Merged-audit B11: detail actions restricted by transaction kind.
// Charge: Charity (admin + verified only), Extra Fund (any role),
// Other (admin), Delete (admin). Transfer/payment/cashback/
// fund_charge: Other + Delete (admin only) — these rows never count
// toward weekly spending, so there is no Charity or Extra Fund
// action for them. Charity: Delete only (as before). Members get
// Extra Fund on charges only; every other action is admin-only.
export function actionsForTxKind(kind, isAdmin, isVerified) {
  if (kind === 'charity') return isAdmin ? ['delete'] : [];
  if (kind === 'charge') {
    // P1-NEW1 (Nov 8, 2026): Charity is offered on any charge,
    // regardless of posted status — the sheet renders it disabled
    // with honest copy when pending (admin) or for members (ask the
    // admin). The guarded mark_transaction_charity RPC still enforces
    // posted + unlocked week when it is actually tapped.
    const out = ['charity'];
    out.push('extraFund');
    if (isAdmin) out.push('other', 'delete');
    return out;
  }
  if (kind === 'transfer' || kind === 'payment' || kind === 'cashback' || kind === 'fund_charge') {
    return isAdmin ? ['other', 'delete'] : [];
  }
  // P0-1 (Nov 8, 2026): a refund gets Link to purchase first (admin
  // only) — linking is what makes restoration reachable. Members get
  // no actions on a refund, as before.
  if (kind === 'refund') {
    return isAdmin ? ['linkRefund', 'other', 'delete'] : [];
  }
  return isAdmin ? ['other', 'delete'] : [];
}
// P1-R2 (Nov 8, 2026): Gmail Testing-mode tokens expire ~7 days
// after the grant, with no pre-expiry warning anywhere. Returns the
// warning keys for one email_connections_public row: 'expiring' when
// the grant (connected_at, falling back to created_at) is more than
// 5 days old, 'stale' when last_poll_at is more than 24h old. The
// card already shows "Needs reconnect" for status='error', so that
// case returns nothing here.
export function emailConnectionWarnings(c, nowMs = Date.now()) {
  if (!c || c.status === 'error') return [];
  const out = [];
  const grantRaw = c.connected_at ?? c.created_at;
  const grantMs = grantRaw ? Date.parse(grantRaw) : NaN;
  if (!Number.isNaN(grantMs) && nowMs - grantMs > 5 * 24 * 3600 * 1000) out.push('expiring');
  const lastMs = c.last_poll_at ? Date.parse(c.last_poll_at) : NaN;
  if (!Number.isNaN(lastMs) && nowMs - lastMs > 24 * 3600 * 1000) out.push('stale');
  return out;
}

export function classifyCsvKind(merchant, amountCents) {
  // Deep audit Nov 5: was transfer-or-sign only, so a CSV
  // "PAYMENT - THANK YOU" or "CASH BACK" row imported as kind='refund'.
  // Mirrors supabase/functions/_shared/canonical.ts classifyKind
  // (same patterns, same order); Plaid category is unavailable for
  // CSV rows, so only the name patterns are checked here.
  const name = String(merchant ?? '');
  if (/INTERNAL TRANSFER/i.test(name)) return 'transfer';
  // Refund-classification fix (Nov 5, 2026): mirrors canonical.ts —
  // a check deposit is income, a payment credit is a payment; CSV
  // rows carry no account type, so only the name patterns apply here.
  if (amountCents < 0 && /CHECK DEPOSIT|MOBILE DEPOSIT|\bDEPOSIT\b/i.test(name)) return 'income';
  if (/MOBILE PAYMENT|PAYMENT - THANK YOU|CARD PAYMENT|PAYMENT\s*:\s*CREDIT|PAYMENT CREDIT|\/ ?PAYMENT|EPAYMENT|E-PAYMENT|ACH PAYMENT/i.test(name)) return 'payment';
  if (/CASH BACK|CASHBACK|REWARD/i.test(name)) return 'cashback';
  // P1-NEW1 (Nov 8, 2026): charity auto-detect, money-out only —
  // same conservative list as canonical.ts CHARITY_PATTERN.
  if (amountCents > 0 && /\b(CHARITY|DONATION|DONATE|TZEDAKA|TZEDAKAH|KEREN|CHABAD|TOIREMORG|COLEL)\b/i.test(name)) return 'charity';
  return amountCents < 0 ? 'refund' : 'charge';
}
