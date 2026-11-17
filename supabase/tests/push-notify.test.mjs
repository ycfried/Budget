// Push-notify tests (Nov 16, 2026) — run with:
//   node --test supabase/tests/push-notify.test.mjs
// Pure helpers from supabase/functions/push-notify/apns.ts,
// imported directly (Node type-strips .ts); the tested code IS the
// deployed code. The JWT test generates its own P-256 key — no real
// key is ever committed.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  base64urlDecodeToBytes,
  base64urlEncode,
  buildCopy,
  clearApnsJwtCache,
  currentWeekStartNY,
  dedupeKey,
  dedupePrefixForKind,
  formatMoney,
  formatMonthLabel,
  formatWeekDate,
  notifyTypeForKind,
  pemToDer,
  screenForType,
  signApnsJwt,
  toggleColumnForKind,
} from '../functions/push-notify/apns.ts';

test('formatMoney renders dollars with cents', () => {
  assert.equal(formatMoney(1234), '$12.34');
  assert.equal(formatMoney(10000), '$100.00');
  assert.equal(formatMoney(0), '$0.00');
});

test('formatWeekDate renders Oct 25, 2026', () => {
  assert.equal(formatWeekDate('2026-10-25'), 'Oct 25, 2026');
});

test('formatMonthLabel renders October', () => {
  assert.equal(formatMonthLabel('2026-10'), 'October');
});

test('currentWeekStartNY returns the Sunday of the week', () => {
  // Monday Nov 16, 2026 (NY) -> Sunday Nov 15, 2026.
  assert.equal(currentWeekStartNY(new Date('2026-11-16T12:00:00-05:00')), '2026-11-15');
  // Sunday Nov 15, 2026 -> itself.
  assert.equal(currentWeekStartNY(new Date('2026-11-15T12:00:00-05:00')), '2026-11-15');
});

test('week_closed copy: single week with surplus', () => {
  const copy = buildCopy('week_closed', { weekStarts: ['2026-10-25'], surplusCents: 1234, fundName: 'Savings' });
  assert.equal(copy.title, 'Week Closed');
  assert.equal(copy.body, 'Week of Oct 25, 2026 is closed. $12.34 left went to Savings.');
});

test('week_closed copy: single week, no surplus', () => {
  const copy = buildCopy('week_closed', { weekStarts: ['2026-10-25'], surplusCents: 0, fundName: 'Savings' });
  assert.equal(copy.body, 'Week of Oct 25, 2026 is closed.');
});

test('week_closed copy: multi-week', () => {
  const copy = buildCopy('week_closed', { weekStarts: ['2026-10-18', '2026-10-25'], surplusCents: 5000, fundName: 'Savings' });
  assert.equal(copy.body, '2 weeks are closed. $50.00 left went to Savings.');
});

test('new_week copy: with and without an amount', () => {
  assert.equal(buildCopy('new_week', { availableCents: 30000 }).body, 'A new week started. $300.00 to spend this week.');
  assert.equal(buildCopy('new_week', { availableCents: null }).body, 'A new week started.');
});

test('over_budget copy', () => {
  const copy = buildCopy('over_budget', { overCents: 4567 });
  assert.equal(copy.title, 'Over Budget');
  assert.equal(copy.body, "You're over budget this week. $45.67 over.");
});

test('new_purchase copy: single and multi', () => {
  assert.equal(buildCopy('new_purchase', { count: 1, amountCents: 1234, merchant: 'Amazon' }).body, '$12.34 at Amazon.');
  assert.equal(buildCopy('new_purchase', { count: 3, totalCents: 4567 }).body, '3 new purchases, $45.67 in total.');
});

test('new_income copy: single and multi', () => {
  assert.equal(buildCopy('new_income', { count: 1, amountCents: 120000, merchant: 'Acme Payroll' }).body, '$1,200.00 from Acme Payroll.');
  assert.equal(buildCopy('new_income', { count: 2, totalCents: 145000 }).body, '2 new incomes, $1,450.00 in total.');
});

test('new_charity copy: single and multi', () => {
  assert.equal(buildCopy('new_charity', { count: 1, amountCents: 1000, merchant: 'Toiremorg' }).body, '$10.00 to Toiremorg.');
  assert.equal(buildCopy('new_charity', { count: 2, totalCents: 1200 }).body, '2 charity gifts, $12.00 in total.');
});

test('monthly_statement copy', () => {
  const copy = buildCopy('monthly_statement', { monthLabel: 'October' });
  assert.equal(copy.title, 'Monthly Statement');
  assert.equal(copy.body, 'Your October statement is ready.');
});

test('member joined/left copy', () => {
  assert.equal(buildCopy('member_joined', { name: 'Shuki' }).body, 'Shuki joined the household.');
  assert.equal(buildCopy('member_left', { name: 'Shuki' }).body, 'Shuki left the household.');
});

test('gmail_expiring copy never names a source', () => {
  const copy = buildCopy('gmail_expiring', {});
  assert.equal(copy.title, 'Gmail Connection Expiring');
  assert.match(copy.body, /Reconnect it in Settings/);
});

test('fund_request copy: with and without a note', () => {
  const withNote = buildCopy('fund_request', { name: 'Shuki', amountCents: 5000, fundName: 'Savings', note: 'New tires' });
  assert.equal(withNote.title, 'Fund Request Waiting');
  assert.equal(withNote.body, 'Shuki asked for $50.00 from Savings. "New tires."');
  const withoutNote = buildCopy('fund_request', { name: 'Shuki', amountCents: 5000, fundName: 'Savings' });
  assert.equal(withoutNote.body, 'Shuki asked for $50.00 from Savings. Tap to review.');
});

