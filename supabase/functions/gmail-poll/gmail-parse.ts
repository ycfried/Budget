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
//
// Multi-bank parsing (Nov 26, 2026) lives below parseAmexAlertText:
// parseBankAlertText + identifyBankAlert + classifyBankAlert, built
// from the bank-alert research report. Amex is untouched by it.

export function authResultsPass(authResults: string): boolean {
  return authResultsPassFor('amex_alert', authResults);
}

// Per-bank Authentication-Results rule. Same shape as the Amex
// rule: the bank's own domain + dkim=pass + spf=pass. Fail-closed
// (see the header note): a legitimate alert that fails SPF on some
// path quarantines instead of ingesting. The Chase domain list is
// the bank's own sender domains — chase.com and jpmorganchase.com
// — NOT a guess at the alert format.
export function authResultsPassFor(source: string, authResults: string): boolean {
  const h = String(authResults ?? '').toLowerCase();
  const domains: Record<string, string[]> = {
    amex_alert: ['americanexpress.com'],
    chase_alert: ['chase.com', 'jpmorganchase.com'],
  };
  const wanted = domains[source];
  if (!wanted) return false;
  return wanted.some((d) => h.includes(d)) && h.includes('dkim=pass') && h.includes('spf=pass');
}

// The alert query for the OAuth path. NO label logic — dedupe
// lives server-side in processed_email_ids, so the gmail.modify
// scope is never needed.
// Scope (owner, Nov 26, 2026): BANK ALERT emails only — the
// allowlisted bank alert senders below — NOT general inbox
// reading. Two clauses, OR-ed with Gmail's { } grouping:
//   * Amex keeps its subject restriction: the bare phrase also
//     matched Amex STATEMENT emails, which mention Large Purchase
//     alerts in the body (owner, Nov 2, 2026: the first poll's 2
//     matches were statements, correctly left unparsed). Real
//     charge alerts carry "Large Purchase" in the subject ("Large
//     Purchase Approved" on the real Nov 2 alert); statements'
//     subjects don't.
//   * The other nine banks have no reliable subject line (most are
//     undocumented), so their clause is sender-domain only and the
//     parser + Authentication-Results gate decide what counts —
//     statements, payment-due, fraud and deposit mail from those
//     senders is listed, classified, and left unparsed, never
//     stored. Explicit subdomains are listed alongside the bare
//     domains because Gmail's from:(domain) matching of subdomains
//     is not relied on. e.chase.com (payment-due sender) and
//     info3.citibank.com (fraud-only sender) are deliberately NOT
//     in the query — they stay in the parser allowlist, but listing
//     them would poll payment-due / fraud mail on every poll.
export function buildAlertQuery(): string {
  return '{from:(americanexpress.com) subject:"Large Purchase"} {from:(alert.chase.com OR alertsp.chase.com OR chase.com OR bofa.com OR bankofamerica.com OR notify.wellsfargo.com OR alerts.wellsfargo.com OR wellsfargo.com OR citibank.com OR citi.com OR capitalone.com OR discover.com OR notifications.usbank.com OR alerts.usbank.com OR usbank.com OR pnc.com OR e.pnc.com OR td.com OR tdbank.com OR e.tdbank.com)}';
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
export function htmlToText(html: string): string {
  let text = String(html ?? '');
  text = text.replace(/<script[\s\S]*?<\/script\s*>/gi, ' ');
  text = text.replace(/<style[\s\S]*?<\/style\s*>/gi, ' ');
  text = text.replace(/<[^>]*>/g, ' ');
  text = text.replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'");
  text = text.replace(/&#(\d+);/g, (_m, code) => {
    try { return String.fromCharCode(Number(code)); } catch { return ' '; }
  });
  return text.replace(/\s+/g, ' ').trim();
}

