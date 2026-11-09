// Refund Links section + better merging + published privacy/terms —
// run with: node --test test/refund-link-merge-ui.test.mjs
// Spec: Nov 9, 2026. Refund-link suggestions live in the Review
// area next to Possible Duplicates; merging shows why a pair was
// flagged, pages past the first 20, and lets a Separate be
// reopened; privacy.html + terms.html are published on the site
// and linked from the app footer and the landing pages.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const js = read('../live.js');
const html = read('../live.html');
const indexHtml = read('../index.html');
const landingHtml = read('../landing.html');
const privacyHtml = read('../privacy.html');
const termsHtml = read('../terms.html');
const dismissSql = read('../supabase/refund-link-dismissals.sql');
const reopenSql = read('../supabase/dedupe-reopen.sql');

// --- Review area structure -------------------------------------------

test('review area: Refund Links section sits below Possible Duplicates, Resolved below that', () => {
  const reviewCard = html.slice(html.indexOf('id="section-fund-review-more"'));
  const dup = reviewCard.indexOf('Possible Duplicates');
  const res = reviewCard.indexOf('Resolved Duplicates');
  const ref = reviewCard.indexOf('Refund Links');
  assert.ok(dup > 0 && res > dup && ref > res, 'order: Possible Duplicates, Resolved Duplicates, Refund Links');
  assert.ok(reviewCard.includes('id="dedupeList"'), 'dedupeList container exists');
  assert.ok(reviewCard.includes('id="dedupeResolvedList"'), 'dedupeResolvedList container exists');
  assert.ok(reviewCard.includes('id="refundLinkList"'), 'refundLinkList container exists');
});

// --- Refund Links wiring ----------------------------------------------

test('refund links: live.js imports the suggestion module and renders the section', () => {
  assert.ok(js.includes("from './refundSuggestions.mjs'"), 'refundSuggestions.mjs is imported');
  assert.ok(js.includes('computeRefundSuggestions'), 'suggestions are computed');
  assert.ok(js.includes("from('transactions')") && js.includes(".eq('kind', 'refund').is('original_purchase_id', null)"), 'unlinked refunds are read');
  assert.ok(js.includes("$('refundLinkList')"), 'refundLinkList is rendered');
  assert.ok(js.includes('No unlinked refunds.'), 'empty state exists');
  assert.ok(js.includes('No refund links to suggest.'), 'no-suggestion state exists');
  assert.ok(js.includes('reviewNeedsCount += suggestions.length'), 'suggestions count toward the Review badge');
});

test('refund links: Link calls link_refund, Dismiss calls the dismiss RPC', () => {
  assert.ok(js.includes("supabase.rpc('link_refund', { p_refund_id: s.refund.id, p_purchase_id: s.purchase.id })"), 'Link calls link_refund with both ids');
  assert.ok(js.includes("supabase.rpc('dismiss_refund_link_suggestion', { p_refund_id: s.refund.id, p_purchase_id: s.purchase.id })"), 'Dismiss calls the dismiss RPC');
  assert.ok(js.includes("audit('Refund linked'"), 'linking writes an audit row');
  assert.ok(js.includes("showToast('Refund linked to its purchase.')"), 'linking toasts');
  assert.ok(js.includes('REFUND_SUGGESTION_REASONS[s.reason]'), 'the suggestion reason is shown on the card');
  assert.ok(js.includes("from('refund_link_dismissals')"), 'dismissals are read so dismissed pairs stay hidden');
});

test('refund links: dismissals table + RPC are admin-only and never link or delete', () => {
  assert.ok(dismissSql.includes('create table if not exists refund_link_dismissals'), 'dismissals table exists');
  assert.ok(dismissSql.includes('unique (refund_id, purchase_id)'), 'a pair is dismissed once');
  assert.ok(dismissSql.includes('enable row level security'), 'RLS is on');
  assert.ok(dismissSql.includes("members read own refund link dismissals"), 'member-read policy exists');
  assert.ok(dismissSql.includes('dismiss_refund_link_suggestion'), 'dismiss RPC exists');
  assert.ok(dismissSql.includes("role = 'admin'"), 'dismiss RPC is admin-only');
  assert.ok(dismissSql.includes('security definer'), 'dismiss RPC is security definer');
  assert.ok(dismissSql.includes('on conflict (refund_id, purchase_id) do nothing'), 'repeat dismiss is a no-op');
  assert.ok(dismissSql.includes('Refund link suggestion dismissed'), 'dismissal writes an audit row');
  assert.equal(dismissSql.includes('delete from transactions'), false, 'dismissing deletes nothing');
});

// --- Better merging ----------------------------------------------------