test('large_purchase copy: single and multi', () => {
  assert.equal(buildCopy('large_purchase', { count: 1, amountCents: 15000, merchant: 'Best Buy' }).body, '$150.00 at Best Buy — a large purchase.');
  assert.equal(buildCopy('large_purchase', { count: 2, totalCents: 32000 }).body, '2 large purchases, $320.00 in total.');
});

test('bank_broken copy', () => {
  const copy = buildCopy('bank_broken', {});
  assert.equal(copy.title, 'Bank Connection Broken');
  assert.match(copy.body, /Reconnect it in Settings/);
});

test('budget_increased copy', () => {
  const copy = buildCopy('budget_increased', { addedCents: 5000, newAllowanceCents: 45000 });
  assert.equal(copy.title, 'Budget Increased');
  assert.equal(copy.body, 'Budget increased by $50.00. Weekly budget is now $450.00.');
});

test('no copy names a source', () => {
  // The owner's rule: never "from email" / "from bank" / "from Amex".
  const copies = [
    buildCopy('new_purchase', { count: 1, amountCents: 100, merchant: 'Amazon' }),
    buildCopy('new_income', { count: 1, amountCents: 100, merchant: 'Acme' }),
    buildCopy('large_purchase', { count: 1, amountCents: 10000, merchant: 'Best Buy' }),
  ];
  for (const copy of copies) {
    assert.doesNotMatch(copy.body, /from (email|bank|amex)/i);
  }
});

test('dedupe keys are type-prefixed and stable', () => {
  assert.equal(dedupeKey('purchase', ['abc123']), 'purchase:abc123');
  assert.equal(dedupeKey('week_closed', ['h1', '2026-10-25']), 'week_closed:h1:2026-10-25');
  assert.equal(dedupeKey('gmail_expiring', ['h1', 'c1', '2026-11-16']), 'gmail_expiring:h1:c1:2026-11-16');
});

test('kind mappings', () => {
  assert.equal(toggleColumnForKind('charge'), 'new_purchase');
  assert.equal(toggleColumnForKind('income'), 'new_income');
  assert.equal(toggleColumnForKind('charity'), 'new_charity');
  assert.equal(notifyTypeForKind('charge'), 'new_purchase');
  assert.equal(notifyTypeForKind('income'), 'new_income');
  assert.equal(notifyTypeForKind('charity'), 'new_charity');
  assert.equal(dedupePrefixForKind('charge'), 'purchase');
  assert.equal(dedupePrefixForKind('income'), 'income');
  assert.equal(dedupePrefixForKind('charity'), 'charity');
  assert.throws(() => toggleColumnForKind('refund'), /unknown transaction kind/);
});

test('screen mapping', () => {
  assert.equal(screenForType('week_closed'), 'week');
  assert.equal(screenForType('new_week'), 'week');
  assert.equal(screenForType('over_budget'), 'week');
  assert.equal(screenForType('budget_increased'), 'week');
  assert.equal(screenForType('new_purchase'), 'purchases');
  assert.equal(screenForType('new_income'), 'purchases');
  assert.equal(screenForType('large_purchase'), 'purchases');
  assert.equal(screenForType('fund_request'), 'money');
  assert.equal(screenForType('member_joined'), 'settings');
  assert.equal(screenForType('gmail_expiring'), 'settings');
  assert.equal(screenForType('bank_broken'), 'settings');
  assert.equal(screenForType('monthly_statement'), 'statement');
});

test('base64url round-trip', () => {
  const bytes = new Uint8Array([0, 171, 255, 16, 200]);
  assert.deepEqual(base64urlDecodeToBytes(base64urlEncode(bytes)), bytes);
});

test('pemToDer strips headers and decodes', async () => {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  let b64 = '';
  const chunk = 8192;
  for (let i = 0; i < pkcs8.length; i += chunk) {
    b64 += String.fromCharCode(...pkcs8.subarray(i, i + chunk));
  }
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(b64)}\n-----END PRIVATE KEY-----\n`;
  assert.deepEqual(pemToDer(pem), pkcs8);
});

test('signApnsJwt produces a verifiable ES256 JWT', async () => {
  clearApnsJwtCache();
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  let b64 = '';
  for (let i = 0; i < pkcs8.length; i += 8192) {
    b64 += String.fromCharCode(...pkcs8.subarray(i, i + 8192));
  }
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(b64)}\n-----END PRIVATE KEY-----\n`;
  const now = 1794000000;
  const jwt = await signApnsJwt({ keyPem: pem, keyId: 'KEYID12345', teamId: 'TEAMID1234' }, now);
  const [headerB64, payloadB64, signatureB64] = jwt.split('.');
  const header = JSON.parse(new TextDecoder().decode(base64urlDecodeToBytes(headerB64)));
  const payload = JSON.parse(new TextDecoder().decode(base64urlDecodeToBytes(payloadB64)));
  assert.equal(header.alg, 'ES256');
  assert.equal(header.kid, 'KEYID12345');
  assert.equal(payload.iss, 'TEAMID1234');
  assert.equal(payload.iat, now);
  const signature = base64urlDecodeToBytes(signatureB64);
  const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pair.publicKey, signature, data);
  assert.equal(valid, true);
  // Cached: a second call within the hour returns the same JWT.
  const again = await signApnsJwt({ keyPem: pem, keyId: 'KEYID12345', teamId: 'TEAMID1234' }, now + 60);
  assert.equal(again, jwt);
  clearApnsJwtCache();
});
