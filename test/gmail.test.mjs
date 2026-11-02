// Gmail OAuth path tests — run with:
//   node --test test/gmail.test.mjs
// Pure helpers only (no network, no database, no Google calls). The
// helpers live in supabase/functions/_shared/gmail-parse.ts and are
// imported directly (Node type-strips .ts); gmail-poll ships identical
// alongside copies, so the tested code IS the deployed code.
// Spec: FINAL — email alerts are PROVISIONAL only, Plaid authoritative;
// cash-back is NOT a refund, card payments are NOT refunds. The email
// path ingests Large Purchase alerts (positive charges) only; refunds
// via email are out of scope by design (see gmail-parse.ts header).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  authResultsPass,
  buildAlertQuery,
  extractPlainText,
  filterNewMessageIds,
  gmailDateToNY,
  headerValue,
  htmlToText,
  parseAmexAlertText,
} from '../supabase/functions/_shared/gmail-parse.ts';

// --- Authentication-Results (exact ingest rule) -------------------------

test('auth-results: dkim+spf pass for americanexpress.com passes', () => {
  assert.equal(
    authResultsPass('mx.google.com; spf=pass (google.com: domain of bounce@americanexpress.com) smtp.mailfrom=americanexpress.com; dkim=pass header.i=@americanexpress.com'),
    true,
  );
});

test('auth-results: dkim fail quarantines', () => {
  assert.equal(
    authResultsPass('mx.google.com; spf=pass smtp.mailfrom=americanexpress.com; dkim=fail header.i=@americanexpress.com'),
    false,
  );
});

test('auth-results: spf missing quarantines (FLAGGED: both required)', () => {
  assert.equal(
    authResultsPass('mx.google.com; dkim=pass header.i=@americanexpress.com'),
    false,
  );
});

test('auth-results: wrong domain quarantines', () => {
  assert.equal(
    authResultsPass('mx.google.com; spf=pass smtp.mailfrom=evil.example; dkim=pass header.i=@evil.example'),
    false,
  );
});

test('auth-results: empty quarantines; matching is case-insensitive', () => {
  assert.equal(authResultsPass(''), false);
  assert.equal(
    authResultsPass('MX.GOOGLE.COM; SPF=PASS; DKIM=PASS HEADER.I=@AMERICANEXPRESS.COM'),
    true,
  );
});

// --- Alert parsing (mirror of the Apps Script parser) --------------------

test('parse: body amount + "at MERCHANT" + card suffix', () => {
  const out = parseAmexAlertText({
    subject: 'Large Purchase Alert',
    body: 'You made a purchase of $48.25 at Amazon\non your card ending in 1005.',
    date: '2026-10-28',
  });
  assert.deepEqual(out, { amountCents: 4825, merchant: 'Amazon', cardSuffix: '1005', date: '2026-10-28' });
});

test('parse: comma amount, bullet suffix', () => {
  const out = parseAmexAlertText({
    subject: 'Large Purchase Alert',
    body: 'A purchase of $1,234.56 at Costco\nwas made on your card •3450.',
    date: '2026-10-29',
  });
  assert.deepEqual(out, { amountCents: 123456, merchant: 'Costco', cardSuffix: '3450', date: '2026-10-29' });
});

test('parse: subject-tail merchant fallback when no "at" phrasing', () => {
  const out = parseAmexAlertText({
    subject: 'Large Purchase Alert: Whole Foods Market',
    body: 'Your purchase of $12.00 was approved.',
    date: '2026-10-30',
  });
  assert.deepEqual(out, { amountCents: 1200, merchant: 'Whole Foods Market', cardSuffix: '0000', date: '2026-10-30' });
});

test('parse: real Large Purchase Approved format (merchant cell, threshold prose)', () => {
  const out = parseAmexAlertText({
    subject: 'Large Purchase Approved',
    body: 'YEHOSHUA FRIEDMAN Account Ending: 01005 There was a large purchase on your Additional Card Dear YEHOSHUA FRIEDMAN, As you requested, we\'re letting you know that this purchase on your Additional Card ending 101013 was more than $1.00. You can change the dollar amount of these large purchase notifications online. AMAZON MARKEPLACE NA PA $10.59* Mon, Nov 2, 2026',
    date: '2026-11-02',
  });
  assert.deepEqual(out, { amountCents: 1059, merchant: 'AMAZON MARKEPLACE NA PA', cardSuffix: '1005', date: '2026-11-02' });
});

test('parse: cell merchant beats "at americanexpress.com" footer prose; "Ending :" suffix', () => {
  const out = parseAmexAlertText({
    subject: 'Large Purchase Approved',
    body: 'YEHOSHUA FRIEDMAN Account Ending : 01005 There was a large purchase. Visit us at americanexpress.com for details. AMAZON MARKEPLACE NA PA $10.59* Mon, Nov 2, 2026',
    date: '2026-11-02',
  });
  assert.deepEqual(out, { amountCents: 1059, merchant: 'AMAZON MARKEPLACE NA PA', cardSuffix: '1005', date: '2026-11-02' });
});

test('parse: null when no amount, zero amount, no merchant, or bad date', () => {
  assert.equal(parseAmexAlertText({ subject: 'Large Purchase Alert', body: 'at Amazon', date: '2026-10-28' }), null);
  assert.equal(parseAmexAlertText({ subject: 'Large Purchase Alert', body: '$0.00 at Amazon', date: '2026-10-28' }), null);
  assert.equal(parseAmexAlertText({ subject: 'Large Purchase Alert', body: 'A purchase of $9.99 was made.', date: '2026-10-28' }), null);
  assert.equal(parseAmexAlertText({ subject: 'Large Purchase Alert', body: '$9.99 at Amazon', date: '10/28/2026' }), null);
});

