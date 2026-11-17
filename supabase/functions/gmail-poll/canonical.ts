// Shared ingestion helpers for OnBudget Edge Functions (S3 workstream).
// CANONICAL DEFINITION — plaid-sync and ingest-amex-alert import this
// file. Do NOT duplicate these functions elsewhere with different logic;
// if a bundler ever cannot resolve this import, copy this file verbatim
// and leave a comment pointing back here.
//
// Canonical dedupe hash (audit P1-4):
//   sha256_hex( normalizedMerchant + '|' + date + '|' + signedAmountCents
//              + '|' + cardSuffix )
//   normalizedMerchant = merchant.toUpperCase(), trimmed, internal
//   whitespace collapsed to single spaces.
//   date = YYYY-MM-DD. signedAmountCents = integer cents, charges
//   positive, inflows negative. cardSuffix = last 4 digits, '0000' if
//   unknown.
// The hash is for MATCHING ONLY. It is never the sole uniqueness
// constraint (see supabase/dedupe-fix.sql): upsert order is
// external_id first, then plaid_pending_transaction_id, then hash
// match. Two identical real purchases coexist by row/external identity,
// not by hash.

export function normalizeMerchant(merchant: string): string {
  return String(merchant ?? '').toUpperCase().trim().replace(/\s+/g, ' ');
}

export async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function canonicalHash(
  merchant: string,
  date: string,
  amountCents: number,
  cardSuffix: string,
): Promise<string> {
  return sha256Hex(
    `${normalizeMerchant(merchant)}|${date}|${amountCents}|${String(cardSuffix ?? '0000').slice(-4)}`,
  );
}

// --- Transaction kind classification (audit P0-10, owner P0-10b) ---
// Card payments are NOT refunds. Cash-back statement credits are NOT
// refunds either (spec FINAL A7: excluded from the budget by default).
// Patterns below are matched against the merchant/name string as Plaid
// or the alert supplies it (matching is case-insensitive).
//
// EXACT PATTERNS (do not widen silently — widening reclassifies money):
// Transfers between the household's own accounts are NOT spending and
// NOT refunds (delta3): an internal transfer out to savings must not
// count toward weekly spending, and one in must not net as a refund.
// The signal is the merchant text; it is checked FIRST, before the
// payment/cashback/category rules, so it applies to both classifyKind
// and classifyMerchantOnly. Only INTERNAL transfers match — a transfer
// to another person keeps its charge/refund kind (admin reclassify
// covers those cases individually).
export const TRANSFER_PATTERN = /INTERNAL TRANSFER/i;
// Refund-classification fix (Nov 5, 2026): checking-account inflows
// were labelled 'refund' by the sign fallback. A check deposit is
// income, and a payment credit (EPAYMENT / PAYMENT: CREDIT / / PAYMENT)
// is a card payment — neither is a refund.
export const DEPOSIT_PATTERN = /CHECK DEPOSIT|MOBILE DEPOSIT|\bDEPOSIT\b/i;
export const PAYMENT_PATTERN = /MOBILE PAYMENT|PAYMENT - THANK YOU|CARD PAYMENT|PAYMENT\s*:\s*CREDIT|PAYMENT CREDIT|\/ ?PAYMENT|EPAYMENT|E-PAYMENT|ACH PAYMENT/i;
export const CASHBACK_PATTERN = /CASH BACK|CASHBACK|REWARD/i;
// Charity auto-detect (Nov 8, 2026, P1-NEW1 — owner-reported gap: no
// donation was ever picked up automatically, and no Action could mark
// one). CONSERVATIVE list, owner confirmation pending before launch:
// explicit charity words plus the household's own known charity
// merchants (KEREN HATZEDAKA, TOIREMORG CHARITY, COLEL CHABAD). Only
// money-OUT rows (positive amounts) match — a negative charity-named
// row is a refund of a gift and keeps the sign fallback. Classifying a
// row as 'charity' only moves it out of weekly spending (it counts as
// Given); it does NOT accrue charity — only admin-called
// record_charity_income accrues (R13). Do NOT widen this list silently.
export const CHARITY_PATTERN = /\b(CHARITY|DONATION|DONATE|TZEDAKA|TZEDAKAH|KEREN|CHABAD|TOIREMORG|COLEL)\b/i;

