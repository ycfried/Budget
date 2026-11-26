// Multi-bank email alert parser tests — run with:
//   node --test test/gmail-banks.test.mjs
// Pure helpers only (no network, no database, no Google calls). The
// helpers live in supabase/functions/_shared/gmail-parse.ts and are
// imported directly (Node type-strips .ts).
//
// Samples are the report's real examples
// (research_notes/bank-transaction-alert-emails-20261126-0514/report.md):
// Chase / Bank of America / Capital One / Citi bodies were verified
// live on Meli (Sept 2026); Wells Fargo / US Bank / Discover rest on
// user-posted screenshots (authenticity unverified); PNC / TD have
// NO confirmed purchase template, so their tests use the generic
// rules only and are labelled as such — do not read them as proof
// of a confirmed PNC/TD format. A real PNC/TD sample from the owner
// is still owed.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  authResultsPassForBank,
  bankAlertMatches,
  bankForDomain,
  buildAlertQuery,
  classifyBankAlert,
  identifyBankAlert,
  parseBankAlertText,
  parseEmailAlert,
} from '../supabase/functions/_shared/gmail-parse.ts';

const chaseAuth = 'mx.google.com; spf=pass (google.com: domain of no-reply@alert.chase.com) smtp.mailfrom=alert.chase.com; dkim=pass header.i=@alert.chase.com';
const bofaAuth = 'mx.google.com; spf=pass smtp.mailfrom=alerts@bofa.com; dkim=pass header.i=@bofa.com';
const wellsAuth = 'mx.google.com; spf=pass smtp.mailfrom=alerts@notify.wellsfargo.com; dkim=pass header.i=@notify.wellsfargo.com';
const citiAuth = 'mx.google.com; spf=pass smtp.mailfrom=alerts@citibank.com; dkim=pass header.i=@citibank.com';
const capOneAuth = 'mx.google.com; spf=pass smtp.mailfrom=noreply@capitalone.com; dkim=pass header.i=@capitalone.com';
const discoverAuth = 'mx.google.com; spf=pass smtp.mailfrom=noreply@discover.com; dkim=pass header.i=@discover.com';
const usbankAuth = 'mx.google.com; spf=pass smtp.mailfrom=1800USBanks@alerts.usbank.com; dkim=pass header.i=@alerts.usbank.com';
const pncAuth = 'mx.google.com; spf=pass smtp.mailfrom=transactional@e.pnc.com; dkim=pass header.i=@e.pnc.com';
const tdAuth = 'mx.google.com; spf=pass smtp.mailfrom=alerts@tdbank.com; dkim=pass header.i=@tdbank.com';

// --- Sender identification (domain, right-to-left) -----------------------

test('identifyBankAlert: allowlisted domains and subdomains resolve to the bank', () => {
  assert.equal(identifyBankAlert('no-reply@alert.chase.com', chaseAuth), 'chase');
  assert.equal(identifyBankAlert('alerts@bofa.com', bofaAuth), 'bofa');
  assert.equal(identifyBankAlert('alerts@notify.wellsfargo.com', wellsAuth), 'wellsfargo');
  assert.equal(identifyBankAlert('alerts@citibank.com', citiAuth), 'citi');
  assert.equal(identifyBankAlert('noreply@capitalone.com', capOneAuth), 'capitalone');
  assert.equal(identifyBankAlert('noreply@discover.com', discoverAuth), 'discover');
  assert.equal(identifyBankAlert('1800USBanks@alerts.usbank.com', usbankAuth), 'usbank');
  assert.equal(identifyBankAlert('transactional@e.pnc.com', pncAuth), 'pnc');
  assert.equal(identifyBankAlert('alerts@tdbank.com', tdAuth), 'td');
});

test('identifyBankAlert: lookalike domains are rejected, never routed to the bank', () => {
  const capOneLookalike = 'mx.google.com; spf=pass smtp.mailfrom=noreply@capitalone-secure.com; dkim=pass header.i=@capitalone-secure.com';
  assert.equal(identifyBankAlert('noreply@capitalone-secure.com', capOneLookalike), null);
  const tdLookalike = 'mx.google.com; spf=pass smtp.mailfrom=alerts@td-bank-alerts.net; dkim=pass header.i=@td-bank-alerts.net';
  assert.equal(identifyBankAlert('alerts@td-bank-alerts.net', tdLookalike), null);
  assert.equal(identifyBankAlert('alerts@chase-alerts.com', 'mx.google.com; spf=pass smtp.mailfrom=alerts@chase-alerts.com; dkim=pass header.i=@chase-alerts.com'), null);
});

