// Delta package (Nov 3, 2026) tests — run with:
//   node --test test/delta-package.test.mjs
// Pure helpers from filterState.mjs: Transactions active-filter labels
// (B2), History period line + date filtering (B1), sync guard (B3).
// No DOM, no network, no database.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  activeFilterLabels,
  historyPeriodLabel,
  filterRowsByDate,
  createSyncGuard,
} from '../filterState.mjs';

test('activeFilterLabels: no narrowing filter means no labels', () => {
  assert.deepEqual(activeFilterLabels({ status: 'all' }), []);
  assert.deepEqual(activeFilterLabels({}), []);
});

test('activeFilterLabels: each active filter gets its own removable label', () => {
  const labels = activeFilterLabels({
    status: 'pending',
    monthLabel: 'November 2026',
    cardLabel: '••1005',
    minLabel: '$10.00',
    maxLabel: '$50.00',
    weekOnly: true,
    fromDate: '2026-11-01',
    toDate: '2026-11-07',
  });
  assert.deepEqual(labels.map((l) => l.key), ['status', 'month', 'card', 'min', 'max', 'week', 'from', 'to']);
  assert.equal(labels[0].label, 'Pending');
  assert.equal(labels[5].label, 'This week');
});

test('activeFilterLabels: a single bound alone still labels', () => {
  assert.deepEqual(activeFilterLabels({ minLabel: '$5.00' }), [{ key: 'min', label: 'From $5.00' }]);
});

test('historyPeriodLabel: states the period, or that there is no filter', () => {
  assert.equal(historyPeriodLabel('', ''), 'Showing all recorded history.');
  assert.equal(historyPeriodLabel('2026-11-01', '2026-11-07'), 'Showing 2026-11-01 to 2026-11-07.');
  assert.equal(historyPeriodLabel('2026-11-01', ''), 'Showing from 2026-11-01 onward.');
  assert.equal(historyPeriodLabel('', '2026-11-07'), 'Showing up to 2026-11-07.');
});

test('filterRowsByDate: keeps in-range rows, drops out-of-range, keeps dateless rows', () => {
  const rows = [
    { d: '2026-11-01' }, { d: '2026-11-05' }, { d: '2026-11-09' }, { d: '' },
  ];
  const out = filterRowsByDate(rows, (r) => r.d, '2026-11-02', '2026-11-08');
  assert.deepEqual(out.map((r) => r.d), ['2026-11-05', '']);
  assert.equal(filterRowsByDate(rows, (r) => r.d, '', '').length, 4);
});

test('createSyncGuard: second start is refused until finish', () => {
  const guard = createSyncGuard();
  assert.equal(guard.isRunning(), false);
  assert.equal(guard.tryStart(), true);
  assert.equal(guard.isRunning(), true);
  assert.equal(guard.tryStart(), false);
  guard.finish();
  assert.equal(guard.isRunning(), false);
  assert.equal(guard.tryStart(), true);
  guard.finish();
});
