// Merchant rules tests (build 30, task E) — run with:
//   node --test supabase/tests/merchant-rules.test.mjs
// Pure helpers from supabase/functions/_shared/canonical.ts,
// imported directly (Node type-strips .ts); plaid-sync, gmail-poll
// and ingest-amex-alert ship identical copies, so the tested code
// IS the deployed code. The SQL mirror (merchant-rules.sql) must
// stay in step with the matching rules pinned here.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  applyMerchantRuleToMerchant,
  loadMerchantRules,
  matchMerchantRule,
  merchantRuleKey,
  merchantRuleSquash,
} from '../functions/_shared/canonical.ts';

// Seed rules from merchant-rules.sql §6, as the JS layer sees them.
const SEED_RULES = [
  { pattern_key: 'BALTIMORE GAS AND ELECTRIC COMPANY', pattern_squash: 'BALTIMOREGASANDELECTRICCOMPANY', match_type: 'exact', display_name: 'BGE', fixed_kind: null },
  { pattern_key: 'GOODYEAR', pattern_squash: 'GOODYEAR', match_type: 'prefix', display_name: 'GOODYEAR', fixed_kind: null },
  { pattern_key: 'AMAZON', pattern_squash: 'AMAZON', match_type: 'prefix', display_name: 'AMAZON', fixed_kind: null },
  { pattern_key: 'TOIREMORG', pattern_squash: 'TOIREMORG', match_type: 'prefix', display_name: 'TOIREMORG', fixed_kind: null },
  { pattern_key: 'TENYAD KALLAH GEMACH', pattern_squash: 'TENYADKALLAHGEMACH', match_type: 'exact', display_name: 'TENYAD KALLAH GEMACH', fixed_kind: null },
  { pattern_key: 'INTERNAL TRANSFER CREDIT: SAVINGS', pattern_squash: 'INTERNALTRANSFERCREDITSAVINGS', match_type: 'prefix', display_name: 'TRANSFER TO SAVINGS', fixed_kind: 'transfer' },
  { pattern_key: 'WIRE TRANSFER DOMESTIC OUTGOING', pattern_squash: 'WIRETRANSFERDOMESTICOUTGOING', match_type: 'exact', display_name: 'WIRE TRANSFER', fixed_kind: null },
  { pattern_key: 'WIRE TRANSFER FEE DOMESTIC OUTGOING', pattern_squash: 'WIRETRANSFERFEEDOMESTICOUTGOING', match_type: 'exact', display_name: 'WIRE TRANSFER FEE', fixed_kind: null },
  { pattern_key: 'ONLINE TRANSFER / PAYMENT: DEBIT', pattern_squash: 'ONLINETRANSFERPAYMENTDEBIT', match_type: 'exact', display_name: 'TRANSFER', fixed_kind: 'transfer' },
];

const display = (merchant, rules = SEED_RULES, amount = 1000) =>
  applyMerchantRuleToMerchant(rules, merchant, amount).merchant;

// --- normalization ---------------------------------------------------

test('key: uppercases, trims, collapses spaces, strips leading bank artifacts', () => {
  assert.equal(merchantRuleKey('  Baltimore  GAS and Electric Company '), 'BALTIMORE GAS AND ELECTRIC COMPANY');
  assert.equal(merchantRuleKey('=tenyadkallahgemach'), 'TENYADKALLAHGEMACH');
  assert.equal(merchantRuleKey(''), '');
});

test('squash: removes all non-alphanumerics so spaced and compact spellings match', () => {
  assert.equal(merchantRuleSquash('=tenyadkallahgemach'), 'TENYADKALLAHGEMACH');
  assert.equal(merchantRuleSquash('TENYAD KALLAH GEMACH'), 'TENYADKALLAHGEMACH');
  assert.equal(merchantRuleSquash('INTERNAL TRANSFER CREDIT: SAVINGS -5939'), 'INTERNALTRANSFERCREDITSAVINGS5939');
});

// --- owner examples --------------------------------------------------

test('owner example: Baltimore GAS and Electric Company -> BGE', () => {
  assert.equal(display('Baltimore GAS and Electric Company'), 'BGE');
});

test('owner example: Goodyear Tirerubber -> Goodyear (prefix stem)', () => {
  assert.equal(display('Goodyear Tirerubber'), 'GOODYEAR');
});