test('identifyBankAlert: unknown and free-mail senders resolve to nothing', () => {
  assert.equal(identifyBankAlert('alerts@example.com', ''), null);
  assert.equal(identifyBankAlert('someone@gmail.com', ''), null);
  assert.equal(identifyBankAlert('', ''), null);
});

test('bankForDomain: exact and subdomain match; lookalikes do not match', () => {
  assert.equal(bankForDomain('alert.chase.com'), 'chase');
  assert.equal(bankForDomain('chase.com'), 'chase');
  assert.equal(bankForDomain('e.pnc.com'), 'pnc');
  assert.equal(bankForDomain('notify.wellsfargo.com'), 'wellsfargo');
  assert.equal(bankForDomain('capitalone-secure.com'), null);
  assert.equal(bankForDomain('td-bank-alerts.net'), null);
});

// --- Authentication-Results gate (per bank) ------------------------------

test('authResultsPassForBank: own domain + dkim + spf passes; anything else fails', () => {
  assert.equal(authResultsPassForBank(chaseAuth, 'chase'), true);
  assert.equal(authResultsPassForBank(capOneAuth, 'capitalone'), true);
  // Right bank, wrong domain.
  assert.equal(authResultsPassForBank(chaseAuth, 'bofa'), false);
  // DKIM fail / SPF missing quarantine, same as Amex.
  assert.equal(authResultsPassForBank('mx.google.com; spf=pass smtp.mailfrom=alert.chase.com; dkim=fail header.i=@alert.chase.com', 'chase'), false);
  assert.equal(authResultsPassForBank('mx.google.com; dkim=pass header.i=@alert.chase.com', 'chase'), false);
  // Lookalike domain never passes, even with dkim+spf pass.
  assert.equal(authResultsPassForBank('mx.google.com; spf=pass smtp.mailfrom=noreply@capitalone-secure.com; dkim=pass header.i=@capitalone-secure.com', 'capitalone'), false);
  assert.equal(authResultsPassForBank('', 'chase'), false);
});

// --- Classification (headline / first lines, not subject) ----------------

test('classifyBankAlert: purchase / declined / fraud / payment-due / deposit-refund / other', () => {
  assert.equal(classifyBankAlert('', 'You made a $37.72 transaction'), 'purchase');
  assert.equal(classifyBankAlert('', 'a transaction using a Wells Fargo Debit Card ending in 6063 was declined due to insufficient funds'), 'declined');
  assert.equal(classifyBankAlert('', 'Do you recognize this purchase? Date: 6/3/2025 Merchant Name: United Airlines Amount: $2,169.00'), 'fraud');
  assert.equal(classifyBankAlert('', 'Action requested: Please confirm activity on your card'), 'fraud');
  assert.equal(classifyBankAlert('', 'Your payment is due in 5 days. Your payment is due $26.23 for account ending in 1234'), 'payment_due');
  assert.equal(classifyBankAlert('', 'A new payment of $499.00 from JANE DOE was deposited in your account'), 'deposit_refund');
  assert.equal(classifyBankAlert('', 'Your monthly statement is ready to view'), 'payment_due');
  assert.equal(classifyBankAlert('', 'Security Alert There was a request to send a domestic wire transfer from your account.'), 'other');
  // A fraud subject alone does not classify when the body is silent
  // about it — but a purchase subject does not rescue a silent body either.
  assert.equal(classifyBankAlert('Do you recognize this purchase?', ''), 'fraud');
  assert.equal(classifyBankAlert('A purchase was charged to your account', ''), 'purchase');
});

// --- One sample per bank (report's real examples) ------------------------

test('parse: Chase — headline + labelled table; $0.01 threshold is NOT the amount', () => {
  const out = parseBankAlertText({
    subject: 'Transaction alert',
    body: 'Transaction alert You made a $37.72 transaction Account: Chase Freedom Flex Mastercard (…1234) Date: Sep 13, 2026 at 9:22 PM ET Merchant: AMAZON MKTPLACE PMTS Amount: $37.72 You are receiving this alert because your transaction was more than the $0.01 level you set.',
    date: '2026-09-13',
    from: 'no-reply@alert.chase.com',
    authResults: chaseAuth,
  });
  assert.deepEqual(out, { amountCents: 3772, merchant: 'AMAZON MKTPLACE PMTS', cardSuffix: '1234', date: '2026-09-13', bank: 'chase', source: 'chase_alert', kind: 'purchase', provisional: false });
});