// Plaid personal_finance_category values observed for card payments.
// These are fields Plaid already returns on each /transactions/sync
// entry (personal_finance_category.primary / .detailed, and the legacy
// category[] array); no new Plaid field is invented here. If Plaid does
// not populate them for a given transaction, the merchant-name fallback
// below governs.
function plaidCategoryIndicatesCardPayment(tx: Record<string, unknown>): boolean {
  const pfc = tx.personal_finance_category as
    | { primary?: unknown; detailed?: unknown }
    | undefined;
  const primary = String(pfc?.primary ?? '').toUpperCase();
  const detailed = String(pfc?.detailed ?? '').toUpperCase();
  if (detailed.includes('CREDIT_CARD_PAYMENT')) return true;
  if (primary === 'LOAN_PAYMENTS' && detailed.includes('CREDIT_CARD')) return true;
  const legacy = tx.category;
  if (Array.isArray(legacy)) {
    const joined = legacy.map((c) => String(c)).join(' ').toUpperCase();
    if (joined.includes('CREDIT CARD PAYMENT')) return true;
  }
  return false;
}

export type TxKind = 'charge' | 'refund' | 'payment' | 'cashback' | 'fund_charge' | 'transfer' | 'income' | 'charity';

// Classification order matters: the internal-transfer check comes FIRST,
// then payment and cashback are checked BEFORE the sign-based refund
// fallback, because both surface as negative Plaid amounts. A real
// refund (e.g. an Amazon return) matches none of these patterns and
// keeps kind='refund'.
export function classifyKind(
  tx: Record<string, unknown>,
  merchantName: string,
  signedAmountCents: number,
  accountType?: string,
): TxKind {
  const name = String(merchantName ?? '');
  if (TRANSFER_PATTERN.test(name)) return 'transfer';
  // Deposit and payment phrases are checked BEFORE the sign-based
  // refund fallback, and only for negative amounts (a positive
  // DEPOSIT, e.g. a security-deposit charge, must not become income).
  if (signedAmountCents < 0 && DEPOSIT_PATTERN.test(name)) return 'income';
  if (plaidCategoryIndicatesCardPayment(tx)) return 'payment';
  if (PAYMENT_PATTERN.test(name)) return 'payment';
  if (CASHBACK_PATTERN.test(name)) return 'cashback';
  // P1-NEW1 (Nov 8, 2026): charity auto-detect, money-out only, after
  // payment/cashback so a "PAYMENT - THANK YOU" from a charity-named
  // merchant still counts as a payment, not a gift.
  if (signedAmountCents > 0 && CHARITY_PATTERN.test(name)) return 'charity';
  // A depository-account inflow with no refund signal is money
  // received, not a purchase refund. A genuine debit-card return is
  // the exception: the admin reclassifies that one row to 'refund'
  // in the UI (reclassify_transaction). accountType is Plaid's
  // acc.type ('depository' | 'credit' | ...); undefined keeps the
  // old behaviour for callers that carry no account (Gmail/CSV).
  if (signedAmountCents < 0 && accountType === 'depository') return 'income';
  return signedAmountCents < 0 ? 'refund' : 'charge';
}

// Merchant-name-only classification, for sources (e.g. Gmail alerts)
// that carry no Plaid category object.
export function classifyMerchantOnly(merchantName: string, signedAmountCents: number, accountType?: string): TxKind {
  return classifyKind({}, merchantName, signedAmountCents, accountType);
}

