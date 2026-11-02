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

export type TxKind = 'charge' | 'refund' | 'payment' | 'cashback' | 'fund_charge';

// Classification order matters: payment and cashback are checked BEFORE
// the sign-based refund fallback, because both surface as negative
// Plaid amounts. A real refund (e.g. an Amazon return) matches neither
// pattern and keeps kind='refund'.
export function classifyKind(
  tx: Record<string, unknown>,
  merchantName: string,
  signedAmountCents: number,
): TxKind {
  const name = String(merchantName ?? '');
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