test('parse: Bank of America — "Where:" merchant, date only, no time', () => {
  const out = parseBankAlertText({
    subject: '',
    body: 'Credit card transaction exceeds alert limit you set Customized Cash Rewards Visa Signature ending in 5678 Amount: $18.97 Date: September 13, 2026 Where: THE WILLOWS MARKET',
    date: '2026-09-13',
    from: 'alerts@bofa.com',
    authResults: bofaAuth,
  });
  assert.deepEqual(out, { amountCents: 1897, merchant: 'THE WILLOWS MARKET', cardSuffix: '5678', date: '2026-09-13', bank: 'bofa', source: 'bofa_alert', kind: 'purchase', provisional: false });
});

test('parse: Wells Fargo — prose sentence, mixed-case merchant, no body date (falls back to email date)', () => {
  const out = parseBankAlertText({
    subject: '',
    body: 'a Wells Fargo Debit Card ending in 4550 was used for a $5.25 purchase at Bitrefill in Stockholm, Sweden Sign on for details, manage alerts, call the number on the back of the card if unrecognized',
    date: '2026-10-01',
    from: 'alerts@notify.wellsfargo.com',
    authResults: wellsAuth,
  });
  assert.deepEqual(out, { amountCents: 525, merchant: 'Bitrefill', cardSuffix: '4550', date: '2026-10-01', bank: 'wellsfargo', source: 'wellsfargo_alert', kind: 'purchase', provisional: false });
});

test('parse: Citi — labelled block, "exceeded $0.01" is NOT the amount', () => {
  const out = parseBankAlertText({
    subject: '',
    body: 'CUSTOM ALERT A transaction of $73.30 was made on your account You\'re receiving this email based on your custom alert settings. The transaction made on your Costco Anywhere account exceeded $0.01. The transaction details are listed below. Amount: $73.30 Card Ending In 9876 Merchant: 76 - DBA DNA LAKESHO Date: 09/09/2026 Time: 03:49 PM ET',
    date: '2026-09-09',
    from: 'alerts@citibank.com',
    authResults: citiAuth,
  });
  assert.deepEqual(out, { amountCents: 7330, merchant: '76 - DBA DNA LAKESHO', cardSuffix: '9876', date: '2026-09-09', bank: 'citi', source: 'citi_alert', kind: 'purchase', provisional: false });
});

test('parse: Capital One — prose sentence, pending authorisation is provisional', () => {
  const out = parseBankAlertText({
    subject: 'A purchase was charged to your Capital One account.',
    body: 'A purchase was charged to your account. About your Savor Credit Card ending in 4321 As requested, we\'re notifying you that on Sep. 14, 2026, at BLUE BOTTLE COFFEE, a pending authorization or purchase in the amount of $7.00 was placed or charged on your Savor Credit Card. Note: You\'ll receive this notification for both purchases and pending authorizations, such as car rentals, hotel reservations and gas purchases, even if an actual transaction hasn\'t taken place.',
    date: '2026-09-14',
    from: 'noreply@capitalone.com',
    authResults: capOneAuth,
  });
  assert.deepEqual(out, { amountCents: 700, merchant: 'BLUE BOTTLE COFFEE', cardSuffix: '4321', date: '2026-09-14', bank: 'capitalone', source: 'capitalone_alert', kind: 'purchase', provisional: true });
});

test('parse: Discover — post-merger Capital One template, discover.com sender', () => {
  const out = parseBankAlertText({
    subject: 'A new transaction was charged to your Discover card.',
    body: 'A purchase was charged to your account. Discover it Card ending in 8765 on Aug. 26, 2026, at MARRIOTT HOTEL, a pending authorization/purchase of $478.64 was placed',
    date: '2026-08-26',
    from: 'noreply@discover.com',
    authResults: discoverAuth,
  });
  assert.deepEqual(out, { amountCents: 47864, merchant: 'MARRIOTT HOTEL', cardSuffix: '8765', date: '2026-08-26', bank: 'discover', source: 'discover_alert', kind: 'purchase', provisional: true });
});