// Constant-time byte comparison: no early exit, no .every() shortcut.
// Returns false on length mismatch after still scanning the longer input
// length worth of work is NOT possible without both buffers, so length
// mismatch returns false immediately — lengths of HMAC hex strings are
// not secret (both are fixed 64 hex chars for SHA-256 when well-formed);
// the timing-critical path is the byte loop below.
export function timingSafeEqualHex(aHex: string, bHex: string): boolean {
  if (aHex.length !== bHex.length) return false;
  let diff = 0;
  for (let i = 0; i < aHex.length; i++) {
    diff |= aHex.charCodeAt(i) ^ bHex.charCodeAt(i);
  }
  return diff === 0;
}

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// --- Merchant rules (build 30, Nov 15, 2026) ---
// Household-scoped teachable renames: `merchant_rules` maps a
// normalized pattern to a clean display name plus an optional fixed
// kind. Rules apply at ingestion (before the hash is computed, so a
// bank row and its email alert hash identically) and via the
// rename/apply RPCs in supabase/merchant-rules.sql (which recompute
// dedupe_hash for renamed rows). Matching is deliberately strict —
// normalized exact / includes / squashed-exact only, never fuzzy:
// (Build 34: 'prefix' became 'includes'; build 39: Includes
// squashes BOTH sides before the substring check — case- and
// whitespace-insensitive, letters in order.)
// a rule must never rename a merchant it was not taught.
//   key    = UPPER, trimmed, whitespace collapsed, leading
//            non-alphanumeric bank artifacts stripped ('=TENYAD...'
//            -> 'TENYAD...').
//   squash = key with ALL non-alphanumerics removed, so
//            'TENYADKALLAHGEMACH' matches 'TENYAD KALLAH GEMACH'.
// Priority: exact-key match beats includes, which beats squash-exact;
// within a tier the longest pattern wins, then the earliest rule.
// Display names are stored UPPER, like every transactions.merchant
// value; clients title-case on render (as they already do).
// Fixed kinds: a rule's fixed kind auto-applies to matching NEW
// transactions (and to rows a rename applies to) — EXCEPT the sign
// guard below: a money-out kind (charge/charity/fund_charge) never
// overrides a money-in (negative) row, and a money-in kind
// (refund/payment/cashback/income) never overrides a money-out
// row. A refund of a gift keeps the classifier's kind. 'transfer'
// applies to either sign.

export function merchantRuleKey(name: string): string {
  return String(name ?? '')
    .toUpperCase()
    .trim()
    .replace(/\s+/g, ' ')
    .replace(/^[^A-Z0-9]+/, '');
}

export function merchantRuleSquash(name: string): string {
  return merchantRuleKey(name).replace(/[^A-Z0-9]/g, '');
}

export type MerchantRule = {
  pattern_key: string;
  pattern_squash: string;
  match_type: 'exact' | 'includes' | 'prefix';
  display_name: string;
  fixed_kind?: string | null;
  created_at?: string;
};

const MONEY_OUT_KINDS = new Set(['charge', 'charity', 'fund_charge']);
const MONEY_IN_KINDS = new Set(['refund', 'payment', 'cashback', 'income']);

export function fixedKindApplies(fixedKind: string | null | undefined, amountCents: number): boolean {
  if (!fixedKind) return false;
  if (amountCents > 0 && MONEY_IN_KINDS.has(fixedKind)) return false;
  if (amountCents < 0 && MONEY_OUT_KINDS.has(fixedKind)) return false;
  return true;
}

export function matchMerchantRule(
  rules: MerchantRule[],
  merchant: string,
): MerchantRule | null {
  const key = merchantRuleKey(merchant);
  const squash = merchantRuleSquash(merchant);
  if (!key) return null;
  let best: MerchantRule | null = null;
  let bestTier = 99;
  let bestLen = -1;
  for (const r of rules ?? []) {
    const pk = merchantRuleKey(r.pattern_key);
    if (!pk) continue;
    let tier = -1;
    if (pk === key) tier = 0;
    else if ((r.match_type === 'includes' || r.match_type === 'prefix') && squash.includes(merchantRuleSquash(pk))) tier = 1;
    else if (r.pattern_squash && merchantRuleSquash(r.pattern_key) === squash) tier = 2;
    else if (merchantRuleSquash(r.pattern_key) === squash) tier = 2;
    if (tier < 0) continue;
    if (tier < bestTier || (tier === bestTier && pk.length > bestLen)) {
      best = r;
      bestTier = tier;
      bestLen = pk.length;
    }
  }
  return best;
}

// Apply the best matching rule to a merchant name. Returns the
// display merchant (normalized UPPER) and a kind override (null
// when the rule has no fixed kind or the sign guard blocks it).
export function applyMerchantRuleToMerchant(
  rules: MerchantRule[],
  merchant: string,
  amountCents: number,
): { merchant: string; kindOverride: string | null } {
  const rule = matchMerchantRule(rules, merchant);
  if (!rule) return { merchant: normalizeMerchant(merchant), kindOverride: null };
  const kindOverride = fixedKindApplies(rule.fixed_kind ?? null, amountCents)
    ? String(rule.fixed_kind)
    : null;
  return { merchant: normalizeMerchant(rule.display_name), kindOverride };
}

