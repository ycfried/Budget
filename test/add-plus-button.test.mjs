// Add-plus-button (owner design Nov 3, 9:49 PM): the Transactions
// header has one blue + button; tapping it opens an options popup —
// Purchase / Donation / Upload for admins, Purchase only for
// members. Choosing an option moves that form's existing section
// into the popup; Back returns to the options, Cancel/submit
// returns to the list. Static tests only — no live data, no network,
// no money math, no form-logic change.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

test('Transactions header has one blue + button, the only Add entry point', () => {
  assert.match(html, /id="txAddBtn"[^>]*aria-label="Add">\+</);
  assert.ok(html.includes('class="btn btn-primary add-plus-btn" id="txAddBtn"'));
  assert.match(css, /body\.live \.add-plus-btn \{[^}]*width: 44px;[^}]*height: 44px;/);
  // The old inline choice card and its buttons are gone — no second way in.
  assert.equal(html.includes('section-add-choice'), false);
  assert.equal(html.includes('addManualBtn'), false);
  assert.equal(html.includes('addCsvBtn'), false);
  assert.equal(html.includes('addCharityBtn'), false);
  assert.equal(js.includes("setAddForm('choice')"), false);
});

test('options popup lists Purchase, Donation, Upload with plain sub-lines', () => {
  assert.match(html, /id="addPopupOverlay"[^>]*role="dialog" aria-modal="true" aria-label="Add"/);
  assert.match(html, /id="addOptionsCard"/);
  assert.match(html, /id="addOptionPurchaseBtn"[^>]*>.*Purchase.*Add a transaction by hand/s);
  assert.match(html, /id="addOptionDonationBtn"[^>]*>.*Donation.*Record a gift by hand/s);
  assert.match(html, /id="addOptionUploadBtn"[^>]*>.*Upload.*Import transactions from a file/s);
  assert.equal((html.match(/id="addOption(?:Purchase|Donation|Upload)Btn"/g) ?? []).length, 3, 'exactly three options in the popup');
});

test('each option opens its existing form in the popup; Back returns to options', () => {
  assert.match(js, /\$\('addOptionPurchaseBtn'\)\?\.addEventListener\('click', \(\) => setAddForm\('manual'\)\);/);
  assert.match(js, /\$\('addOptionDonationBtn'\)\?\.addEventListener\('click', \(\) => setAddForm\('charity'\)\);/);
  assert.match(js, /\$\('addOptionUploadBtn'\)\?\.addEventListener\('click', \(\) => setAddForm\('csv'\)\);/);
  // Forms are moved, not rewritten: the popup slot receives the section.
  assert.match(js, /ADD_FORM_SECTIONS = \{ manual: 'section-manual', csv: 'section-csv', charity: 'section-charity-gift' \}/);
  assert.match(js, /slot\.appendChild\(el\)/);
  assert.match(js, /\$\('manualBackBtn'\)\?\.addEventListener\('click', \(\) => setAddForm\('options'\)\);/);
  assert.match(js, /\$\('csvBackBtn'\)\?\.addEventListener\('click', \(\) => setAddForm\('options'\)\);/);
  assert.match(js, /charityBackBtn.*setAddForm\('options'\)/);
});

test('Cancel and successful submits return to the list', () => {
  assert.match(js, /manualCancelBtn.*setAddForm\(null\)/s);
  assert.match(js, /addOptionsCloseBtn.*setAddForm\(null\)/s);
  // Gift already closed on success; manual and CSV now do the same.
  assert.match(js, /f\.reset\(\); setAddForm\(null\); done\(\); await refresh\(\);/);
  assert.match(js, /setAddForm\(null\);\s*await refresh\(\);/);
});

test('members see Purchase only; donation and upload are gated', () => {
  // Options list itself: donation and upload hidden unless admin.
  assert.match(js, /addOptionDonationBtn.*isAdmin \? '' : 'none'/s);
  assert.match(js, /addOptionUploadBtn.*isAdmin \? '' : 'none'/s);
  // Entry-point gate: a member reaching a gated form is sent to options.
  assert.match(js, /if \(\(which === 'charity' \|\| which === 'csv'\) && !\(household && household\.role === 'admin'\)\) which = 'options';/);
  // Defense in depth: the CSV confirm path refuses members before inserting.
  assert.match(js, /Only the admin can import transactions\./);
});

test('popup has Escape-to-close and a Tab trap that stands aside for other sheets', () => {
  assert.match(js, /addPopupOverlay/);
  assert.match(js, /if \(e\.key === 'Escape'\) \{ e\.preventDefault\(\); if \(addFormOpen === 'options'\) setAddForm\(null\); else setAddForm\('options'\); return; \}/);
  assert.match(js, /if \(document\.getElementById\('sheetOverlay'\)\) return;/);
  assert.match(css, /body\.live \.add-popup-overlay \{[^}]*position: fixed;/);
});

test('new popup ids are unique in the page', () => {
  for (const id of ['addPopupOverlay', 'addPopupFormSlot', 'addOptionsCard', 'addOptionPurchaseBtn', 'addOptionDonationBtn', 'addOptionUploadBtn', 'addOptionsCloseBtn']) {
    assert.equal((html.match(new RegExp(`id="${id}"`, 'g')) ?? []).length, 1, `${id} appears exactly once`);
  }
});