test('parse: US Bank — "was charged $X at MERCHANT", no body date (falls back to email date)', () => {
  const out = parseBankAlertText({
    subject: 'Your U.S. Bank credit card has a new transaction.',
    body: 'Your credit card was charged $226.00 at Pilot_00034 Your purchase came from a card ending in 3407',
    date: '2026-07-05',
    from: '1800USBanks@alerts.usbank.com',
    authResults: usbankAuth,
  });
  assert.deepEqual(out, { amountCents: 22600, merchant: 'Pilot_00034', cardSuffix: '3407', date: '2026-07-05', bank: 'usbank', source: 'usbank_alert', kind: 'purchase', provisional: false });
});

test('parse: PNC — GENERIC RULES ONLY, no confirmed PNC purchase template exists', () => {
  const out = parseBankAlertText({
    subject: '',
    body: 'PNC Alerts Your card was charged $42.10 at GIANT EAGLE Your purchase came from a card ending in 1111 on October 5, 2026',
    date: '2026-10-05',
    from: 'transactional@e.pnc.com',
    authResults: pncAuth,
  });
  assert.deepEqual(out, { amountCents: 4210, merchant: 'GIANT EAGLE', cardSuffix: '1111', date: '2026-10-05', bank: 'pnc', source: 'pnc_alert', kind: 'purchase', provisional: false });
});

test('parse: TD — GENERIC RULES ONLY, no confirmed TD purchase template exists', () => {
  const out = parseBankAlertText({
    subject: '',
    body: 'TD Alerts Your debit card was charged $15.75 at STARBUCKS Card ending in 2222 on Nov. 3, 2026',
    date: '2026-11-03',
    from: 'alerts@tdbank.com',
    authResults: tdAuth,
  });
  assert.deepEqual(out, { amountCents: 1575, merchant: 'STARBUCKS', cardSuffix: '2222', date: '2026-11-03', bank: 'td', source: 'td_alert', kind: 'purchase', provisional: false });
});

// --- Non-purchases never parse (fail closed) ------------------------------

test('parse: declined, fraud, payment-due, deposit, wire-transfer, and lookalike mail all return null', () => {
  const base = { date: '2026-09-13' };
  // Wells Fargo declined.
  assert.equal(parseBankAlertText({
    ...base, subject: 'Your card was declined.',
    body: 'a transaction using a Wells Fargo Debit Card ending in 6063 was declined due to insufficient funds, amount 649.56 USD, at LYFT *XD RENTAL FEE in +18552800278 UNITED STATES, dated 05/06/2026 06:50 AM US/Pacific',
    from: 'alerts@notify.wellsfargo.com', authResults: wellsAuth,
  }), null);
  // Capital One fraud / verification ("Do you recognize this purchase?").
  assert.equal(parseBankAlertText({
    ...base, subject: 'Do you recognize this purchase?',
    body: 'Do you recognize this purchase? Date: 6/3/2025 14:13:28 Merchant Name: United Airlines Amount: $2,169.00 Outcome: Yes / No',
    from: 'noreply@capitalone.com', authResults: capOneAuth,
  }), null);
  // Chase payment due.
  assert.equal(parseBankAlertText({
    ...base, subject: 'Your payment is due',
    body: 'Your payment is due in 5 days. Your payment is due $26.23 for account ending in 1234',
    from: 'no-reply@e.chase.com', authResults: chaseAuth,
  }), null);
  // US Bank Zelle deposit.
  assert.equal(parseBankAlertText({
    ...base, subject: 'A new Zelle payment is in your account.',
    body: 'A new payment of $499.00 from JANE DOE was deposited in your account, credited to account ending in 1234, received date 07/09/2026',
    from: '1800USBanks@alerts.usbank.com', authResults: usbankAuth,
  }), null);
  // PNC wire-transfer Security Alert.
  assert.equal(parseBankAlertText({
    ...base, subject: 'Security Alert',
    body: 'Security Alert There was a request to send a domestic wire transfer from your account. Requested Date: 08/13/26 at 3:47 p.m. ET Confirmation Number ending in 31169 Wire Transfer Amount: $7,000.00',
    from: 'transactional@e.pnc.com', authResults: pncAuth,
  }), null);
  // Lookalike sender, genuine-looking body.
  assert.equal(parseBankAlertText({
    ...base, subject: 'A purchase was charged to your Capital One account.',
    body: 'A purchase was charged to your account. on Sep. 14, 2026, at BLUE BOTTLE COFFEE, a pending authorization or purchase in the amount of $7.00 was placed',
    from: 'noreply@capitalone-secure.com',
    authResults: 'mx.google.com; spf=pass smtp.mailfrom=noreply@capitalone-secure.com; dkim=pass header.i=@capitalone-secure.com',
  }), null);
});

