// Weekly-sheet-words-buttons (owner feedback, Nov 3, ~10:48 PM, Weekly
// Budget popup screenshot): (1) "The words don't belong, only number"
// — the Left row showed "-$X (over budget by $X)"; the parenthetical
// is removed, leaving the signed number alone. The minus sign does
// the talking, per the owner's standing numbers-only principle.
// (2) "And the buttons should be centered" — the sheet button row
// (Show transactions + Close) was right-aligned; it is now centered.
// Static tests only — no live data, no network, no money math. The
// Left figure itself is computed exactly as before; only its visible
// text changes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

// Slice the openWeeklySheet body: from its definition to the hero
// target handlers that follow it.
const sheetFn = js.slice(
  js.indexOf('async function openWeeklySheet()'),
  js.indexOf('const heroWeeklyTarget'),
);
assert.ok(sheetFn.length > 0, 'openWeeklySheet body found');

test('Weekly Left row is the signed number alone, no over-budget words', () => {
  assert.equal(
    sheetFn.includes("['Left', formatCents(w.availableCents)]"),
    true,
    'Left row must be exactly formatCents(w.availableCents)',
  );
  assert.equal(
    sheetFn.includes('over budget by'),
    false,
    'no "over budget by" text in the Weekly sheet',
  );
  // The negative-week output is therefore just the signed number:
  // formatCents(-405842) renders "-$4,058.42" with no parenthetical.
  assert.equal(
    sheetFn.includes('(over budget by'),
    false,
    'no over-budget parenthetical anywhere in the Weekly sheet',
  );
});

test('hero aria-label keeps its words for screen readers only', () => {
  // The visible-text removal must not strip the accessibility label:
  // it is not visible text, and it still describes the negative week.
  assert.match(
    js,
    /Weekly Budget, over budget by .*?, show breakdown/,
    'hero aria-label keeps its words',
  );
});

test('Weekly sheet rows and buttons are otherwise unchanged', () => {
  // Weekly-left-only (owner approval, Nov 3, ~11:20 PM): Spent and
  // Allowance are gone from the popup; only Left remains, plus the
  // Show transactions button and Close.
  assert.doesNotMatch(sheetFn, /\['Spent', formatCents\(w\.chargesCents\)\]/);
  assert.doesNotMatch(sheetFn, /\['Allowance', formatCents\(w\.baseAllowanceCents/);
  assert.match(sheetFn, /extraAction: \{ label: 'Show transactions', result: 'show-transactions' \}/);
  assert.match(sheetFn, /confirmLabel: 'Close'/);
});

test('sheet button row is centered', () => {
  const rule = css.match(/#sheetOverlay \.sheet-btns \{[^}]*\}/);
  assert.ok(rule, '.sheet-btns rule found');
  assert.match(rule[0], /justify-content: center/);
  assert.doesNotMatch(rule[0], /justify-content: flex-end/);
});