// --- Gmail payload helpers ------------------------------------------------

const b64url = (s) => Buffer.from(s, 'utf8').toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

test('extractPlainText: single part, multipart prefers text/plain, nested parts', () => {
  assert.equal(extractPlainText({ body: { data: b64url('hello plain') } }), 'hello plain');
  assert.equal(
    extractPlainText({
      mimeType: 'multipart/alternative',
      parts: [
        { mimeType: 'text/plain', body: { data: b64url('plain wins') } },
        { mimeType: 'text/html', body: { data: b64url('<b>html loses</b>') } },
      ],
    }),
    'plain wins',
  );
  assert.equal(
    extractPlainText({
      mimeType: 'multipart/mixed',
      parts: [{ mimeType: 'multipart/alternative', parts: [{ mimeType: 'text/plain', body: { data: b64url('nested works') } }] }],
    }),
    'nested works',
  );
  assert.equal(extractPlainText(null), '');
  assert.equal(extractPlainText({}), '');
});

test('htmlToText: drops style/script blocks, keeps cells separated, decodes entities', () => {
  assert.equal(
    htmlToText('<style>.x{content:"$999.99"}</style><script>var a="$888.88";</script><table><tr><td>AMAZON MARKEPLACE NA PA</td><td>$10.59*</td></tr></table><p>Fish &amp; Chips &#36;5.00</p>'),
    'AMAZON MARKEPLACE NA PA $10.59* Fish & Chips $5.00',
  );
});

test('extractPlainText: HTML-only Amex alert converts to a parseable alert', () => {
  const html = '<html><head><style>.pad{padding:0} .price{content:"$999.99"}</style></head><body>'
    + '<p>YEHOSHUA FRIEDMAN Account Ending: 01005</p>'
    + '<p>There was a large purchase on your Additional Card. As you requested, we\'re letting you know that this purchase on your Additional Card ending 101013 was more than $1.00.</p>'
    + '<table><tr><td><p>AMAZON MARKEPLACE NA PA</p></td></tr><tr><td><p>$10.59*</p></td></tr><tr><td><p>Mon, Nov 2, 2026</p></td></tr></table>'
    + '</body></html>';
  const text = extractPlainText({ mimeType: 'text/html', body: { data: b64url(html) } });
  assert.equal(text.includes('$999.99'), false);
  assert.deepEqual(parseAmexAlertText({ subject: 'Large Purchase Approved', body: text, date: '2026-11-02' }), { amountCents: 1059, merchant: 'AMAZON MARKEPLACE NA PA', cardSuffix: '1005', date: '2026-11-02' });
});

// --- N12 drift guard ------------------------------------------------------
// The poll imports gmail-poll/gmail-parse.ts; the tests import the
// _shared copy. The two files drifted before (query comment, then
// parser fixes applied to both by hand), so this test extracts each
// named function from both files and requires them identical.
// Extraction slices from the function's declaration to the next
// top-level `export function` — robust against braces and quotes
// inside regexes, which brace-counting would miscount.
test('parse copies stay identical: gmail-poll vs _shared (N12)', () => {
  const read = (p) => fs.readFileSync(new URL(p, import.meta.url), 'utf8');
  const poll = read('../supabase/functions/gmail-poll/gmail-parse.ts');
  const shared = read('../supabase/functions/_shared/gmail-parse.ts');
  const extract = (source, name) => {
    const start = source.indexOf(`export function ${name}`);
    assert.notEqual(start, -1, `${name} missing from a parse copy`);
    let end = source.indexOf('\nexport function ', start + 1);
    if (end === -1) end = source.length;
    const body = source.slice(start, end).trimEnd();
    assert.ok(body.length > 100, `${name} extraction too short to trust`);
    return body;
  };
  for (const name of ['parseAmexAlertText', 'extractPlainText', 'htmlToText']) {
    assert.equal(extract(poll, name), extract(shared, name), `${name} drifted between parse copies`);
  }
});

test('headerValue: case-insensitive lookup, missing header is empty', () => {
  const headers = [
    { name: 'Subject', value: 'Large Purchase Alert' },
    { name: 'Authentication-Results', value: 'dkim=pass' },
  ];
  assert.equal(headerValue(headers, 'subject'), 'Large Purchase Alert');
  assert.equal(headerValue(headers, 'AUTHENTICATION-RESULTS'), 'dkim=pass');
  assert.equal(headerValue(headers, 'From'), '');
  assert.equal(headerValue(null, 'Subject'), '');
});

test('gmailDateToNY: UTC midnight boundary flips the NY date', () => {
  // 2026-11-01T04:00Z == 2026-11-01 00:00 EDT (DST still on).
  assert.equal(gmailDateToNY(Date.parse('2026-11-01T04:00:00Z')), '2026-11-01');
  // 2026-11-01T03:00Z == 2026-10-31 23:00 EDT.
  assert.equal(gmailDateToNY(Date.parse('2026-11-01T03:00:00Z')), '2026-10-31');
  assert.equal(gmailDateToNY('not-a-date'), '');
});

test('filterNewMessageIds: drops already-processed ids only', () => {
  assert.deepEqual(filterNewMessageIds(['a', 'b', 'c'], ['b']), ['a', 'c']);
  assert.deepEqual(filterNewMessageIds(['a'], []), ['a']);
  assert.deepEqual(filterNewMessageIds([], ['a']), []);
});

test('buildAlertQuery: Amex Large Purchase alerts only, no label logic', () => {
  assert.equal(buildAlertQuery(), 'from:(americanexpress.com) subject:"Large Purchase"');
});
