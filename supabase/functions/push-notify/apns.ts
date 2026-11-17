// apns.ts — pure helpers for push-notify (alongside index.ts).
//
// No Supabase import and no Deno-specific APIs except WebCrypto
// (available in Deno and Node 18+), so `node --test` can import this
// file directly. The tested code IS the deployed code.
//
// Contents:
//   - base64url encode + PEM (.p8) decoding
//   - APNs ES256 JWT signing (cached ~50 min)
//   - notification copy builders (Title Case titles, plain bodies —
//     never name the source: no "from email" / "from bank" / "from Amex")
//   - dedupe-key builders
//   - money / date formatting

// ---------------------------------------------------------------------------
// base64url + PEM
// ---------------------------------------------------------------------------

export function base64urlEncode(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function base64urlDecodeToBytes(s: string): Uint8Array {
  const normalized = s.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/// Strip the PEM header/footer and base64-decode a .p8 (PKCS#8) key to DER.
export function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, '')
    .replace(/-----END [A-Z ]+-----/g, '')
    .replace(/\s+/g, '');
  if (!body) throw new Error('apns: empty key');
  return base64urlDecodeToBytes(body);
}

// ---------------------------------------------------------------------------
// APNs ES256 JWT (valid 1 hour; cached and re-signed on expiry)
// ---------------------------------------------------------------------------

let cachedJwt = '';
let cachedJwtUntil = 0;

export interface ApnsCredentials {
  keyPem: string;
  keyId: string;
  teamId: string;
}

export async function signApnsJwt(creds: ApnsCredentials, nowSeconds?: number): Promise<string> {
  const now = nowSeconds ?? Math.floor(Date.now() / 1000);
  if (cachedJwt && now < cachedJwtUntil) return cachedJwt;
  const der = pemToDer(creds.keyPem);
  const key = await crypto.subtle.importKey(
    'pkcs8',
    der.buffer as ArrayBuffer,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const header = base64urlEncode(new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: creds.keyId, typ: 'JWT' })));
  const payload = base64urlEncode(new TextEncoder().encode(JSON.stringify({ iss: creds.teamId, iat: now })));
  const data = new TextEncoder().encode(`${header}.${payload}`);
  // WebCrypto ECDSA returns the raw r||s concatenation (64 bytes),
  // which is exactly the JWS signature format — no DER conversion.
  const signature = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, data));
  cachedJwt = `${header}.${payload}.${base64urlEncode(signature)}`;
  cachedJwtUntil = now + 50 * 60; // re-sign 10 minutes before expiry
  return cachedJwt;
}