export function extractPlainText(payload: GmailPayload | undefined | null): string {
  if (!payload) return '';
  // Prefer a real text/plain part. Amex alerts are often HTML-only
  // (Nov 2, 2026: the real Large Purchase email has no text/plain
  // part at all), and the old first-part-wins rule handed the parser
  // 52KB of raw HTML, where tags between the merchant and amount
  // cells defeated every merchant strategy. An HTML-only payload is
  // converted to text instead; anything else falls back to the first
  // non-empty part, as before.
  const parts: GmailPayload[] = [];
  const collect = (p: GmailPayload) => {
    parts.push(p);
    (p.parts ?? []).forEach(collect);
  };
  collect(payload);
  const decode = (p: GmailPayload): string => {
    try {
      const t = decodeBase64Url(p.body?.data ?? '');
      return t.trim() ? t : '';
    } catch {
      return '';
    }
  };
  for (const p of parts) {
    if ((p.mimeType ?? '').toLowerCase() === 'text/plain') {
      const t = decode(p);
      if (t) return t;
    }
  }
  for (const p of parts) {
    if ((p.mimeType ?? '').toLowerCase() === 'text/html') {
      const t = decode(p);
      if (t) {
        const converted = htmlToText(t);
        if (converted) return converted;
      }
    }
  }
  for (const p of parts) {
    const t = decode(p);
    if (t) return t;
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
//
// Real-format notes (Nov 2, 2026, from a real "Large Purchase Approved"
// alert): the merchant is a bare uppercase table cell next to the
// amount ("AMAZON MARKEPLACE NA PA $10.59*"), with no "at" phrasing and
// no subject tail — so a third merchant strategy (uppercase run before
// the amount) is required. And the body quotes the notification
// threshold in prose ("was more than $1.00"), so the amount must be the
// LARGEST dollar figure, not the first: the purchase always exceeds
// its own alert threshold.
//
// Strategy ORDER matters, proven against the real email (Nov 2, 2026):
// the stripped HTML text contains footer prose "at
// americanexpress.com", so the "at NAME" strategy must NOT run first
// or every alert parses as merchant "americanexpress.com". The
// amount-adjacent cell runs first (it is adjacent to the amount, the
// strongest signal); "at NAME" is the fallback for the old prose
// format, then the subject tail. Likewise the card-suffix pattern
// must tolerate a space before the colon ("Ending : 01005" after
// HTML tag-stripping), or the first match becomes the Additional
// Card's 6-digit "ending 101013" instead of the account's 01005.
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
  let hay = text;
  let matches = [...hay.matchAll(/\$([\d,]+\.\d{2})/g)];
  if (!matches.length) {
    hay = combined;
    matches = [...hay.matchAll(/\$([\d,]+\.\d{2})/g)];
  }
  if (!matches.length) return null;
  let amountCents = 0;
  let maxPos = 0;
  for (const m of matches) {
    const cents = Math.round(parseFloat(m[1].replace(/,/g, '')) * 100);
    if (cents >= amountCents) {
      amountCents = cents;
      maxPos = m.index ?? 0;
    }
  }
  if (!amountCents || amountCents <= 0) return null;
  let merchant: string | null = null;
  // Cell first: the uppercase run immediately before the amount.
  // (A run that looks like a domain is not a merchant; fall through.)
  const before = hay.slice(0, maxPos).trimEnd();
  const cellMatch = before.match(/([A-Z][A-Z0-9 .&'\-]{1,60})$/);
  if (cellMatch) {
    const cell = cellMatch[1].trim().replace(/\s+/g, ' ');
    if (!/\.(com|net|org|edu|gov|io|co)\b/i.test(cell)) merchant = cell;
  }
  if (!merchant) {
    const atMatch = combined.match(/\bat\s+([A-Za-z0-9][A-Za-z0-9 .&'\-]{1,60})/i);
    if (atMatch) merchant = atMatch[1].trim().replace(/\s+/g, ' ');
  }
  if (!merchant) {
    const subjMatch = subject.match(/[:\-–—]\s*(.+)$/);
    if (subjMatch) merchant = subjMatch[1].trim();
  }
  if (!merchant) return null;
  const suffixMatch = combined.match(/(?:ending(?: in)?\s*:?\s?|•|xx|\*)\s?(\d{4,6})/i);
  const cardSuffix = suffixMatch ? suffixMatch[1].slice(-4) : '0000';
  return { amountCents, merchant, cardSuffix, date };
}

// --- Multi-bank alert parsing (Nov 26, 2026) ---
// Generic parser built from
// research_notes/bank-transaction-alert-emails-20261126-0514/report.md.
// Covers Chase, Bank of America, Wells Fargo, Citi, Capital One,
// Discover, US Bank, PNC, TD. The Amex path above is UNTOUCHED —
// Amex keeps its own parser, query clause, and auth rule exactly
// as before.
// Verification status (from the report — do not overclaim):
//   * Real purchase-alert bodies verified live (Meli, Sept 2026):
//     Chase, Bank of America, Capital One, Citi.
//   * Sender/body from user-posted screenshots, authenticity
//     unverified: Wells Fargo, US Bank, Discover (post-merger
//     Capital One template).
//   * NO confirmed purchase-alert sender and NO confirmed purchase
//     body: PNC, TD. For those two the parser relies on the generic
//     rules only (labelled fields / prose + domain allowlist); a
//     real sample from the owner is still owed.
//   * Exact purchase-alert senders NOT confirmed for Citi,
//     Discover, PNC, TD — only domains are known, so the allowlist
//     is domain-based (see BANK_ALERT_DOMAINS) and the query lists
//     domains, not exact addresses.
// Fail-closed throughout: unknown sender, non-purchase
// classification, missing amount/merchant/date → null, and the
// caller quarantines the message; nothing is guessed into a
// transaction. Sender domain is a ROUTING signal, not proof of
// genuineness — phishing copies the wording verbatim, so the
// domain check (exact-or-subdomain, read right-to-left after @)
// plus DKIM+SPF is the gate, and lookalike domains are rejected
// outright.

export type BankId = 'chase' | 'bofa' | 'wellsfargo' | 'citi' | 'capitalone' | 'discover' | 'usbank' | 'pnc' | 'td';

export const BANK_ALERT_DOMAINS: Record<BankId, string[]> = {
  chase: ['chase.com'],
  bofa: ['bofa.com', 'bankofamerica.com'],
  wellsfargo: ['wellsfargo.com'],
  citi: ['citibank.com', 'citi.com'],
  capitalone: ['capitalone.com'],
  discover: ['discover.com', 'capitalone.com'],
  usbank: ['usbank.com'],
  pnc: ['pnc.com'],
  td: ['td.com', 'tdbank.com'],
};

export const BANK_ALERT_SOURCE: Record<BankId, string> = {
  chase: 'chase_alert',
  bofa: 'bofa_alert',
  wellsfargo: 'wellsfargo_alert',
  citi: 'citi_alert',
  capitalone: 'capitalone_alert',
  discover: 'discover_alert',
  usbank: 'usbank_alert',
  pnc: 'pnc_alert',
  td: 'td_alert',
};

export function bankForSource(source: string): BankId | null {
  for (const bank of Object.keys(BANK_ALERT_SOURCE) as BankId[]) {
    if (BANK_ALERT_SOURCE[bank] === source) return bank;
  }
  return null;
}

// A domain matches a base when it IS the base or a subdomain of it
// (read right-to-left after @). `capitalone-secure.com` does NOT
// match `capitalone.com` — it is a different base, not a subdomain.
export function domainMatchesBase(domain: string, base: string): boolean {
  const d = String(domain ?? '').toLowerCase().replace(/\.$/, '');
  const b = String(base ?? '').toLowerCase();
  return d === b || d.endsWith(`.${b}`);
}

function domainsInText(text: string): string[] {
  const out: string[] = [];
  for (const m of String(text ?? '').matchAll(/@([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})/g)) {
    out.push(m[1].toLowerCase());
  }
  return out;
}

// Bank-name tokens: a domain containing one of these as a dot/dash
// token but NOT allowlisted is a lookalike (e.g.
// capitalone-secure.com, td-bank-alerts.net) and is rejected, never
// treated as its bank.
const BANK_TOKENS = ['chase', 'capitalone', 'citi', 'citibank', 'wellsfargo', 'bofa', 'bankofamerica', 'usbank', 'pnc', 'td', 'tdbank', 'discover'];

function looksLikeBankDomain(domain: string): boolean {
  const tokens = String(domain ?? '').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  return tokens.some((t) => BANK_TOKENS.includes(t));
}

export function bankForDomain(domain: string): BankId | null {
  const d = String(domain ?? '').toLowerCase().replace(/\.$/, '');
  for (const bank of Object.keys(BANK_ALERT_DOMAINS) as BankId[]) {
    if (BANK_ALERT_DOMAINS[bank].some((b) => domainMatchesBase(d, b))) return bank;
  }
  return null;
}

export function identifyBankAlert(from: string, authResults: string): BankId | null {
  // Priority: the DKIM signing domain (header.i) in
  // Authentication-Results, then the From domain, then the SPF
  // mailfrom, then any other @domain in the auth header. A lookalike
  // anywhere in those signals rejects the message outright — a
  // genuine alert never carries one.
  const auth = String(authResults ?? '');
  const headerI = [...auth.matchAll(/header\.i=@([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})/gi)].map((m) => m[1].toLowerCase());
  const mailFrom = [...auth.matchAll(/smtp\.mailfrom=([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})/gi)].map((m) => m[1].toLowerCase());
  const candidates = [...headerI, ...domainsInText(from), ...mailFrom, ...domainsInText(auth)];
  for (const d of candidates) {
    const bank = bankForDomain(d);
    if (bank) return bank;
    if (looksLikeBankDomain(d)) return null;
  }
  return null;
}

// Same fail-closed shape as the Amex rule: the bank's own domain
// must appear as the DKIM signing domain or SPF mailfrom, AND both
// dkim=pass and spf=pass must be present. A display name is never
// enough — it is trivially spoofed.
export function authResultsPassForBank(authResults: string, bank: BankId): boolean {
  const h = String(authResults ?? '').toLowerCase();
  if (!h.includes('dkim=pass') || !h.includes('spf=pass')) return false;
  const auth = String(authResults ?? '');
  const domains = [
    ...[...auth.matchAll(/header\.i=@([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})/gi)].map((m) => m[1]),
    ...[...auth.matchAll(/smtp\.mailfrom=([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})/gi)].map((m) => m[1]),
  ];
  return domains.some((d) => BANK_ALERT_DOMAINS[bank].some((b) => domainMatchesBase(d, b)));
}

export type BankAlertKind = 'purchase' | 'declined' | 'fraud' | 'payment_due' | 'deposit_refund' | 'other';

// Classification reads the HEADLINE / first lines of the BODY, not
// the subject — subjects are generic or threshold-based and vary by
// bank. The subject is consulted only when the body carries no
// classification signal at all. Order matters: fraud/verification
// copy contains the word "purchase", and declined copy contains an
// amount and a merchant — both must be excluded BEFORE the purchase
// test, or a fraud check would book as spending.
export function classifyBankAlert(subject: string, body: string): BankAlertKind {
  const head = String(body ?? '').slice(0, 1200);
  const classify = (text: string): BankAlertKind | null => {
    if (/declined/i.test(text)) return 'declined';
    if (/do you recognize|please confirm|confirm (this |your )?(purchase|transaction|activity)|temporarily locked|under review|transaction flagged|verify (your|this)|recognize this purchase/i.test(text)) return 'fraud';
    if (/payment is due|payment due|statement (is )?(ready|available)/i.test(text)) return 'payment_due';
    if (/deposited|direct deposit|\bzelle\b|refund/i.test(text)) return 'deposit_refund';
    if (/(transaction|purchase|charged|charge of)/i.test(text)) return 'purchase';
    return null;
  };
  return classify(head) ?? classify(String(subject ?? '')) ?? 'other';
}

function bankAlertAmountCents(text: string): number | null {
  const toCents = (s: string): number => Math.round(parseFloat(s.replace(/,/g, '')) * 100);
  // 1. Labelled Amount: field (Chase / Citi / BofA tables).
  const labelled = text.match(/Amount:\s*\$([\d,]+\.\d{2})/i);
  if (labelled) {
    const cents = toCents(labelled[1]);
    if (cents > 0) return cents;
  }
  // 2. First $ amount that is not the alert THRESHOLD. Every bank
  // quotes the threshold in prose ("more than the $0.01 level you
  // set", "exceeded $0.01") — taking the first amount blindly
  // would book a $0.01 purchase.
  for (const m of text.matchAll(/\$([\d,]+\.\d{2})/g)) {
    const idx = m.index ?? 0;
    const before = text.slice(Math.max(0, idx - 48), idx);
    if (/(more than|exceeded|exceeds|greater than|over|above)\s*$/i.test(before)) continue;
    if (/level you set|alert (limit|threshold)|threshold/i.test(before)) continue;
    const cents = toCents(m[1]);
    if (cents > 0) return cents;
  }
  return null;
}

function cleanMerchant(raw: string): string | null {
  let m = String(raw ?? '').trim().replace(/\s+/g, ' ');
  m = m.replace(/[*.,;:]+$/, '').trim();
  if (m.length < 2) return null;
  if (!/[A-Za-z]{2}/.test(m)) return null;
  // A domain is not a merchant (footer prose "at americanexpress.com").
  if (/\.(com|net|org|edu|gov|io|co)\b/i.test(m)) return null;
  return m;
}

function bankAlertMerchant(text: string): string | null {
  // 1. Labelled Merchant: / Where: field (Citi / BofA; Chase table).
  // The value runs to the next labelled field (Amount: / Date: /
  // Time:) or the end — bodies arrive with whitespace collapsed to
  // spaces, so "to end of line" would swallow the rest of the mail.
  const labelled = text.match(/(?:Merchant|Where):\s*([A-Za-z0-9][A-Za-z0-9 .&'\-_/]*?)(?=\s+(?:Amount|Date|Time|Merchant|Where):|\s*$)/i);
  if (labelled) {
    const m = cleanMerchant(labelled[1]);
    if (m) return m;
  }
  // 2. Prose "at MERCHANT" (Capital One / Discover / Wells Fargo /
  // US Bank). Consume tokens after "at" while they look like a
  // merchant: ALL-CAPS words / store numbers throughout, with the
  // FIRST token allowed to be mixed-case (Bitrefill, Pilot_00034).
  // The first lowercase filler word ("in", "on", "Your", "a")
  // ends the merchant — so following prose ("Your purchase came
  // from a card ending in …") is never swallowed into the name.
  const atMatch = text.match(/\bat\s+(.+)/);
  if (atMatch) {
    const kept: string[] = [];
    for (const rawTok of atMatch[1].split(/\s+/)) {
      const tok = rawTok.replace(/^[(*]+/, '').replace(/[,;:*.]+$/, '');
      if (!tok) break;
      const isCaps = /^[A-Z0-9][A-Z0-9&'.\-_/]*$/.test(tok) && /[A-Z]/.test(tok);
      const isFirstMixed = kept.length === 0 && /^[A-Z][A-Za-z0-9&'.\-_/]+$/.test(tok);
      if (!isCaps && !isFirstMixed) break;
      kept.push(tok);
    }
    const m = cleanMerchant(kept.join(' '));
    if (m) return m;
  }
  // 3. Uppercase run immediately before the amount (Chase table
  // layout when the Merchant: label is absent).
  const amountPos = text.search(/\$[\d,]+\.\d{2}/);
  if (amountPos > 0) {
    const before = text.slice(0, amountPos).trimEnd();
    const cell = before.match(/([A-Z][A-Z0-9 .&'\-]{1,60})$/);
    if (cell) {
      const m = cleanMerchant(cell[1]);
      if (m) return m;
    }
  }
  return null;
}

function bankAlertCardSuffix(text: string): string {
  const m = text.match(/ending(?:\s+in)?\s*:?\s*(\d{4,6})/i)
    ?? text.match(/[•…*]\s*(\d{4})\b/)
    ?? text.match(/\(\D{0,4}(\d{4})\)/);
  return m ? m[1].slice(-4) : '0000';
}

const BANK_MONTHS: Record<string, string> = {
  jan: '01', january: '01', feb: '02', february: '02', mar: '03', march: '03',
  apr: '04', april: '04', may: '05', jun: '06', june: '06', jul: '07', july: '07',
  aug: '08', august: '08', sep: '09', sept: '09', september: '09', oct: '10',
  october: '10', nov: '11', november: '11', dec: '12', december: '12',
};

// The transaction date as printed in the body, if any. US banks
// print MM/DD/YYYY or "Month D, YYYY"; several templates print no
// time, and BofA prints no time at all — the caller falls back to
// the email Date: header (the `date` input) when this returns null.
function bankAlertBodyDate(text: string): string | null {
  const iso = (y: string, m: string, d: string): string | null => {
    const yy = Number(y);
    const mm = Number(m);
    const dd = Number(d);
    if (!Number.isInteger(yy) || !Number.isInteger(mm) || !Number.isInteger(dd)) return null;
    if (mm < 1 || mm > 12 || dd < 1 || dd > 31) return null;
    const dt = new Date(Date.UTC(yy, mm - 1, dd));
    if (dt.getUTCFullYear() !== yy || dt.getUTCMonth() !== mm - 1 || dt.getUTCDate() !== dd) return null;
    return `${y}-${String(mm).padStart(2, '0')}-${String(dd).padStart(2, '0')}`;
  };
  const mdy = text.match(/\b(\d{1,2})\/(\d{1,2})\/(\d{4})\b/);
  if (mdy) {
    const d = iso(mdy[3], mdy[1], mdy[2]);
    if (d) return d;
  }
  const named = text.match(/\b(January|February|March|April|May|June|July|August|September|Sept|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\.?\s+(\d{1,2}),\s+(\d{4})\b/i);
  if (named) {
    const mm = BANK_MONTHS[named[1].toLowerCase().replace('.', '')];
    if (mm) {
      const d = iso(named[3], mm, named[2]);
      if (d) return d;
    }
  }
  return null;
}

export type ParsedBankAlert = ParsedAlert & {
  bank: BankId;
  source: string;
  kind: 'purchase';
  // True when the wording is a pending authorisation ("pending
  // authorization or purchase") — the charge may not post. The row
  // still inserts as provisional (as all email rows do); this flag
  // is what the pending-vs-posted dedupe keys on.
  provisional: boolean;
};

export function parseBankAlertText(input: {
  subject: string;
  body: string;
  date: string;
  from?: string;
  authResults?: string;
}): ParsedBankAlert | null {
  const subject = String(input?.subject ?? '');
  const text = String(input?.body ?? '');
  const fallbackDate = String(input?.date ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fallbackDate)) return null;
  const bank = identifyBankAlert(String(input?.from ?? ''), String(input?.authResults ?? ''));
  if (!bank) return null;
  if (classifyBankAlert(subject, text) !== 'purchase') return null;
  const amountCents = bankAlertAmountCents(text);
  if (!amountCents || amountCents <= 0) return null;
  const merchant = bankAlertMerchant(text);
  if (!merchant) return null;
  const cardSuffix = bankAlertCardSuffix(subject + '\n' + text);
  const date = bankAlertBodyDate(text) ?? fallbackDate;
  return {
    amountCents,
    merchant,
    cardSuffix,
    date,
    bank,
    source: BANK_ALERT_SOURCE[bank],
    kind: 'purchase',
    provisional: /pending authorization/i.test(text),
  };
}

// Dedupe for the pending-authorisation → posted-charge pair
// (Capital One / Discover send one email at authorisation and one
// when it posts; Wells Fargo can fire several alert types for one
// purchase): same bank + same amount + same squashed merchant +
// same card (or unknown on either side) + dates within 1 day.
// Squash-based merchant comparison, same rule as the Nov 16
// bank+email dedupe — punctuation/case/whitespace must not defeat
// the match. This is a PURE comparison; the poll applies it
// against stored email rows.
export function squashMerchantForDedupe(merchant: string): string {
  return String(merchant ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}

export type BankAlertIdentity = {
  bank: BankId;
  cardSuffix: string;
  amountCents: number;
  merchant: string;
  date: string;
};

export function bankAlertMatches(a: BankAlertIdentity, b: BankAlertIdentity): boolean {
  if (a.bank !== b.bank || a.amountCents !== b.amountCents) return false;
  if (squashMerchantForDedupe(a.merchant) !== squashMerchantForDedupe(b.merchant)) return false;
  if (a.cardSuffix !== '0000' && b.cardSuffix !== '0000' && a.cardSuffix !== b.cardSuffix) return false;
  const ta = Date.parse(`${a.date}T00:00:00Z`);
  const tb = Date.parse(`${b.date}T00:00:00Z`);
  if (!Number.isFinite(ta) || !Number.isFinite(tb)) return false;
  return Math.abs(ta - tb) <= 86400000;
}

// Server-side dedupe: message ids not already in the processed set.
// Pure helper; the DB unique constraint is the backstop, not this.
export function filterNewMessageIds(allIds: string[], processedIds: string[]): string[] {
  const seen = new Set(processedIds ?? []);
  return (allIds ?? []).filter((id) => id && !seen.has(id));
}

// --- Per-bank parser dispatcher (build 44, item 4; multi-bank Nov 26, 2026) ---
// A bank registers its parser here and its source in EMAIL_SOURCES
// in canonical.ts; the merge paths (autoMergeEligible,
// findCoveringBankRow, plaid-sync steps 3/3b) then accept that
// bank's rows with no other code change. Amex keeps its own parser;
// every other bank shares parseBankAlertText, which identifies the
// bank from the sender (From / Authentication-Results) — so a
// caller that already knows the bank passes the source, and the
// parser still refuses mail whose sender does not match it.
// Nov 26, 2026 rebase: the F-15 parseChaseAlertText scaffold (build 64) was
// removed — Chase is parsed by parseBankAlertText, built from a real Chase alert
// body verified live (Meli, Sept 2026); the scaffold's best-guess patterns are
// superseded, and its gmail-poll gate (CHASE_ALERTS_ENABLED) is gone with it.
export type EmailAlertParser = (input: {
  subject: string;
  body: string;
  date: string;
  from?: string;
  authResults?: string;
}) => ParsedAlert | null;

export const EMAIL_PARSERS: Record<string, EmailAlertParser> = {
  amex_alert: parseAmexAlertText,
  chase_alert: parseBankAlertText,
  bofa_alert: parseBankAlertText,
  wellsfargo_alert: parseBankAlertText,
  citi_alert: parseBankAlertText,
  capitalone_alert: parseBankAlertText,
  discover_alert: parseBankAlertText,
  usbank_alert: parseBankAlertText,
  pnc_alert: parseBankAlertText,
  td_alert: parseBankAlertText,
};

export function parseEmailAlert(
  source: string,
  input: { subject: string; body: string; date: string; from?: string; authResults?: string },
): ParsedAlert | null {
  const parser = EMAIL_PARSERS[source];
  if (!parser) return null;
  return parser(input);
}
