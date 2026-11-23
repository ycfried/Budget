// F-15 Chase scaffold tests (build 64, Nov 23, 2026) — run with:
//   node --test supabase/tests/gmail-chase-scaffold.test.mjs
// These tests pin GUARDRAILS ONLY. They do NOT prove the Chase
// parser understands real Chase mail — no real Chase alert sample
// exists in the repo, and the parser's patterns are best-guess
// shapes. The proof step is a real redacted Chase alert run
// against parseChaseAlertText by hand (see the "UNPROVEN" note at
// the bottom); only after that may CHASE_ALERTS_ENABLED flip to
// true in supabase/functions/gmail-poll/index.ts. A passing suite
// here must never be reported as "Chase ingestion works".

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  authResultsPassFor,
  buildAlertQuery,
  buildChaseAlertQuery,
  EMAIL_PARSERS,
  parseChaseAlertText,
  parseEmailAlert,
} from '../functions/_shared/gmail-parse.ts';

test('F-15: Chase query filters on the Chase sender domains only', () => {
  const q = buildChaseAlertQuery();
  assert.match(q, /chase\.com/);
  assert.match(q, /jpmorganchase\.com/);
  // No guessed subject phrase: Chase alert subjects are unknown.
  assert.doesNotMatch(q, /subject:/i);
  // The Amex query is unchanged by the Chase work.
  assert.equal(buildAlertQuery(), 'from:(americanexpress.com) subject:"Large Purchase"');
});

test('F-15: Chase auth rule requires a Chase domain + dkim + spf', () => {
  assert.equal(authResultsPassFor('chase_alert',
    'mx.google.com; spf=pass smtp.mailfrom=chase.com; dkim=pass header.i=@chase.com'), true);
  assert.equal(authResultsPassFor('chase_alert',
    'mx.google.com; spf=pass smtp.mailfrom=jpmorganchase.com; dkim=pass header.i=@jpmorganchase.com'), true);
  // An Amex-authenticated message must NOT pass as Chase.
  assert.equal(authResultsPassFor('chase_alert',
    'mx.google.com; spf=pass smtp.mailfrom=americanexpress.com; dkim=pass header.i=@americanexpress.com'), false);
  // Chase domain but a failing DKIM must NOT pass (fail-closed).
  assert.equal(authResultsPassFor('chase_alert',
    'mx.google.com; spf=pass smtp.mailfrom=chase.com; dkim=fail header.i=@chase.com'), false);
  // Unknown source never passes.
  assert.equal(authResultsPassFor('capital_one_alert',
    'mx.google.com; spf=pass smtp.mailfrom=capitalone.com; dkim=pass header.i=@capitalone.com'), false);
});

test('F-15: Chase parser is fail-closed — null without amount, merchant, or Chase marker', () => {
  const base = { subject: 'Chase alert', body: 'You made a purchase of $48.25 with Amazon on your card ending in 1005.', date: '2026-11-20' };
  assert.deepEqual(parseChaseAlertText(base),
    { amountCents: 4825, merchant: 'Amazon on your card ending in 1005', cardSuffix: '1005', date: '2026-11-20' });
  assert.equal(parseChaseAlertText({ ...base, body: 'You made a purchase with Amazon.' }), null);
  assert.equal(parseChaseAlertText({ ...base, body: 'You made a purchase of $48.25.' }), null);
  assert.equal(parseChaseAlertText({ subject: 'Alert', body: 'You made a purchase of $48.25 with Amazon.', date: '2026-11-20' }), null);
  assert.equal(parseChaseAlertText({ ...base, date: 'Nov 20, 2026' }), null);
  // Amex-shaped mail never parses as Chase.
  assert.equal(parseEmailAlert('chase_alert', { subject: 'Large Purchase Alert', body: 'You made a purchase of $48.25 at Amazon\non your card ending in 1005.', date: '2026-10-28' }), null);
  assert.equal(EMAIL_PARSERS.chase_alert, parseChaseAlertText);
});

test('F-15: the Chase path is DISABLED in gmail-poll until a real alert is verified', () => {
  const poll = readFileSync(
    new URL('../functions/gmail-poll/index.ts', import.meta.url), 'utf8');
  assert.match(poll, /const CHASE_ALERTS_ENABLED = false;/);
  assert.match(poll, /isChase && !CHASE_ALERTS_ENABLED/);
  // The insert stores the dispatched source, not a hardcoded Amex one.
  assert.match(poll, /source,\n\s+state: 'provisional',/);
  // The dedupe-hash guard still applies to Chase rows (same code path).
  assert.match(poll, /findExistingSameHash\(supabaseAdmin, householdId, dedupeHash\)/);
});

test('F-15: UNPROVEN — what still needs a real Chase alert (documentation, not a code check)', () => {
  // This test passes by construction; it exists so the suite itself
  // says what it does NOT prove. Before flipping
  // CHASE_ALERTS_ENABLED to true, the owner (or a tester with a
  // Chase account) must supply ONE real redacted Chase transaction
  // alert and check, by hand, that parseChaseAlertText returns the
  // right amount, merchant, and card suffix — and that the alert's
  // subject/body actually match buildChaseAlertQuery's sender
  // filter. The scaffold's "with/at NAME" merchant patterns and
  // "ending in NNNN" suffix pattern are guesses; a real alert may
  // use different phrasing ("at", "to", a card nickname, no suffix
  // at all). Until then, Chase ingestion is NOT working — only wired.
  assert.ok(true);
});