// Best-effort rule load for one household (ingestion path). Never
// throws: on any error the caller proceeds with no rules, i.e. the
// pre-rules behaviour.
export async function loadMerchantRules(
  supabaseAdmin: SupaAdmin,
  householdId: string,
): Promise<MerchantRule[]> {
  try {
    const { data, error } = await supabaseAdmin.from('merchant_rules')
      .select('pattern_key, pattern_squash, match_type, display_name, fixed_kind, created_at')
      .eq('household_id', householdId)
      .order('created_at', { ascending: true });
    if (error || !data) return [];
    return data as MerchantRule[];
  } catch {
    return [];
  }
}

// --- Bank+Email auto-merge eligibility (build 30, task I) ---
// The approved provisional-merge take: a bank row and an email row
// for the SAME purchase merge automatically — bank row kept, email
// row merged away, no manual review. Conservative by design: ALL
// of these must hold, or the pair stays for manual review.
//   * bank source 'plaid', email source 'amex_alert' (NEVER two
//     bank rows, NEVER two email rows);
//   * same household, same signed amount, same kind;
//   * dates within 2 days (either direction);
//   * card suffix equal, or either side '0000' (unknown, not a
//     different card — the same rule as plaid-sync step 3b);
//   * neither row already excluded;
//   * merchant names related: identical, one contains the other,
//     a confirmed alias pair, or both map to the same rule display
//     name (the merchant-string gap that used to defeat the hash);
//   * NEVER a TOIREMORG pair (owner ruling Nov 3: the $2 bank
//     "TOIREMORG" and $2 email "TOIREMORG CHARITY" rows are TWO
//     real gifts, not a duplicate) — checked on both spellings.
// `resolvedPair` is true when a duplicate_candidates row already
// links the pair in ANY status: a pair the owner already resolved
// as Separate is never auto-merged, and an already-merged pair is
// never merged twice.

export function isToiremorgMerchant(merchant: string): boolean {
  return normalizeMerchant(merchant).includes('TOIREMORG');
}

export type MergeRow = {
  id: string;
  household_id?: string;
  merchant: string;
  source: string;
  date: string;
  amount_cents: number;
  card_suffix: string;
  kind?: string;
  excluded?: boolean | null;
  state?: string | null;
};

export function daysBetweenDates(a: string, b: string): number | null {
  const ta = Date.parse(`${a}T00:00:00Z`);
  const tb = Date.parse(`${b}T00:00:00Z`);
  if (!Number.isFinite(ta) || !Number.isFinite(tb)) return null;
  return Math.abs(Math.round((ta - tb) / 86400000));
}

export function addDaysToDate(dateStr: string, days: number): string {
  const t = Date.parse(`${dateStr}T00:00:00Z`);
  if (!Number.isFinite(t)) return dateStr;
  return new Date(t + days * 86400000).toISOString().slice(0, 10);
}