test('merging: the flag reason is shown on each duplicate card', () => {
  assert.ok(js.includes('Flagged as a lookalike'), 'why-flagged line exists');
  assert.ok(js.includes('c.merchant_a') && js.includes('c.merchant_b'), 'the related merchant names are shown');
  assert.ok(js.includes('merchant names look related'), 'the line names the evidence');
});

test('merging: Possible Duplicates pages past the first 20 with Show More', () => {
  assert.ok(js.includes('dedupeShownCount'), 'dedupe paging state exists');
  assert.ok(js.includes('slice(0, dedupeShownCount)'), 'the shown slice follows the paging state');
  assert.ok(js.includes('dedupeShownCount += 20'), 'Show More raises the dedupe page');
  assert.ok(js.includes('refundLinkShownCount += 20'), 'Show More raises the refund-link page too');
});

test('merging: resolved pairs list with Reopen for Separate, none for merged', () => {
  assert.ok(js.includes("$('dedupeResolvedList')"), 'resolved list is rendered');
  assert.ok(js.includes("supabase.rpc('reopen_duplicate_candidate', { p_candidate_id: r.id })"), 'Reopen calls the reopen RPC');
  assert.ok(js.includes('the duplicate can be restored from Trash'), 'merged rows point at Trash restore, not reopen');
  assert.ok(reopenSql.includes('reopen_duplicate_candidate'), 'reopen RPC exists');
  assert.ok(reopenSql.includes("role = 'admin'"), 'reopen RPC is admin-only');
  assert.ok(reopenSql.includes('security definer'), 'reopen RPC is security definer');
  assert.ok(reopenSql.includes("status = 'pending'"), 'reopen moves the candidate back to pending');
  assert.ok(reopenSql.includes('a merged pair is undone from Trash'), 'reopen refuses merged candidates');
  assert.ok(reopenSql.includes('already pending'), 'reopen refuses pending candidates');
  assert.ok(reopenSql.includes('Duplicate review reopened'), 'reopen writes an audit row');
});

// --- Published privacy & terms ------------------------------------------

test('privacy + terms: pages exist, carry the draft note, and keep the drafts’ content', () => {
  assert.ok(existsSync(new URL('../privacy.html', import.meta.url)), 'privacy.html exists at the site root');
  assert.ok(existsSync(new URL('../terms.html', import.meta.url)), 'terms.html exists at the site root');
  assert.ok(privacyHtml.includes('A lawyer review is still owed before launch'), 'privacy page says lawyer review is owed');
  assert.ok(termsHtml.includes('A lawyer review is still owed before launch'), 'terms page says lawyer review is owed');
  assert.ok(privacyHtml.includes('We do not sell your data'), 'privacy keeps the no-sale promise');
  assert.ok(privacyHtml.includes('American Express Large Purchase alert emails'), 'privacy keeps the Gmail scope');
  assert.ok(termsHtml.includes('provided "as is."'), 'terms keep the as-is clause');
  assert.ok(termsHtml.includes('not a bank, not a financial advisor'), 'terms keep the not-a-bank line');
  assert.ok(privacyHtml.includes('href="terms.html"'), 'privacy links to terms');
  assert.ok(termsHtml.includes('href="privacy.html"'), 'terms link to privacy');
});

test('privacy + terms: linked from the sign-in footer, Settings, and both landing pages', () => {
  // The live footer stays the last-sync line only (Task 6 pins it),
  // so the links live under the sign-in card (auth-foot, both auth
  // views) and in Settings, where a signed-in user can find them.
  assert.equal((html.match(/<a href="privacy\.html">Privacy<\/a>/g) ?? []).length, 3, 'Privacy linked from both auth-foots and Settings');
  assert.equal((html.match(/<a href="terms\.html">Terms<\/a>/g) ?? []).length, 3, 'Terms linked from both auth-foots and Settings');
  assert.ok(html.includes('class="auth-foot"'), 'auth-foot exists');
  assert.ok(indexHtml.includes('<a href="privacy.html">Privacy</a>'), 'landing page links Privacy');
  assert.ok(indexHtml.includes('<a href="terms.html">Terms</a>'), 'landing page links Terms');
  assert.ok(landingHtml.includes('<a href="privacy.html">Privacy</a>'), 'landing.html links Privacy');
  assert.ok(landingHtml.includes('<a href="terms.html">Terms</a>'), 'landing.html links Terms');
});

// --- Pins -----------------------------------------------------------------

test('pins: live.js v67 / styles v53, service-worker cache tracks live.js', () => {
  assert.ok(html.includes('live.js?v=67'), 'live.html pins live.js v67');
  assert.ok(html.includes('styles.css?v=53'), 'live.html pins styles v53');
  const sw = read('../live-sw.js');
  assert.ok(sw.includes("CACHE = 'onbudget-live-v67'"), 'service-worker cache tracks the live.js pin');
  assert.ok(sw.includes('(v67)'), 'service-worker comment names the current pin');
});