test('owner example: Toiremorg spellings -> one name', () => {
  assert.equal(display('TOIREMORG'), 'TOIREMORG');
  assert.equal(display('TOIREMORG CHARITY'), 'TOIREMORG');
  assert.equal(display('Toiremorg Charity Inc'), 'TOIREMORG');
});

test('owner example: =tenyadkallahgemach -> Tenyad Kallah Gemach (squash)', () => {
  assert.equal(display('=tenyadkallahgemach'), 'TENYAD KALLAH GEMACH');
  assert.equal(display('TENYAD KALLAH GEMACH'), 'TENYAD KALLAH GEMACH');
});

test('owner example: Amazon variants -> Amazon', () => {
  assert.equal(display('AMAZON'), 'AMAZON');
  assert.equal(display('AMAZON MARKEPLACE NA PA'), 'AMAZON');
  assert.equal(display('AMAZON.COM'), 'AMAZON');
});

test('owner example: Internal Transfer Credit: Savings -5939 -> Transfer to Savings', () => {
  const r = applyMerchantRuleToMerchant(SEED_RULES, 'Internal Transfer Credit: Savings -5939', 5000);
  assert.equal(r.merchant, 'TRANSFER TO SAVINGS');
  assert.equal(r.kindOverride, 'transfer');
});

test('owner example: wire transfers -> Wire Transfer / Wire Transfer Fee', () => {
  assert.equal(display('Wire Transfer Domestic Outgoing'), 'WIRE TRANSFER');
  assert.equal(display('Wire Transfer FEE Domestic Outgoing'), 'WIRE TRANSFER FEE');
  // The fee row must NOT be swallowed by the plain wire rule: exact
  // match on the longer pattern wins over the shorter one.
  const rule = matchMerchantRule(SEED_RULES, 'WIRE TRANSFER FEE DOMESTIC OUTGOING');
  assert.equal(rule.display_name, 'WIRE TRANSFER FEE');
});

test('owner example: Online Transfer / Payment: Debit -> Transfer', () => {
  const r = applyMerchantRuleToMerchant(SEED_RULES, 'Online Transfer / Payment: Debit', -2500);
  assert.equal(r.merchant, 'TRANSFER');
  assert.equal(r.kindOverride, 'transfer');
});

// --- matching strictness ----------------------------------------------

test('no rule: unknown merchants pass through unchanged', () => {
  assert.equal(display('ROYAL FARMS #123'), 'ROYAL FARMS #123');
  assert.equal(matchMerchantRule(SEED_RULES, 'ROYAL FARMS #123'), null);
});

test('exact beats prefix: a taught exact spelling wins over a stem', () => {
  const rules = [
    { pattern_key: 'AMAZON', pattern_squash: 'AMAZON', match_type: 'prefix', display_name: 'AMAZON', fixed_kind: null },
    { pattern_key: 'AMAZON MARKEPLACE NA PA', pattern_squash: 'AMAZONMARKEPLACENAPA', match_type: 'exact', display_name: 'AMAZON MARKETPLACE', fixed_kind: null },
  ];
  assert.equal(matchMerchantRule(rules, 'AMAZON MARKEPLACE NA PA').display_name, 'AMAZON MARKETPLACE');
  assert.equal(matchMerchantRule(rules, 'AMAZON PRIME').display_name, 'AMAZON');
});

test('includes matches mid-word: AMAZON is a substring stem, not an anchor (build 34)', () => {
  // F-26 (build 61 audit): this test pinned the pre-build-34 'prefix'
  // rule (a stem must anchor at the start). Build 34 renamed 'prefix'
  // to 'includes' — the name must CONTAIN the pattern anywhere
  // (canonical.ts matchMerchantRule, merchant-rules-includes.sql) —
  // so 'MY AMAZON STORE' now matches the AMAZON rule. The old
  // expectation (null) was the stale pin, not a regression.
  assert.equal(matchMerchantRule(SEED_RULES, 'MY AMAZON STORE')?.display_name, 'AMAZON');
  // And a merchant with no rule substring still matches nothing.
  assert.equal(matchMerchantRule(SEED_RULES, 'MY STORE'), null);
});