export function autoMergeEligible(
  bankRow: MergeRow,
  emailRow: MergeRow,
  opts: {
    aliases?: Array<{ name_a: string; name_b: string }>;
    rules?: MerchantRule[];
    resolvedPair?: boolean;
  } = {},
): { eligible: boolean; reason: string } {
  if (bankRow.source !== 'plaid') return { eligible: false, reason: 'bank row is not plaid' };
  if (emailRow.source !== 'amex_alert') return { eligible: false, reason: 'email row is not amex_alert' };
  if (opts.resolvedPair) return { eligible: false, reason: 'pair already resolved' };
  if (bankRow.household_id && emailRow.household_id && bankRow.household_id !== emailRow.household_id) {
    return { eligible: false, reason: 'different households' };
  }
  if (bankRow.amount_cents !== emailRow.amount_cents) return { eligible: false, reason: 'amount differs' };
  if (bankRow.kind && emailRow.kind && bankRow.kind !== emailRow.kind) {
    return { eligible: false, reason: 'kind differs' };
  }
  const gap = daysBetweenDates(bankRow.date, emailRow.date);
  if (gap === null) return { eligible: false, reason: 'bad date' };
  if (gap > 2) return { eligible: false, reason: 'dates more than 2 days apart' };
  const bs = String(bankRow.card_suffix ?? '0000');
  const es = String(emailRow.card_suffix ?? '0000');
  if (bs !== es && bs !== '0000' && es !== '0000') {
    return { eligible: false, reason: 'card suffix differs' };
  }
  if (bankRow.excluded === true || bankRow.state === 'excluded') {
    return { eligible: false, reason: 'bank row excluded' };
  }
  if (emailRow.excluded === true || emailRow.state === 'excluded') {
    return { eligible: false, reason: 'email row excluded' };
  }
  if (isToiremorgMerchant(bankRow.merchant) || isToiremorgMerchant(emailRow.merchant)) {
    return { eligible: false, reason: 'toiremorg pair never auto-merges' };
  }
  const nb = normalizeMerchant(bankRow.merchant);
  const ne = normalizeMerchant(emailRow.merchant);
  let related = nb === ne || merchantsRelated(bankRow.merchant, emailRow.merchant);
  if (!related) {
    for (const a of opts.aliases ?? []) {
      const x = normalizeMerchant(a.name_a);
      const y = normalizeMerchant(a.name_b);
      if ((x === nb && y === ne) || (x === ne && y === nb)) { related = true; break; }
    }
  }
  if (!related && opts.rules) {
    const rb = matchMerchantRule(opts.rules, bankRow.merchant);
    const re = matchMerchantRule(opts.rules, emailRow.merchant);
    if (rb && re && normalizeMerchant(rb.display_name) === normalizeMerchant(re.display_name)) related = true;
  }
  if (!related) return { eligible: false, reason: 'merchants not related' };
  return { eligible: true, reason: 'ok' };
}

// Bank-first guard, widened (build 30): when an email alert
// arrives, skip the insert when a Plaid row already covers the
// purchase — same amount + same card (or unknown suffix) + date
// within 2 days + merchant-related (exact hash is the special case
// where all of those are equalities). Returns the covering bank row
// or null. Pure-DB-query half lives here so the callers
// (gmail-poll, ingest-amex-alert) share it; the TOIREMORG and
// kind checks run through autoMergeEligible, so a TOIREMORG alert
// is never swallowed by this guard.
export async function findCoveringBankRow(
  supabaseAdmin: SupaAdmin,
  householdId: string,
  alert: { merchant: string; date: string; amount_cents: number; card_suffix: string; kind?: string },
  opts: {
    aliases?: Array<{ name_a: string; name_b: string }>;
    rules?: MerchantRule[];
  } = {},
): Promise<MergeRow | null> {
  try {
    const { data: rows } = await supabaseAdmin.from('transactions')
      .select('id, household_id, merchant, source, date, amount_cents, card_suffix, kind, excluded, state')
      .eq('household_id', householdId)
      .eq('source', 'plaid')
      .eq('amount_cents', alert.amount_cents)
      .gte('date', addDaysToDate(alert.date, -2))
      .lte('date', addDaysToDate(alert.date, 2))
      .limit(20);
    for (const row of rows ?? []) {
      const bank = row as MergeRow;
      const emailLike: MergeRow = {
        id: '', household_id: householdId, merchant: alert.merchant,
        source: 'amex_alert', date: alert.date, amount_cents: alert.amount_cents,
        card_suffix: alert.card_suffix, kind: alert.kind,
      };
      if (autoMergeEligible(bank, emailLike, opts).eligible) return bank;
    }
    return null;
  } catch {
    return null;
  }
}

// --- Lookalike detection (Nov 3 Amazon case) ---
// Exact-hash and provider-ID merges already ran before this is used.
// A lookalike is same household + date + signed amount + card suffix
// + merchant names that are related (one contains the other, or a
// confirmed alias exists). Lookalikes NEVER auto-merge: they create
// a duplicate_candidates row for admin review. A pair that already
// has a candidate row (any status) is never flagged again.
// deno-lint-ignore no-explicit-any
type SupaAdmin = { from: (table: string) => any };

export function merchantsRelated(a: string, b: string): boolean {
  const na = normalizeMerchant(a);
  const nb = normalizeMerchant(b);
  if (!na || !nb || na === nb) return false;
  if (na.length < 4 || nb.length < 4) return false;
  return na.includes(nb) || nb.includes(na);
}

