// P2-F1–F13, P2-N1, P2-N2, P2-N4, P2-C4 (third re-audit, Nov 8, 2026)
// — client-UI P2 batch. Branch-only; no live change. Static tests
// only: no live data, no network, no money math. P2-F4 is NOT fixed
// here (owner decision owed); its test pins the header order as-is
// so a later swap is a deliberate change, not drift.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { merchantStem } from '../filterState.mjs';

const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const reset = readFileSync(new URL('../reset.html', import.meta.url), 'utf8');
const sw = readFileSync(new URL('../live-sw.js', import.meta.url), 'utf8');
const linkSql = readFileSync(new URL('../supabase/refund-linking.sql', import.meta.url), 'utf8');

// ---- P2-F1: gift pre-Nov date is an inline field error, not a dialog ----
test('P2-F1: gift form pre-Nov date uses setGiftError, not a dialog', () => {
  assert.ok(js.includes("setGiftError('Date: gifts before November 2026 are outside the charity period.', f.date)"), 'pre-Nov gift date is an inline error');
  assert.equal(js.includes("showAlert('Charity starts November 2026'"), false, 'no pre-Nov gift dialog remains');
});

// ---- P2-F2: lone submits are primary blue, never pale ----
test('P2-F2: the three lone submits are btn-primary', () => {
  assert.ok(html.includes('<button class="btn btn-primary" type="submit" aria-label="Save the default charity rate">Save default rate</button>'), 'Save default rate is primary');
  assert.ok(html.includes('<button class="btn btn-primary" type="submit" aria-label="Record spending from the Extra Fund">Record it</button>'), 'Record it is primary');
  assert.ok(html.includes('<label class="btn btn-primary csv-file-btn" for="csvFile">Choose file</label>'), 'Choose file is primary');
});