test('empty merchant matches nothing', () => {
  assert.equal(matchMerchantRule(SEED_RULES, ''), null);
  assert.equal(matchMerchantRule(SEED_RULES, '   '), null);
});

test('rename teaches one spelling only by default (exact): other spellings unaffected', () => {
  const rules = [
    { pattern_key: 'GOODYEAR TIRERUBBER', pattern_squash: 'GOODYEARTIRERUBBER', match_type: 'exact', display_name: 'GOODYEAR', fixed_kind: null },
  ];
  assert.equal(display('GOODYEAR TIRERUBBER', rules), 'GOODYEAR');
  assert.equal(display('GOODYEAR AUTO SERVICE', rules), 'GOODYEAR AUTO SERVICE');
});

// --- fixed kind + sign guard -------------------------------------------

test('fixed kind applies to new matching rows (charity merchant)', () => {
  const rules = [
    { pattern_key: 'KEREN HATZEDAKA', pattern_squash: 'KERENHATZEDAKA', match_type: 'exact', display_name: 'KEREN HATZEDAKA', fixed_kind: 'charity' },
  ];
  const r = applyMerchantRuleToMerchant(rules, 'KEREN HATZEDAKA', 5000);
  assert.equal(r.merchant, 'KEREN HATZEDAKA');
  assert.equal(r.kindOverride, 'charity');
});

test('sign guard: a money-out fixed kind never overrides a money-in row', () => {
  const rules = [
    { pattern_key: 'KEREN HATZEDAKA', pattern_squash: 'KERENHATZEDAKA', match_type: 'exact', display_name: 'KEREN HATZEDAKA', fixed_kind: 'charity' },
  ];
  // A negative row from the same merchant is a refund of a gift.
  assert.equal(applyMerchantRuleToMerchant(rules, 'KEREN HATZEDAKA', -5000).kindOverride, null);
});

test('sign guard: a money-in fixed kind never overrides a money-out row', () => {
  const rules = [
    { pattern_key: 'AMEX PAYMENT', pattern_squash: 'AMEXPAYMENT', match_type: 'exact', display_name: 'AMEX PAYMENT', fixed_kind: 'payment' },
  ];
  assert.equal(applyMerchantRuleToMerchant(rules, 'AMEX PAYMENT', 5000).kindOverride, null);
  assert.equal(applyMerchantRuleToMerchant(rules, 'AMEX PAYMENT', -5000).kindOverride, 'payment');
});

test('sign guard: transfer applies to either sign', () => {
  const rules = [
    { pattern_key: 'ONLINE TRANSFER / PAYMENT: DEBIT', pattern_squash: 'ONLINETRANSFERPAYMENTDEBIT', match_type: 'exact', display_name: 'TRANSFER', fixed_kind: 'transfer' },
  ];
  assert.equal(applyMerchantRuleToMerchant(rules, 'ONLINE TRANSFER / PAYMENT: DEBIT', 5000).kindOverride, 'transfer');
  assert.equal(applyMerchantRuleToMerchant(rules, 'ONLINE TRANSFER / PAYMENT: DEBIT', -5000).kindOverride, 'transfer');
});

test('Toiremorg rule carries no fixed kind: the two $2 gifts keep their own kinds', () => {
  const rule = matchMerchantRule(SEED_RULES, 'TOIREMORG CHARITY');
  assert.equal(rule.fixed_kind, null);
  assert.equal(applyMerchantRuleToMerchant(SEED_RULES, 'TOIREMORG CHARITY', 200).kindOverride, null);
});

// --- loadMerchantRules (fake db) ---------------------------------------

function fakeDb({ ruleRows = [] }) {
  return {
    from(table) {
      const chain = {
        select() { return chain; },
        eq() { return chain; },
        order() { return chain; },
        then(res) { return Promise.resolve({ data: table === 'merchant_rules' ? ruleRows : null, error: null }).then(res); },
      };
      return chain;
    },
  };
}

test('loadMerchantRules returns the household rules; errors fail open to []', async () => {
  const db = fakeDb({ ruleRows: SEED_RULES.slice(0, 2) });
  assert.equal((await loadMerchantRules(db, 'hh-1')).length, 2);
  const failing = { from() { throw new Error('down'); } };
  assert.deepEqual(await loadMerchantRules(failing, 'hh-1'), []);
});