test('parse: missing amount, missing merchant, or bad fallback date returns null', () => {
  assert.equal(parseBankAlertText({
    subject: '', body: 'A purchase was charged to your account. at BLUE BOTTLE COFFEE', date: '2026-09-14',
    from: 'noreply@capitalone.com', authResults: capOneAuth,
  }), null);
  assert.equal(parseBankAlertText({
    subject: '', body: 'A purchase was charged to your account for $7.00.', date: '2026-09-14',
    from: 'noreply@capitalone.com', authResults: capOneAuth,
  }), null);
  assert.equal(parseBankAlertText({
    subject: '', body: 'A purchase was charged to your account. at BLUE BOTTLE COFFEE, in the amount of $7.00 was placed', date: '09/14/2026',
    from: 'noreply@capitalone.com', authResults: capOneAuth,
  }), null);
  // No sender at all: unidentifiable, even with a perfect body.
  assert.equal(parseBankAlertText({
    subject: '', body: 'A purchase was charged to your account. on Sep. 14, 2026, at BLUE BOTTLE COFFEE, a pending authorization or purchase in the amount of $7.00 was placed', date: '2026-09-14',
  }), null);
});

// --- Pending-vs-posted dedupe --------------------------------------------

test('bankAlertMatches: pending authorisation matches the posted charge next day; others do not', () => {
  const pending = { bank: 'capitalone', cardSuffix: '4321', amountCents: 700, merchant: 'BLUE BOTTLE COFFEE', date: '2026-09-14' };
  const posted = { bank: 'capitalone', cardSuffix: '4321', amountCents: 700, merchant: 'Blue Bottle Coffee', date: '2026-09-15' };
  assert.equal(bankAlertMatches(pending, posted), true);
  assert.equal(bankAlertMatches(pending, { ...posted, amountCents: 701 }), false);
  assert.equal(bankAlertMatches(pending, { ...posted, merchant: 'STARBUCKS' }), false);
  assert.equal(bankAlertMatches(pending, { ...posted, cardSuffix: '9999' }), false);
  assert.equal(bankAlertMatches(pending, { ...posted, cardSuffix: '0000' }), true);
  assert.equal(bankAlertMatches(pending, { ...posted, date: '2026-09-16' }), false);
  assert.equal(bankAlertMatches(pending, { ...posted, bank: 'chase' }), false);
});

// --- Dispatcher -----------------------------------------------------------

test('parseEmailAlert: bank sources dispatch to the generic parser; unknown sources return null', () => {
  const out = parseEmailAlert('chase_alert', {
    subject: 'Transaction alert',
    body: 'You made a $37.72 transaction Merchant: AMAZON MKTPLACE PMTS Amount: $37.72 Date: Sep 13, 2026',
    date: '2026-09-13',
    from: 'no-reply@alert.chase.com',
    authResults: chaseAuth,
  });
  assert.equal(out?.merchant, 'AMAZON MKTPLACE PMTS');
  assert.equal(parseEmailAlert('nope_alert', { subject: '', body: '', date: '2026-09-13' }), null);
});

// --- Query (Part 2) -------------------------------------------------------

test('buildAlertQuery: Amex keeps its subject clause; all nine banks are sender-clauses', () => {
  const q = buildAlertQuery();
  assert.ok(q.includes('from:(americanexpress.com) subject:"Large Purchase"'), 'Amex clause unchanged');
  for (const domain of ['chase.com', 'bofa.com', 'bankofamerica.com', 'wellsfargo.com', 'citibank.com', 'citi.com', 'capitalone.com', 'discover.com', 'usbank.com', 'pnc.com', 'td.com', 'tdbank.com']) {
    assert.ok(q.includes(domain), `query missing ${domain}`);
  }
  // Payment-due / fraud-only senders are deliberately NOT listed.
  assert.equal(q.includes('e.chase.com'), false);
  assert.equal(q.includes('info3.citibank.com'), false);
});
