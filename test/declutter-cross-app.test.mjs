// Declutter-cross-app (owner, Nov 4, 2026) — Tasks 1–6.
// Static tests + pure-function tests. No DOM, no network, no database,
// no money math changes. Run with: node --test test/declutter-cross-app.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  simplifyActivityDetail, resolveRestoredView, resolveRestoredSubView, scrollStorageKey, historyPeriodLabel,
} from '../filterState.mjs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');

test('version pins: styles v44, live.js v54', () => {
  assert.match(html, /styles\.css\?v=44/);
  assert.match(html, /live\.js\?v=54/);});// ---- Task 1: removed sentences are gone ----
const REMOVED = [
  'Weekly summaries below are the financial record',
  'Closed weeks, read-only — week start, surplus, debt carried',
  'Weekly summaries are above. Below, a shared record',
  'Restorations the refund rules posted',
  'The first account creates the household (as admin)',
  'Record a transaction by hand. It counts as pending',
  'Sample row: 2026-11-01, AMAZON, 12.99, 1005',
  'The preview numbers each row, flags duplicates',
  'Record a gift you already gave.',
  'No tokens or account numbers are shown.',
  'Invite code and account deletion live here now',
  'This never changes your weekly allowance, spending, or debt.',
  'Bank deposits never add fund money by themselves.',
  'Nothing is pulled in automatically — a transfer, refund, reimbursement',
  'To change an old income, correct it below',
  'This records spending from the Extra Fund itself',
  'you can track its decision in the Fund requests list below',
  'Refund restorations, held refunds, and possible duplicates',
  'Nothing here is deleted — Same purchase keeps one row',
  'Extra Fund is the savings story now.',
  'Showing all recorded history.',
];
test('Task 1: removed explainer sentences are absent', () => {
  for (const s of REMOVED) {
    assert.equal(html.includes(s), false, `still in live.html: ${s}`);
    assert.equal(js.includes(s), false, `still in live.js: ${s}`);
  }
});

test('Task 1: kept sentences are present', () => {
  assert.equal((html.match(/Look only — it never moves, sends, or changes anything\./g) || []).length, 2);
  assert.ok(html.includes('Only the admin can change these.'));
  assert.ok(html.includes('Counts as pending until the bank confirms it.'));
  assert.ok(html.includes('Never enter a full card number.'));
  assert.ok(html.includes('Expected columns: Date, Description, Amount, Card Ending.'));
  assert.ok(html.includes('Blank = no limit. Refunds count as negative amounts.'));
  assert.ok(html.includes('Bank rows you deleted live here. The admin can bring them back.'));
  assert.ok(html.includes('Deleting removes you from this household.'));
  assert.ok(js.includes('Trash is empty.'));
  assert.ok(js.includes('No closed weeks yet.'));
});

test('Task 1: period line empty with no filter; count line only when meaningful', () => {
  assert.equal(historyPeriodLabel('', ''), '');
  assert.equal(historyPeriodLabel('2026-11-01', '2026-11-07'), 'Showing 2026-11-01 to 2026-11-07.');
  assert.match(js, /filterActive \|\| listsEmpty/);
  assert.equal(js.includes("Showing entries in the selected period."), false);
});

