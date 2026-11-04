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
export const PAYMENT_PATTERN = /MOBILE PAYMENT|PAYMENT - THANK YOU|CARD PAYMENT/i;
export const CASHBACK_PATTERN = /CASH BACK|CASHBACK|REWARD/i;

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

export type TxKind = 'charge' | 'refund' | 'payment' | 'cashback' | 'fund_charge' | 'transfer';

// Classification order matters: the internal-transfer check comes FIRST,
// then payment and cashback are checked BEFORE the sign-based refund
// fallback, because both surface as negative Plaid amounts. A real
// refund (e.g. an Amazon return) matches none of these patterns and
// keeps kind='refund'.
export function classifyKind(
  tx: Record<string, unknown>,
  merchantName: string,
  signedAmountCents: number,
): TxKind {
  const name = String(merchantName ?? '');
  if (TRANSFER_PATTERN.test(name)) return 'transfer';
  if (plaidCategoryIndicatesCardPayment(tx)) return 'payment';
  if (PAYMENT_PATTERN.test(name)) return 'payment';
  if (CASHBACK_PATTERN.test(name)) return 'cashback';
  return signedAmountCents < 0 ? 'refund' : 'charge';
}

// Merchant-name-only classification, for sources (e.g. Gmail alerts)
// that carry no Plaid category object.
export function classifyMerchantOnly(merchantName: string, signedAmountCents: number): TxKind {
  return classifyKind({}, merchantName, signedAmountCents);
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
    const aliasSet = new Set<string>();
    for (const a of aliases) {
      const x = normalizeMerchant(a.name_a);
      const y = normalizeMerchant(a.name_b);
      aliasSet.add(`${x}|${y}`);
      aliasSet.add(`${y}|${x}`);
    }
    const related = (m1: string, m2: string): boolean => {
      if (merchantsRelated(m1, m2)) return true;
      return aliasSet.has(`${normalizeMerchant(m1)}|${normalizeMerchant(m2)}`);
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