// ---- P2-F3: sort row has no two adjacent pale controls ----
test('P2-F3: sort direction button is grey tertiary beside the pale select', () => {
  assert.ok(html.includes('<button id="txSortDirBtn" class="btn btn-tertiary"'), 'direction button is tertiary grey');
  assert.match(css, /body\.live #txSortField \{ background: #bfdbfe;/, 'select stays pale secondary');
  assert.ok(css.includes('P2-F3'), 'sort comment records the fix');
});

// ---- P2-F4: owner decision Nov 8 — SWAP, + Add primary first, Filters grey second ----
test('P2-F4: Transactions header order is swapped — + Add primary first, Filters grey second', () => {
  assert.ok(html.indexOf('id="txAddBtn"') < html.indexOf('id="txFiltersToggle"'), 'Add precedes Filters in the header');
  assert.ok(html.includes('id="txFiltersToggle" class="btn btn-tertiary"'), 'Filters still grey tertiary');
  assert.ok(html.includes('class="btn btn-primary add-plus-btn" id="txAddBtn"'), 'Add still primary');
});

// ---- P2-F5: one "Past Weeks" heading ----
test('P2-F5: exactly one Past Weeks heading; the filter card is "Filter by Date"', () => {
  assert.ok(html.includes('<h2>Filter by Date</h2>'), 'history filter card renamed');
  assert.equal((html.match(/>Past Weeks<\/h2>/g) ?? []).length, 1, 'only the page head still says Past Weeks');
  assert.ok(html.includes('<h2 tabindex="-1">Past Weeks</h2>'), 'page head kept');
});

// ---- P2-F6: Title Case — minor word "from" lower unless first ----
test('P2-F6: "from" is lowercase in the CSV heading and the fund sheet title', () => {
  assert.ok(html.includes('Import Transactions from a CSV File'), 'CSV heading fixed');
  assert.equal(html.includes('Import Transactions From a CSV File'), false, 'no capital From in the CSV heading');
  assert.ok(js.includes("title: 'Approve from the Fund'"), 'fund sheet title fixed');
  assert.equal(js.includes("title: 'Approve From the Fund'"), false, 'no capital From in the fund sheet title');
});

// ---- P2-F7: dead settingsPasswordBtn handler is gone ----
test('P2-F7: settingsPasswordBtn binding deleted; the real button stays wired', () => {
  assert.equal(js.includes('settingsPasswordBtn'), false, 'no reference to the missing element remains');
  assert.ok(js.includes("document.getElementById('profilePasswordBtn')?.addEventListener('click', changePasswordFlow)"), 'Change password still wired via profilePasswordBtn');
});

// ---- P2-F8: showSheet comment describes the layout that exists ----
test('P2-F8: showSheet comment no longer describes a three-button sheet', () => {
  assert.equal(js.includes('a three-button sheet (cancel + extra +'), false, 'stale three-button claim gone');
  assert.ok(js.includes('Cancel is NEVER a button in this'), 'comment now says Cancel is the top text link');
  assert.ok(js.includes('sheet-top-cancel'), 'Cancel still renders as the top text link');
});

// ---- P2-F9: fund-form errors are inline, not toasts/dialogs ----
const topupFn = js.slice(js.indexOf("$('fundTopupForm')"), js.indexOf("$('fundAllocateForm')"));
const allocFn = js.slice(js.indexOf("$('fundAllocateForm')"), js.indexOf("$('fundRequestForm')"));
const reqFn = js.slice(js.indexOf("$('fundRequestForm')"), js.indexOf("window.addEventListener('beforeunload'"));

test('P2-F9: fund forms have inline error elements and use them', () => {
  assert.ok(html.includes('<p id="fundTopupError" class="error hidden" role="alert"></p>'), 'top-up inline error element');
  assert.ok(html.includes('<p id="fundRequestError" class="error hidden" role="alert"></p>'), 'request inline error element');
  assert.ok(html.includes('<div id="fundAllocateMsg" class="result"></div>'), 'allocate reuses its result box');
  assert.ok(topupFn.includes("setTopupError('Amount: enter a positive amount.')"), 'top-up validation is inline');
  assert.ok(topupFn.includes("setTopupError(notLive"), 'top-up save failure is inline');
  assert.ok(allocFn.includes("setAllocError('Amount: enter a positive amount.')"), 'allocate validation is inline');
  assert.ok(allocFn.includes("setAllocError('Could not record fund spending. Try again.')"), 'allocate save failure is inline');
  assert.ok(reqFn.includes("setReqError('Amount: enter a positive amount.')"), 'request validation is inline');
  assert.ok(reqFn.includes("setReqError('Could not save this request. Try again.')"), 'request save failure is inline');
});

test('P2-F9: fund forms no longer toast/dialog their field errors', () => {
  assert.equal(topupFn.includes("showToast('Enter a positive amount.', true)"), false, 'top-up no longer toasts the amount error');
  assert.equal(topupFn.includes("showToast('Check the box to confirm"), false, 'top-up no longer toasts the checkbox error');
  assert.equal(allocFn.includes("showToast('Enter a positive amount.', true)"), false, 'allocate no longer toasts the amount error');
  assert.equal(reqFn.includes("showAlert('Invalid amount'"), false, 'request no longer dialogs the amount error');
  assert.equal(reqFn.includes("showAlert('Could not save request'"), false, 'request no longer dialogs a save failure');
});

// ---- P2-F10: auth "Create Account" fits on one line at 320/360px ----
test('P2-F10: auth button rows wrap to full-width buttons at 380px and below', () => {
  const mq = css.slice(css.indexOf('@media (max-width: 380px)'));
  assert.ok(mq.length > 0, '380px media query exists');
  assert.match(css, /@media \(max-width: 380px\) \{\s*#view-auth \.auth-btn-row, #view-household \.auth-btn-row \{ flex-wrap: wrap; \}/, 'row wraps at 380px and below');
  assert.match(css, /#view-auth \.auth-btn-row \.btn, #view-household \.auth-btn-row \.btn \{ flex: 1 1 100%; \}/, 'buttons go full-width when wrapped');
  assert.ok(html.includes('>Create Account</button>'), 'label text itself is unchanged');
});

// ---- P2-F11: service worker fails loudly; cache name tracks the pin ----
test('P2-F11: service-worker cache name equals the live.js pin in live.html', () => {
  const pin = /live\.js\?v=(\d+)/.exec(html)?.[1];
  const cache = /const CACHE = 'onbudget-live-v(\d+)'/.exec(sw)?.[1];
  assert.ok(pin, 'live.js pin found in live.html');
  assert.ok(cache, 'cache version found in live-sw.js');
  assert.equal(cache, pin, 'cache name tracks the live.js pin so it cannot go stale');
});

test('P2-F11: service-worker registration failure is logged, not swallowed', () => {
  assert.ok(html.includes("console.warn('Service worker registration failed:'"), 'registration logs its failure');
  assert.equal(html.includes("navigator.serviceWorker.register('live-sw.js').catch(() => {})"), false, 'silent registration catch is gone');
  assert.ok(sw.includes("console.warn('OnBudget service worker install failed:'"), 'install logs its failure');
});

// ---- P2-F12: reset page redirects back to the app ----
test('P2-F12: reset.html redirects to live.html after a successful save', () => {
  assert.ok(reset.includes("setTimeout(() => { window.location.href = 'live.html'; }, 2000)"), '2s redirect to the app');
  assert.ok(reset.includes('Back to Sign In'), 'fallback link kept');
  assert.ok(reset.includes('Password saved. You can now sign in with it.'), 'success message kept');
});

// ---- P2-F13: five-digit amounts never wrap mid-number ----
test('P2-F13: hero/stat figures never wrap mid-number; hero shrinks at 360px', () => {
  assert.doesNotMatch(css, /\.hero \.big \{[^}]*overflow-wrap: anywhere/, 'hero figure no longer breaks mid-number');
  assert.match(css, /body\.live \.hero \.big \{ font-size: 36px; white-space: nowrap; overflow-wrap: normal; \}/, 'hero figure is no-break at 390px and below');
  assert.match(css, /@media \(max-width: 360px\) \{\s*body\.live \.hero \.big \{ font-size: 30px; \}/, 'hero figure shrinks to 30px at 360px and below');
  assert.doesNotMatch(css, /#section-stats \.num, body\.live \.stat-card \.num, body\.live \.fund-balance \{[^}]*overflow-wrap: anywhere/, 'stat figures no longer break mid-number');
});

// ---- P2-N1: Load-more edges ----
test('P2-N1a: fetch asks for one probe row past the page and tracks it', () => {
  assert.ok(js.includes('.limit(txLimit + 1)'), 'fetch asks for txLimit + 1 rows');
  assert.ok(js.includes('lastFetchedCount = txReadFailed ? 0 : (txns ?? []).length;'), 'last fetch count tracked');
  assert.ok(js.includes('const all = txReadFailed ? [] : (txns ?? []).slice(0, txLimit);'), 'shown page is exactly txLimit rows');
  assert.ok(js.includes('const hasMoreTxns = lastFetchedCount > txLimit;'), 'more-exists comes from the probe row');
  assert.ok(js.includes('if (loadMore && lastFetchedCount <= txLimit) loadMore.classList.add(\'hidden\');'), 'button hides when the probe row is missing');
  assert.ok(js.includes("if (loadMore) loadMore.classList.toggle('hidden', all.length < txLimit);"), 'original hide line kept (P0-2)');
});

test('P2-N1b: the page resets whenever the filter set changes', () => {
  assert.ok(js.includes('function resetTxLimit() { txLimit = 100; }'), 'reset helper exists');
  const calls = (js.match(/resetTxLimit\(\);/g) ?? []).length;
  assert.ok(calls >= 9, `reset is called at the filter/search change sites (found ${calls})`);
  for (const site of [
    "if (key === 'status' || key === 'month' || key === 'card' || key === 'min' || key === 'max' || key === 'week' || key === 'from' || key === 'to') resetTxLimit();",
    'resetTxLimit(); // P2-N1: applied filters are a new list.',
    'resetTxLimit(); // P2-N1: reset filters are a new list.',
    'resetTxLimit(); // P2-N1: a new month is a new list.',
    'resetTxLimit(); // P2-N1: a new card is a new list.',
    'setTimeout(() => { resetTxLimit(); refresh(); }, 250);',
  ]) assert.ok(js.includes(site), `reset site present: ${site}`);
});

// ---- P2-N2: refund-link picker normalised stem match + fallback ----
test('P2-N2: merchantStem strips punctuation and case, first word wins', () => {
  assert.equal(merchantStem('AMAZON MARKEPLACE NA PA'), 'AMAZON');
  assert.equal(merchantStem('Keren Hatzedaka!'), 'KEREN');
  assert.equal(merchantStem("McDonald's #123"), 'MCDONALD');
  assert.equal(merchantStem(''), '');
  assert.equal(merchantStem('  --  '), '');
  assert.equal(merchantStem('AMAZON MARKEPLACE NA PA'), merchantStem('Amazon Marketplace'), 'spelling variants share a stem');
});

test('P2-N2: picker uses an ilike stem match, falls back to same-card charges, keeps the server guard', () => {
  assert.equal(js.includes(".eq('merchant', row.merchant)"), false, 'exact-string merchant match is gone');
  assert.ok(js.includes(".ilike('merchant', `%${stem}%`)"), 'normalised contains match on the stem');
  assert.ok(js.includes('usedFallback'), 'same-card fallback exists');
  assert.ok(js.includes("No purchase under the same name was found, so every charge on the same card"), 'fallback is labelled honestly');
  assert.ok(js.includes("supabase.rpc('link_refund', { p_refund_id: row.id, p_purchase_id: picked })"), 'server fit check still guards the link');
});

// ---- P2-N4: manual/CSV ingestion is manual-Link-only (documented) ----
test('P2-N4: auto-link RPCs are service_role-only, so the client cannot call them', () => {
  assert.match(linkSql, /grant execute on function public\.auto_link_refund\(uuid\) to service_role;/, 'auto_link_refund is service_role-only');
  assert.match(linkSql, /grant execute on function public\.link_refunds_to_purchase\(uuid\) to service_role;/, 'link_refunds_to_purchase is service_role-only');
  assert.doesNotMatch(linkSql, /grant execute on function public\.auto_link_refund\(uuid\) to authenticated/, 'no authenticated grant on auto_link_refund');
  assert.doesNotMatch(linkSql, /grant execute on function public\.link_refunds_to_purchase\(uuid\) to authenticated/, 'no authenticated grant on link_refunds_to_purchase');
  assert.match(linkSql, /grant execute on function public\.link_refund\(uuid, uuid\) to authenticated;/, 'manual link_refund IS client-callable');
});

test('P2-N4: both insert sites document manual-Link-only and never call the auto-linkers', () => {
  assert.equal(js.includes("supabase.rpc('auto_link_refund'"), false, 'client never calls auto_link_refund');
  assert.equal(js.includes("supabase.rpc('link_refunds_to_purchase'"), false, 'client never calls link_refunds_to_purchase');
  assert.equal((js.match(/P2-N4/g) ?? []).length, 2, 'both insert sites carry the P2-N4 note');
  assert.ok(js.includes('Actions → Link to purchase'), 'manual path is named at the insert sites');
});

// ---- P2-C4: unlinked_excess_cents is displayed ----
test('P2-C4: compute-week unlinked excess is stored and shown in the Weekly Budget sheet', () => {
  assert.ok(js.includes('unlinkedExcessCents: r.unlinked_excess_cents ?? 0,'), 'field stored on currentWeekData');
  assert.ok(js.includes("weeklyRows.push(['Unlinked refunds', formatCents(unlinkedExcess)])"), 'fourth row only when the excess is non-zero');
  assert.ok(js.includes("Unlinked refunds above this week\\'s spending are not counted here."), 'sheet message explains the figure');
  assert.ok(js.includes("'Pending transactions are included and marked.'"), 'zero-excess sheet message unchanged');
});

// ---- NEW-P2-1 (R4, Nov 9, 2026): clearWeekNumbers writes N/A for Purchases ----
// The hero's initial value is N/A (live.html:124) and the normal failure
// path writes N/A (live.js:848); the clear-week fallback must agree, or
// a refresh that aborts before :848 leaves a bare dash in Purchases.
test('NEW-P2-1: clearWeekNumbers writes N/A for heroPurchaseCount, dash for the rest', () => {
  const fn = js.slice(js.indexOf('const clearWeekNumbers'), js.indexOf('const loadWeekNumbers'));
  assert.ok(fn.length > 0, 'clearWeekNumbers found');
  assert.ok(fn.includes("id === 'heroPurchaseCount' ? 'N/A' : '—'"), 'Purchases gets N/A on compute-week failure');
  assert.ok(fn.includes("'heroPurchaseCount'"), 'heroPurchaseCount is still cleared with the rest');
});

// ---- NEW-P2-2 (R4, Nov 9, 2026): chip removal resets the page for ALL keys ----
test('NEW-P2-2: removing any of the seven filter chips resets txLimit', () => {
  const line = "if (key === 'status' || key === 'month' || key === 'card' || key === 'min' || key === 'max' || key === 'week' || key === 'from' || key === 'to') resetTxLimit();";
  assert.ok(js.includes(line), 'all seven chip keys reset the page');
  assert.equal(js.includes("if (key === 'status' || key === 'month' || key === 'card') resetTxLimit();"), false, 'old three-key condition is gone');
});

// ---- NEW-P2-3 (R4, Nov 9, 2026): stale-sync footer names where Sync lives ----
// Chosen fix: reword, not per-view hiding — the footer is global and the
// warning is computed in refresh() without view state, so hiding it on
// Transactions would couple the global footer to view routing. The copy
// now names the two places that have a Sync button (Home hero, Bank & Funds).
test('NEW-P2-3: stale-sync footer names where Sync lives', () => {
  assert.ok(html.includes("Scheduled sync hasn't run in a while — tap Sync on Home or Bank &amp; Funds to check now."), 'footer names Home and Bank & Funds');
  assert.equal(html.includes('tap Sync to check now.'), false, 'old copy pointing at a Sync button that is not on every page is gone');
  assert.ok(html.includes('id="syncStaleWarn"'), 'warning element itself is unchanged');
});

// ---- NEW-P2-4 (R4, Nov 9, 2026): SW comment cites the current pin ----
// The live.js pin moved v63 -> v64 in this batch, so the comment now says
// (v64) to match the bumped cache name.
test('NEW-P2-4: service-worker comment cites the current cache version', () => {
  const cache = /const CACHE = 'onbudget-live-v(\d+)'/.exec(sw)?.[1];
  assert.ok(cache, 'cache version found');
  assert.ok(sw.includes(`(${`v${cache}`})`), 'comment cites the same version as CACHE');
  assert.equal(sw.includes('(v62)'), false, 'stale v62 comment is gone');
  assert.equal(sw.includes('(v63)'), false, 'stale v63 comment is gone');
});

// ---- NEW-P2-5 (R4, Nov 9, 2026): showSheet actions branch deleted ----
// Decision: DELETE, not documented dead code. Zero of the 16 showSheet call
// sites passes actions; the Task 7 sheet actions it served are now the
// expand-in-place buttons. Deleting removes a second button-row path that
// could silently reappear; git history keeps the code if it is ever needed.
test('NEW-P2-5: showSheet actions param/branch is deleted', () => {
  assert.equal(js.includes('actions = null'), false, 'actions param is gone from the signature');
  assert.equal(js.includes('actionsHtml'), false, 'actions rendering is gone');
  assert.equal(js.includes('data-sheet-action'), false, 'actions click wiring is gone');
  assert.equal(js.includes("actions ? ' btn-quiet'"), false, 'actions confirm-button branch is gone');
  assert.ok(js.includes('function showSheet({'), 'showSheet itself still exists');
  assert.ok(js.includes('extraAction'), 'the live extra-action path is untouched');
  // The count is not pinned: later call sites (e.g. the C2 household
  // picker) legitimately add more. The invariant is that no call site
  // passes `actions:` — the deleted param has no callers to resurrect.
  assert.equal((js.match(/showSheet\(\{[^}]*actions:/g) ?? []).length, 0, 'no call site passes actions');
});

// ---- NEW-P2-6 (R4, Nov 9, 2026): SW cache-write failure is logged ----
test('NEW-P2-6: service-worker cache-write failure logs instead of swallowing', () => {
  assert.ok(sw.includes("console.warn('OnBudget service worker cache write failed:'"), 'cache-write failure is logged like the install catch');
  assert.equal(sw.includes('.catch(() => {})'), false, 'no silent empty catch remains in the service worker');
});

// ---- NEW-P2-7 (R4, Nov 9, 2026): button labels are Title Case platform-wide ----
// Owner delegated the call Nov 9 ("whatever you chose"): Title Case for
// all button labels, the same rule already standing for headlines/headers.
// The five sentence-case labels found by R4 are fixed here; the rule is
// pinned so a new sentence-case button cannot drift back in.
test('NEW-P2-7: button labels are Title Case (owner-delegated Nov 9)', () => {
  for (const label of ['Add Transaction', 'Save Name', 'Save Email', 'Check Email Now', 'Apply Filter']) {
    assert.ok(html.includes(`>${label}<`), `button label is Title Case: ${label}`);
  }
  for (const old of ['>Add transaction<', '>Save name<', '>Save email<', '>Check email now<', '>Apply filter<']) {
    assert.equal(html.includes(old), false, `no sentence-case button label remains: ${old}`);
  }
  assert.match(html, /aria-label="Add Transaction"/);
  assert.match(html, /aria-label="Check Email Now"/);
});