// ---- Task 2: field spacing ----
test('Task 2: every adjacent pair has a visible gap, own border, no overflow', () => {
  assert.match(css, /#section-history-filter \.form-row-2 \{[^}]*gap: 12px;/);
  assert.match(css, /#section-history-filter \.form-row-2 input \{[^}]*border: 1px solid #e5e7eb; background: #fff;/);
  assert.match(css, /\.form-row-2 \{[^}]*grid-template-columns: minmax\(0, 1fr\) minmax\(0, 1fr\); gap: 12px;/);
  assert.match(css, /\.form-row-3 \{[^}]*grid-template-columns: minmax\(0, 1fr\) minmax\(0, 1fr\) minmax\(0, 1fr\); gap: 12px;/);
  assert.match(css, /#section-manual \.form-row-3 \{[^}]*grid-template-columns: minmax\(0, 1fr\) minmax\(0, 1\.25fr\) minmax\(0, 0\.9fr\); gap: 12px;/);
  assert.match(css, /body\.live \.tx-sheet-pair \{[^}]*gap: 12px;/);
  assert.match(css, /body\.live \.temp-increase-row \.money-input-row input[^}]*min-width: 0; box-sizing: border-box;/);
  assert.equal(css.includes('.form-row-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }'), false);
});

// ---- Task 3: activity detail, plain language, display only ----
test('Task 3: Duplicate merged example — one merchant/amount, no legalese, no Note', () => {
  const out = simplifyActivityDetail('Merged duplicate (TOIREMORG CHARITY $1.00) into the original bank row (TOIREMORG $1.00). Duplicate excluded, not deleted. Note: merge');
  assert.equal(out, 'Counted once: TOIREMORG CHARITY $1.00.');
  assert.equal((out.match(/TOIREMORG CHARITY/g) || []).length, 1);
  assert.equal((out.match(/\$1\.00/g) || []).length, 1);
  assert.equal(out.includes('excluded, not deleted'), false);
  assert.equal(out.includes('Note:'), false);
});

test('Task 3: every other action type simplified', () => {
  assert.equal(simplifyActivityDetail('Kept and as separate purchases. Note: separate'), 'Kept as two separate purchases.');
  assert.equal(simplifyActivityDetail('2 weeks closed, 1 surplus released, 0 refunds restored, 0 refunds held for review.'), '2 weeks closed · 1 surplus released.');
  assert.equal(simplifyActivityDetail('Surplus $123.45 for week Oct 25, 2026 released to the Extra Fund.'), '$123.45 to the Extra Fund · Week of Oct 25, 2026.');
  assert.equal(simplifyActivityDetail('Refund  for purchase week Oct 25, 2026: surplus $1,234.56, debt reduction $0.00, fund $10.00, held $0.00.'), 'Refund for the week of Oct 25, 2026: $1,234.56 left to spend · $10.00 to the Extra Fund.');
  assert.equal(simplifyActivityDetail('TOIREMORG $1.00 excluded — reason: duplicate.'), 'Removed from the week: TOIREMORG $1.00 (duplicate).');
  assert.equal(simplifyActivityDetail('TOIREMORG $1.00 excluded — no reason given.'), 'Removed from the week: TOIREMORG $1.00.');
  assert.equal(simplifyActivityDetail('AMAZON $10.59 restored to the week as posted.'), 'Back in the week: AMAZON $10.59.');
  assert.equal(simplifyActivityDetail('AMAZON $10.59 reclassified from charge to refund — reason: test.'), 'Now counts as a refund: AMAZON $10.59 (test).');
  assert.equal(simplifyActivityDetail('IMPORT TEST $1.00 (manual entry) deleted by admin.'), 'Deleted for good: IMPORT TEST $1.00.');
  assert.equal(simplifyActivityDetail('EXXONMOBIL $33.03 moved to trash — reason: duplicate.'), 'Moved to the Trash: EXXONMOBIL $33.03.');
  assert.equal(simplifyActivityDetail('Default charity rate set to 20% (applies to future incomes only).'), 'Charity rate: 20% for future income.');
  assert.equal(simplifyActivityDetail('Fund spending $50.00.'), 'Spent from the Extra Fund: $50.00.');
  assert.equal(simplifyActivityDetail('Request approved for $33.03.'), 'Extra Fund request approved: $33.03.');
  assert.equal(simplifyActivityDetail('Base allowance set to $375.00.'), 'Weekly allowance: $375.00.');
  assert.equal(simplifyActivityDetail('Weekly allowance set to $425.00 for week Nov 1, 2026.'), 'Weekly allowance: $425.00 for the week of Nov 1, 2026.');
  assert.equal(simplifyActivityDetail('Created via create_household RPC; creator is admin.'), 'Household created.');
  assert.equal(simplifyActivityDetail('Joined via invite code.'), 'Joined the household.');
  // No banned jargon survives in any of the above outputs.
  for (const banned of ['basis points', 'restoration', 'processed ×', 'canonical', 'excluded, not deleted']) {
    assert.equal(simplifyActivityDetail('Merged duplicate (A $1.00) into the original bank row (A $1.00). Duplicate excluded, not deleted. Note: merge').includes(banned), false);
  }
});

test('Task 3: live.js wires the simplification into the display path only', () => {
  assert.match(js, /return simplifyActivityDetail\(d\);/);
  assert.equal(js.includes('update audit_log'), false, 'no stored-row edit in live.js');
});

// ---- Task 4: scroll preservation ----
test('Task 4: refresh never scrolls to top; dedupe repro path is covered', () => {
  assert.match(js, /const savedScrollY = window\.scrollY \|\| 0;/);
  assert.match(js, /showView\(currentView, \{ preserveScroll: true \}\)/);
  assert.match(js, /if \(!opts\.preserveScroll\) window\.scrollTo\(0, 0\);/);
  assert.match(js, /window\.scrollTo\(0, savedScrollY\); requestAnimationFrame\(\(\) => window\.scrollTo\(0, savedScrollY\)\);/);
  // Dedupe actions still do exactly what they did — merge/exclude + refresh — only scroll changes.
  assert.match(js, /p_action: 'merge'[\s\S]*?else await refresh\(\)/s);
  assert.match(js, /p_action: 'separate'[\s\S]*?else await refresh\(\)/s);
  assert.match(js, /'Same purchase', 'Keep one transaction and exclude the other from counts\? Neither row is deleted\.'/);
  // Tab taps still scroll to top (intentional navigation, not a refresh jump).
  assert.match(js, /showView\(b\.dataset\.view, \{ clearMessages: true \}\)/);
});

// ---- Task 5: last-view restore ----
test('Task 5: resolveRestoredView / sub-view / scroll key', () => {
  assert.equal(resolveRestoredView('purchases', 'admin'), 'purchases');
  assert.equal(resolveRestoredView('settings', 'member'), 'settings');
  assert.equal(resolveRestoredView('activity', 'member'), 'activity');
  assert.equal(resolveRestoredView('', 'admin'), 'week');
  assert.equal(resolveRestoredView('bogus', 'admin'), 'week');
  assert.equal(resolveRestoredSubView('purchases', 'trash', 'admin'), 'trash');
  assert.equal(resolveRestoredSubView('purchases', 'trash', 'member'), null);
  assert.equal(resolveRestoredSubView('week', 'trash', 'admin'), null);
  assert.equal(scrollStorageKey('money'), 'hb-scroll-money');
});

test('Task 5: live.js persists every view incl. Settings, plus scroll, plus Trash sub-view', () => {
  assert.equal(js.includes("if (name !== 'settings') localStorage.setItem('hb-view', name)"), false);
  assert.match(js, /localStorage\.setItem\(VIEW_STORAGE_KEY, name\)/);
  assert.match(js, /localStorage\.setItem\(PREV_VIEW_STORAGE_KEY, previousView\)/);
  assert.match(js, /window\.addEventListener\('beforeunload'/);
  assert.match(js, /localStorage\.setItem\('hb-view-sub', nowHidden \? '' : 'trash'\)/);
  assert.match(js, /resolveRestoredSubView\(currentView, localStorage\.getItem\('hb-view-sub'\), household\?\.role\)/);
  assert.match(js, /const saved = Number\(localStorage\.getItem\(scrollStorageKey\(currentView\)\)\)/);
  // Auth / household screens still come first in boot().
  assert.match(js, /if \(!session\) \{ await show\('auth'\); return; \}/);
  assert.match(js, /if \(!household\) \{ await show\('household'\); return; \}/);
});

// ---- Task 6: footer never shows Updating ----
test('Task 6: footer is the last-sync line only, in every state', () => {
  assert.match(html, /OnBudget · Last bank sync <span id="lastSync">—<\/span>\s*\n<\/footer>/);
  assert.equal(html.includes('refreshState'), false);
  assert.equal(js.includes('refreshState'), false);
  assert.equal(js.includes("textContent = 'Updating"), false);
  // Last-sync wording and assignment are untouched.
  assert.match(js, /getElementById\('lastSync'\)/);
  // Bank sync keeps its own busy state, restored in finally on success AND failure.
  assert.match(js, /syncBtn\.textContent = 'Syncing…'/);
  assert.match(js, /syncBtn\.disabled = false; syncBtn\.textContent = savedSyncText;/);
  assert.match(js, /homeBtn\.classList\.remove\('syncing'\)/);
});

// ---- Task 7: smarter Funds bottom section (Option A) ----
test('Task 7: three old cards, triangles, and sentences are gone', () => {
  assert.equal(html.includes('id="section-fund-actions"'), false);
  assert.equal(html.includes('id="section-fund-review"'), false);
  assert.equal(html.includes('id="section-savings-past"'), false);
  assert.equal(html.includes('id="fundTopupsDisclosure"'), false);
  assert.equal(html.includes('id="charityIncomeDisclosure"'), false);
  assert.equal(html.includes('id="reviewDetails"'), false);
  assert.equal(html.includes('id="reviewSummary"'), false);
  assert.equal(html.includes('id="pastSavingsToggle"'), false);
  assert.equal(html.includes('id="pastSavingsWrap"'), false);
  assert.equal(html.includes('View activity · Money added'), false);
  assert.equal(html.includes('View activity · Charity income'), false);
  assert.equal(html.includes('Open review'), false);
  assert.equal(html.includes('Older savings records, read-only.'), false);
  assert.equal(html.includes('Pairs that may have been counted twice.'), false);
  // The Fund requests disclosure inside the Ask form is NOT a deleted
  // card and stays.
  assert.ok(html.includes('View activity · Fund requests'));
});

test('Task 7: one quiet More card with › rows, no triangles', () => {
  assert.ok(html.includes('id="section-fund-more"'));
  assert.ok(html.includes('id="moreFundActivityBtn"'));
  assert.ok(html.includes('id="moreReviewBtn"'));
  assert.ok(html.includes('id="moreSavingsBtn"'));
  assert.ok(html.includes('<span id="moreReviewLabel">Review</span>'));
  for (const id of ['moreFundActivityBtn', 'moreReviewBtn', 'moreSavingsBtn']) {
    const row = html.slice(html.indexOf(`id="${id}"`) - 40, html.indexOf(`id="${id}"`) + 200);
    assert.ok(row.includes('›'), `${id} has a chevron`);
  }
  assert.equal(html.includes('▶'), false, 'no triangles in live.html More rows');
  assert.match(css, /\.more-row \{[^}]*display: flex; justify-content: space-between;/);
  // The moved content keeps its ids, so refresh() still populates it.
  for (const id of ['fundTopupsList', 'charityIncomeList', 'restorationList', 'heldList', 'dedupeList', 'savingsSummary', 'savingsList']) {
    assert.ok(html.includes(`id="${id}"`), `${id} still rendered`);
  }
  assert.ok(html.includes('id="section-fund-activity-more"'));
  assert.ok(html.includes('id="section-fund-review-more"'));
  assert.ok(html.includes('id="section-savings-more"'));
});

test('Task 7: Review count shows only when something needs review', () => {
  assert.match(js, /reviewNeedsCount = \(heldRows2 \?\? \[\]\)\.filter\(\(h\) => h\.status === 'pending'\)\.length;/);
  assert.match(js, /reviewNeedsCount \+= \(candRows \?\? \[\]\)\.length;/);
  assert.match(js, /lbl\.textContent = reviewNeedsCount > 0 \? `Review \(\$\{reviewNeedsCount\}\)` : 'Review';/);
  // Restorations (already posted history) do not feed the count.
  assert.equal(js.includes('restRows') && js.includes('reviewNeedsCount = (restRows'), false);
});

test('Task 7: three fund actions live in the Extra Fund sheet, original order/treatments/gating', () => {
  const sheet = js.slice(js.indexOf('async function openFundSheet'), js.indexOf(": [{ label: 'Ask for fund money'"));
  assert.deepEqual([...sheet.matchAll(/label: '([^']+)'/g)].map((m) => m[1]), ['Add money', 'Use fund money', 'Ask for fund money']);
  assert.deepEqual([...sheet.matchAll(/btnClass: '([^']+)'/g)].map((m) => m[1]), ['btn btn-primary', 'btn', 'btn btn-tertiary']);
  assert.deepEqual([...sheet.matchAll(/result: '([^']+)'/g)].map((m) => m[1]), ['add', 'use', 'ask']);
  // Members see Ask only, in the same tertiary treatment.
  assert.ok(js.includes(": [{ label: 'Ask for fund money', result: 'ask', btnClass: 'btn btn-tertiary' }]"));
  // Choosing an action opens the same form as the old card buttons did.
  assert.match(js, /if \(result === 'add'\) setFundForm\('add'\);/);
  assert.match(js, /else if \(result === 'use'\) setFundForm\('use'\);/);
  assert.match(js, /else if \(result === 'ask'\) setFundForm\('ask'\);/);
  // Funds panel gets actions; Home stat card stays read-only.
  assert.ok(js.includes('await openFundSheet(true)'));
  assert.ok(js.includes('await openFundSheet(false)'));
  // Charity Record income stays in the Charity sheet, not in More.
  assert.match(js, /extraAction: isAdmin \? \{ label: 'Record income', result: 'record-income' \} : null/);
  assert.equal(html.slice(html.indexOf('id="section-fund-more"'), html.indexOf('id="section-fund-activity-more"')).includes('Record income'), false);
  // More rows gate by role exactly as the old content did.
  assert.match(js, /setBtn\('moreFundActivityBtn', !!isAdmin\)/);
  assert.match(js, /setBtn\('moreReviewBtn', !!isAdmin\)/);
  assert.match(js, /setBtn\('moreSavingsBtn', true\)/);
});
