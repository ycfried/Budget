// gmail-parse.ts — pure helpers for the per-user Gmail OAuth path.
// Shared by gmail-poll (Deno) and test/gmail.test.mjs (Node type-strip).
// Erasable TypeScript only: no enums, namespaces, or parameter
// properties, so Node can import this file directly.
//
// These helpers DELIBERATELY mirror the existing parsers instead of
// inventing new ones:
//   * authResultsPass is the exact rule from ingest-amex-alert (and the
//     INGEST_CONTRACT): americanexpress.com + dkim=pass + spf=pass.
//     FLAGGED AMBIGUITY (carried forward, not resolved here): requiring
//     BOTH DKIM and SPF means a legitimate alert that fails SPF on some
//     path quarantines instead of ingesting. Fail-closed was chosen over
//     guessing; relaxing it is an owner decision after a real alert's
//     headers are inspected.
//   * parseAmexAlertText mirrors integrations/gmail-apps-script.gs
//     parseAmexAlert: first $ amount in body else subject+body, merchant
//     via "at NAME" else the subject tail, card suffix via "ending in /
//     bullet / xx / *" else '0000'. Amounts must be positive: the email
//     path ingests Large Purchase alerts (charges) only. Refunds,
//     cash-back credits, and card payments arriving by email are OUT OF
//     SCOPE here — Plaid is authoritative for those (spec FINAL: email
//     is PROVISIONAL only, cash-back is NOT a refund, payments are NOT
//     refunds). An alert that does not parse returns null and the
//     caller quarantines it (disposition 'unparseable'); nothing is
//     guessed into a transaction.

export function authResultsPass(authResults: string): boolean {
  const h = String(authResults ?? '').toLowerCase();
  return h.includes('americanexpress.com') && h.includes('dkim=pass') && h.includes('spf=pass');
}

// The Amex alert query for the OAuth path. Same scope as the Apps
// Script path (americanexpress.com Large Purchase alerts); NO label
// logic — dedupe lives server-side in processed_email_ids, so the
// gmail.modify scope is never needed. Tightening this against a real
// alert is an owner step after first proof (see HANDOFF checklist).
export function buildAlertQuery(): string {
  return 'from:(americanexpress.com) subject:"Large Purchase"';
}

export type GmailHeader = { name: string; value: string };

export function headerValue(headers: GmailHeader[] | undefined | null, name: string): string {
  const wanted = String(name ?? '').toLowerCase();
  for (const h of headers ?? []) {
    if (String(h?.name ?? '').toLowerCase() === wanted) return String(h?.value ?? '');
  }
  return '';
}

function decodeBase64Url(data: string): string {
  const b64 = String(data ?? '').replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  const bin = atob(padded);
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

export type GmailPayload = {
  mimeType?: string;
  body?: { data?: string };
  parts?: GmailPayload[];
};

// Walk a Gmail message payload and return the text/plain body, falling
// back to any part that carries data. Returns '' when nothing decodes.
export function extractPlainText(payload: GmailPayload | undefined | null): string {
  if (!payload) return '';
  if (payload.body?.data) {
    try {
      const text = decodeBase64Url(payload.body.data);
      if (text.trim()) return text;
    } catch {
      // fall through to parts
    }
  }
  for (const part of payload.parts ?? []) {
    const text = extractPlainText(part);
    if (text.trim()) return text;
  }
  return '';
}

// Gmail internalDate (epoch millis, UTC) -> YYYY-MM-DD in
// America/New_York, the household timezone. Uses Intl, available in
// both Deno and Node; no manual offset math.
export function gmailDateToNY(internalDateMs: string | number): string {
  const ms = Number(internalDateMs);
  if (!Number.isFinite(ms)) return '';
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/New_York',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date(ms));
  const get = (t: string): string => parts.find((p) => p.type === t)?.value ?? '';
  const y = get('year');
  const m = get('month');
  const d = get('day');
  if (!y || !m || !d) return '';
  return `${y}-${m}-${d}`;
}

export type ParsedAlert = {
  amountCents: number;
  merchant: string;
  cardSuffix: string;
  date: string;
};

// Mirror of the Apps Script parser. `date` must already be YYYY-MM-DD
// (from gmailDateToNY); anything else fails closed (null).
export function parseAmexAlertText(input: {
  subject: string;
  body: string;
  date: string;
}): ParsedAlert | null {
  const subject = String(input?.subject ?? '');
  const text = String(input?.body ?? '');
  const date = String(input?.date ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  const combined = subject + '\n' + text;
  const amountMatch = text.match(/\$([\d,]+\.\d{2})/) || combined.match(/\$([\d,]+\.\d{2})/);
  if (!amountMatch) return null;
  const amountCents = Math.round(parseFloat(amountMatch[1].replace(/,/g, '')) * 100);
  if (!amountCents || amountCents <= 0) return null;
  let merchant: string | null = null;
  const atMatch = combined.match(/\bat\s+([A-Za-z0-9][A-Za-z0-9 .&'\-]{1,60})/i);
  if (atMatch) merchant = atMatch[1].trim().replace(/\s+/g, ' ');
  if (!merchant) {
    const subjMatch = subject.match(/[:\-–—]\s*(.+)$/);
    if (subjMatch) merchant = subjMatch[1].trim();
  }
  if (!merchant) return null;
  const suffixMatch = combined.match(/(?:ending in|•|xx|\*)\s?(\d{4})/i);
  const cardSuffix = suffixMatch ? suffixMatch[1] : '0000';
  return { amountCents, merchant, cardSuffix, date };
}

// Server-side dedupe: message ids not already in the processed set.
// Pure helper; the DB unique constraint is the backstop, not this.
export function filterNewMessageIds(allIds: string[], processedIds: string[]): string[] {
  const seen = new Set(processedIds ?? []);
  return (allIds ?? []).filter((id) => id && !seen.has(id));
}