export type LookalikeRow = {
  id: string;
  merchant: string;
  source: string;
  created_at?: string;
};

// Prefer the Plaid row as canonical: it receives posted updates.
// Otherwise the earlier-created row is canonical.
export function pickCanonicalPair(
  existing: LookalikeRow,
  incoming: LookalikeRow,
): [LookalikeRow, LookalikeRow] {
  if (incoming.source === 'plaid' && existing.source !== 'plaid') return [incoming, existing];
  if (existing.source === 'plaid' && incoming.source !== 'plaid') return [existing, incoming];
  const e = existing.created_at ?? '';
  const i = incoming.created_at ?? '';
  return e <= i ? [existing, incoming] : [incoming, existing];
}

// Best-effort lookalike flagging. Never throws and never fails the
// sync: if the review tables do not exist yet (SQL not applied),
// the queries fail inside try/catch and the sync continues.
export async function flagLookalikes(
  supabaseAdmin: SupaAdmin,
  householdId: string,
  newRow: LookalikeRow & { date: string; amount_cents: number; card_suffix: string },
): Promise<number> {
  try {
    const { data: rows } = await supabaseAdmin.from('transactions')
      .select('id, merchant, source, created_at, excluded, state')
      .eq('household_id', householdId)
      .eq('date', newRow.date)
      .eq('amount_cents', newRow.amount_cents)
      .eq('card_suffix', newRow.card_suffix)
      .neq('id', newRow.id)
      .limit(20);
    let aliases: Array<{ name_a: string; name_b: string }> = [];
    try {
      const { data } = await supabaseAdmin.from('merchant_aliases')
        .select('name_a, name_b').eq('household_id', householdId);
      aliases = data ?? [];
    } catch {
      aliases = [];
    }
    // Build 30: merchant rules are also relatedness evidence — two
    // spellings the household taught to one display name are the
    // same merchant for review, same as a confirmed alias pair.
    let rules: MerchantRule[] = [];
    try {
      rules = await loadMerchantRules(supabaseAdmin, householdId);
    } catch {
      rules = [];
    }
    const aliasSet = new Set<string>();
    for (const a of aliases) {
      const x = normalizeMerchant(a.name_a);
      const y = normalizeMerchant(a.name_b);
      aliasSet.add(`${x}|${y}`);
      aliasSet.add(`${y}|${x}`);
    }
    const related = (m1: string, m2: string): boolean => {
      if (merchantsRelated(m1, m2)) return true;
      if (aliasSet.has(`${normalizeMerchant(m1)}|${normalizeMerchant(m2)}`)) return true;
      const r1 = matchMerchantRule(rules, m1);
      const r2 = matchMerchantRule(rules, m2);
      return !!r1 && !!r2 && normalizeMerchant(r1.display_name) === normalizeMerchant(r2.display_name);
    };
    let flagged = 0;
    for (const r of rows ?? []) {
      if (flagged >= 5) break;
      if (r.excluded === true || r.state === 'excluded') continue;
      if (!related(newRow.merchant, r.merchant)) continue;
      const [canonical, duplicate] = pickCanonicalPair(
        { id: r.id, merchant: r.merchant, source: r.source, created_at: r.created_at },
        newRow,
      );
      try {
        const { data: prior } = await supabaseAdmin.from('duplicate_candidates')
          .select('id').eq('household_id', householdId)
          .or(`and(canonical_transaction_id.eq.${canonical.id},duplicate_transaction_id.eq.${duplicate.id}),and(canonical_transaction_id.eq.${duplicate.id},duplicate_transaction_id.eq.${canonical.id})`)
          .limit(1).maybeSingle();
        if (prior) continue;
        const { error } = await supabaseAdmin.from('duplicate_candidates').insert({
          household_id: householdId,
          canonical_transaction_id: canonical.id,
          duplicate_transaction_id: duplicate.id,
          reason: 'lookalike',
          merchant_a: normalizeMerchant(canonical.merchant),
          merchant_b: normalizeMerchant(duplicate.merchant),
        });
        if (!error) flagged += 1;
      } catch {
        continue;
      }
    }
    return flagged;
  } catch {
    return 0;
  }
}