export function clearApnsJwtCache(): void {
  cachedJwt = '';
  cachedJwtUntil = 0;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

export function formatMoney(cents: number): string {
  return (cents / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' });
}

/// "2026-10-25" -> "Oct 25, 2026" (UTC, so the date never shifts).
export function formatWeekDate(isoDate: string): string {
  return new Date(`${isoDate}T00:00:00Z`).toLocaleDateString('en-US', {
    month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC',
  });
}

/// "2026-10" -> "October".
export function formatMonthLabel(yearMonth: string): string {
  return new Date(`${yearMonth}-01T00:00:00Z`).toLocaleDateString('en-US', {
    month: 'long', timeZone: 'UTC',
  });
}

/// The Sunday starting the current week, in America/New_York.
/// (The app's weeks are Sunday-start, NY time — same as week-close's
/// weekStartOf. Used only as a fallback dedupe key when compute-week
/// cannot be reached.)
export function currentWeekStartNY(now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(now);
  const value = (type: string) => parts.find((p) => p.type === type)?.value ?? '0';
  const date = new Date(Date.UTC(Number(value('year')), Number(value('month')) - 1, Number(value('day'))));
  date.setUTCDate(date.getUTCDate() - date.getUTCDay());
  return date.toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------------
// Copy builders — one per notification type.
// ---------------------------------------------------------------------------

export interface CopyInput {
  weekStarts?: string[];
  surplusCents?: number;
  fundName?: string;
  availableCents?: number | null;
  overCents?: number;
  count?: number;
  totalCents?: number;
  merchant?: string;
  amountCents?: number;
  monthLabel?: string;
  name?: string;
  note?: string;
  fundName?: string;
  addedCents?: number;
  newAllowanceCents?: number;
}

export function buildCopy(type: string, input: CopyInput): { title: string; body: string } {
  switch (type) {
    case 'week_closed': {
      const starts = input.weekStarts ?? [];
      const surplus = input.surplusCents ?? 0;
      const fund = input.fundName ?? 'Extra Fund';
      const surplusPart = surplus > 0 ? ` ${formatMoney(surplus)} left went to ${fund}.` : '';
      if (starts.length > 1) {
        return { title: 'Week Closed', body: `${starts.length} weeks are closed.${surplusPart}` };
      }
      const label = starts.length === 1 ? formatWeekDate(starts[0]) : 'This week';
      return { title: 'Week Closed', body: `Week of ${label} is closed.${surplusPart}` };
    }
    case 'new_week': {
      const available = input.availableCents;
      return {
        title: 'New Week',
        body: available != null
          ? `A new week started. ${formatMoney(available)} to spend this week.`
          : 'A new week started.',
      };
    }
    case 'over_budget':
      return { title: 'Over Budget', body: `You're over budget this week. ${formatMoney(input.overCents ?? 0)} over.` };
    case 'new_purchase': {
      const count = input.count ?? 1;
      if (count === 1) {
        return { title: 'New Purchase', body: `${formatMoney(input.amountCents ?? 0)} at ${input.merchant ?? 'a store'}.` };
      }
      return { title: 'New Purchase', body: `${count} new purchases, ${formatMoney(input.totalCents ?? 0)} in total.` };
    }
    case 'new_income': {
      const count = input.count ?? 1;
      if (count === 1) {
        return { title: 'New Income', body: `${formatMoney(input.amountCents ?? 0)} from ${input.merchant ?? 'a payer'}.` };
      }
      return { title: 'New Income', body: `${count} new incomes, ${formatMoney(input.totalCents ?? 0)} in total.` };
    }
    case 'new_charity': {
      const count = input.count ?? 1;
      if (count === 1) {
        return { title: 'Charity Gift', body: `${formatMoney(input.amountCents ?? 0)} to ${input.merchant ?? 'charity'}.` };
      }
      return { title: 'Charity Gift', body: `${count} charity gifts, ${formatMoney(input.totalCents ?? 0)} in total.` };
    }
    case 'monthly_statement':
      return { title: 'Monthly Statement', body: `Your ${input.monthLabel ?? 'monthly'} statement is ready.` };
    case 'member_joined':
      return { title: 'Member Joined', body: `${input.name ?? 'A member'} joined the household.` };
    case 'member_left':
      return { title: 'Member Left', body: `${input.name ?? 'A member'} left the household.` };
    case 'gmail_expiring':
      return {
        title: 'Gmail Connection Expiring',
        body: 'Your Gmail connection needs attention. Reconnect it in Settings so purchase alerts keep coming.',
      };
    case 'fund_request': {
      const fund = input.fundName ?? 'Extra Fund';
      const ask = `${input.name ?? 'A member'} asked for ${formatMoney(input.amountCents ?? 0)} from ${fund}.`;
      if (!input.note) {
        return { title: 'Fund Request Waiting', body: `${ask} Tap to review.` };
      }
      const note = input.note;
      const quoted = `"${note}${/[.!?]$/.test(note) ? '' : '.'}"`;
      return { title: 'Fund Request Waiting', body: `${ask} ${quoted}` };
    }
    case 'large_purchase': {
      const count = input.count ?? 1;
      if (count === 1) {
        return { title: 'Large Purchase', body: `${formatMoney(input.amountCents ?? 0)} at ${input.merchant ?? 'a store'} — a large purchase.` };
      }
      return { title: 'Large Purchase', body: `${count} large purchases, ${formatMoney(input.totalCents ?? 0)} in total.` };
    }
    case 'bank_broken':
      return {
        title: 'Bank Connection Broken',
        body: 'Your bank connection needs attention. Reconnect it in Settings to keep purchases syncing.',
      };
    case 'budget_increased':
      return {
        title: 'Budget Increased',
        body: `Budget increased by ${formatMoney(input.addedCents ?? 0)}. Weekly budget is now ${formatMoney(input.newAllowanceCents ?? 0)}.`,
      };
    default:
      throw new Error(`apns: unknown notification type ${type}`);
  }
}

// ---------------------------------------------------------------------------
// Dedupe keys — the event identity, never the row id (plan §1.1).
// ---------------------------------------------------------------------------

export function dedupeKey(type: string, parts: string[]): string {
  return [type, ...parts].join(':');
}

/// The per-kind toggle column for a new-transaction kind.
export function toggleColumnForKind(kind: string): string {
  if (kind === 'charge') return 'new_purchase';
  if (kind === 'income') return 'new_income';
  if (kind === 'charity') return 'new_charity';
  throw new Error(`apns: unknown transaction kind ${kind}`);
}

/// The push-notify type for a new-transaction kind.
export function notifyTypeForKind(kind: string): string {
  if (kind === 'charge') return 'new_purchase';
  if (kind === 'income') return 'new_income';
  if (kind === 'charity') return 'new_charity';
  throw new Error(`apns: unknown transaction kind ${kind}`);
}

/// The dedupe-key prefix for a new-transaction kind.
export function dedupePrefixForKind(kind: string): string {
  if (kind === 'charge') return 'purchase';
  if (kind === 'income') return 'income';
  if (kind === 'charity') return 'charity';
  throw new Error(`apns: unknown transaction kind ${kind}`);
}

/// The deep-link screen for a notification type.
export function screenForType(type: string): string {
  switch (type) {
    case 'week_closed':
    case 'new_week':
    case 'over_budget':
      return 'week';
    case 'new_purchase':
    case 'new_income':
    case 'new_charity':
    case 'large_purchase':
      return 'purchases';
    case 'monthly_statement':
      return 'statement';
    case 'member_joined':
    case 'member_left':
    case 'gmail_expiring':
    case 'bank_broken':
      return 'settings';
    case 'fund_request':
      return 'money';
    default:
      return 'week';
  }
}
