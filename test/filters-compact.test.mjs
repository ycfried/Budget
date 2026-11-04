// Filters-compact (Nov 3, 2026) tests — run with:
//   node --test test/filters-compact.test.mjs
// One consistent labeling system: From/To always means dates, Min/Max
// always means amounts; pill dates use the short "Oct 1" style with
// the year only for non-current years. No filter logic is tested
// here beyond the labels — matching behaviour is unchanged.
// No DOM, no network, no database; the sheet checks read live.html
// as static text, the same file the app ships.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { activeFilterLabels, formatShortDate } from '../filterState.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const liveHtml = readFileSync(path.join(root, 'live.html'), 'utf8');
const stylesCss = readFileSync(path.join(root, 'styles.css'), 'utf8');
const sheet = liveHtml.slice(
  liveHtml.indexOf('id="txFiltersSheet"'),
  liveHtml.indexOf('id="txCount"'),
);

test('pill labels: From/To are dates, Min/Max are amounts — no collision', () => {
  const year = new Date().getFullYear();
  const labels = activeFilterLabels({
    status: 'pending',
    monthLabel: 'November 2026',
    cardLabel: '••1005',
    minLabel: '$10.00',
    maxLabel: '$50.00',
    weekOnly: true,
    fromDate: `${year}-10-01`,
    toDate: `${year}-10-31`,
  });
  const byKey = Object.fromEntries(labels.map((l) => [l.key, l.label]));
  assert.equal(byKey.min, 'Min $10.00');
  assert.equal(byKey.max, 'Max $50.00');
  assert.equal(byKey.from, 'From Oct 1');
  assert.equal(byKey.to, 'To Oct 31');
  assert.equal(byKey.week, 'This week');
  assert.ok(!labels.some((l) => l.label.startsWith('Up to')), 'no "Up to" label remains');
});

test('pill dates: short format, year only for non-current years', () => {
  const year = new Date().getFullYear();
  assert.equal(formatShortDate(`${year}-01-05`), 'Jan 5');
  assert.equal(formatShortDate(`${year - 1}-12-25`), 'Dec 25, ' + (year - 1));
  assert.equal(formatShortDate('not-a-date'), 'not-a-date');
  assert.equal(formatShortDate(''), '');
});

test('sheet labels: no duplicate heading+label, new From/To and Min/Max only', () => {
  assert.ok(sheet.includes('<h4>When</h4>'), 'Dates group is headed When');
  assert.ok(!sheet.includes('<h4>Dates</h4>'), 'old Dates heading is gone');
  assert.ok(!sheet.includes('From date'), 'no From date label');
  assert.ok(!sheet.includes('To date'), 'no To date label');
  assert.ok(!sheet.includes('From ($)'), 'no From ($) label');
  assert.ok(!sheet.includes('To ($)'), 'no To ($) label');
  assert.ok(!sheet.includes('This week only'), 'no This week only label');
  assert.ok(sheet.includes('<label>From'), 'date field is From');
  assert.ok(sheet.includes('<label>To'), 'date field is To');
  assert.ok(sheet.includes('<label>Min'), 'amount field is Min');
  assert.ok(sheet.includes('<label>Max'), 'amount field is Max');
  assert.ok(sheet.includes('> This week</label>'), 'week checkbox is This week');
  // Count visible labels, not substrings (the id txStatusSelect itself
  // contains "Status" and would otherwise double-count).
  const count = (pattern) => (sheet.match(new RegExp(pattern, 'g')) ?? []).length;
  assert.equal(count('<label>Status'), 1, 'Status label appears exactly once in the sheet');
  assert.equal(count('<label>Card / Account'), 1, 'Card / Account label appears exactly once in the sheet');
  assert.equal(count('<h4>When</h4>'), 1, 'When heading appears exactly once in the sheet');
});

test('sheet amount explainer is one short line, not a paragraph', () => {
  assert.ok(sheet.includes('Blank = no limit. Refunds count as negative amounts.'));
  assert.ok(!sheet.includes('Amounts compare to the signed amount'), 'old long explainer is gone');
});

test('sheet controls are compact, sheet-scoped, and still ~40px tap targets', () => {
  assert.ok(stylesCss.includes('body.live .tx-sheet-card { padding: 14px; }'), 'sheet padding 14px');
  assert.ok(
    stylesCss.includes('body.live .tx-sheet-card input, body.live .tx-sheet-card select { padding: 10px; margin: 2px 0 6px; font-size: 15px; }'),
    'sheet inputs 10px padding at 15px font (10 + 10 + 18 line-height + 2 border = 40px)',
  );
  assert.ok(stylesCss.includes('body.live .tx-sheet-card .btn { padding: 11px 14px; }'), 'sheet buttons compact');
  // Compact rules are scoped to the sheet: the app-wide input rule is untouched.
  assert.ok(stylesCss.includes('padding: 11px 12px;'), 'app-wide input padding unchanged');
});
