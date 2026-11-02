// Household Budget — Gmail ingestion poller (LIVE, Plan B, S3 rewrite).
// Never commit a real secret or mailbox credential to this repo.
// The per-household secret lives ONLY in Script Properties and in the
// Supabase household_ingest_secrets table (set by the parent via the
// rotate function / SQL editor) — never pasted into this file or chat.
//
// PLAN B (active, owner decision Nov 1, 2026): this script runs bound to
// the PERSONAL Gmail account and searches ONLY for Amex Large Purchase
// alerts. No dedicated inbox, no forwarding. See INTEGRATIONS.md.
// (The dedicated-inbox / forwarding variant in spec v2 Part B2 is
// superseded for this deployment by the owner's Plan B decision.)
//
// Purpose: poll for Amex Large Purchase alerts and POST each new alert
// as a signed HTTPS event to the backend. The backend — not this script —
// verifies Authentication-Results, dedupes by messageId, and marks
// everything PROVISIONAL. Anything unparseable server-side is
// quarantined and creates no transaction.
//
// CONTRACT (authoritative: integrations/INGEST_CONTRACT.md):
//   Header:  'x-budget-signature' (lowercase; Apps Script sends it
//            exactly so; HTTP header names are case-insensitive, but
//            the contract name is this string).
//   Body fields (exactly these): messageId, auth_results (verbatim
//            Authentication-Results header), amount (integer cents),
//            merchant, date (YYYY-MM-DD only), household_id,
//            card_suffix, nonce, timestamp (epoch seconds).
//   HMAC:    HMAC-SHA256, hex lowercase, over the canonical string
//              timestamp + '.' + nonce + '.' + household_id + '.'
//              + messageId + '.' + amount + '.' + merchant + '.' + date
//            where amount is String(amount) exactly as sent and
//            merchant is the merchant string exactly as sent.
//   Labelling: the thread is labelled HB_PROCESSED ONLY when the
//            function response parses as JSON with stored === true.
//            NEVER on 401 / 202 (quarantined) / 500, and NEVER
//            unconditionally. A non-stored message is left unlabelled
//            so a later poll retries it (with a fresh nonce).
//
// Setup (owner performs the Gmail steps; see INTEGRATIONS.md):
//   1. In Apps Script (script.google.com, bound to the personal account),
//      paste this file, set the Script Properties below, and add a
//      time-driven trigger (e.g. every 10 minutes).
//   2. Tighten the search query below to the exact Amex alert
//      sender/subject once a real alert has been inspected. The query
//      is the boundary: only threads matching it are ever read.
//
// Script Properties to set (Apps Script -> Project Settings -> Script Properties):
//   WEBHOOK_URL            - the ingest-amex-alert function URL
//   HOUSEHOLD_ID           - the household UUID this script feeds
//   HOUSEHOLD_INGEST_SECRET- this household's per-household secret
//                            (same value stored via
//                            rotate_household_ingest_secret; the old
//                            SHARED_SECRET property is NOT read).
//   (No URL or secret value is written in this file.)
//
// Security notes:
//   - Never trust the From header alone. The backend verifies
//     Authentication-Results for americanexpress.com before accepting.
//   - This script sends only the contract fields above. It never sends
//     full mailbox contents, and it never follows links in messages.
//   - Alert parsing below is BEST-EFFORT and provisional: the exact
//     Amex Large Purchase alert template has not been confirmed
//     against a real redacted sample (spec Phase 0 gate). If amount or
//     merchant cannot be parsed, the message is NOT sent at all (it
//     stays unlabelled for manual review) rather than sending a
//     guessed value that would quarantine in a retry loop.
//
// Date note: `date` is the message date in America/New_York (the
// household timezone per spec A2), formatted YYYY-MM-DD. Email receipt
// time is not purchase time (spec B3); the matcher reconciles the
// provisional alert against the Plaid row, which carries the
// authoritative date.

function pollAmexAlerts() {
  var props = PropertiesService.getScriptProperties();
  var webhookUrl = props.getProperty('WEBHOOK_URL');
  var householdId = props.getProperty('HOUSEHOLD_ID');
  var secret = props.getProperty('HOUSEHOLD_INGEST_SECRET');
  if (!webhookUrl || !householdId || !secret) {
    Logger.log('WEBHOOK_URL / HOUSEHOLD_ID / HOUSEHOLD_INGEST_SECRET not set. See INGEST_CONTRACT.md.');
    return;
  }
  var label = GmailApp.getUserLabelByName('HB_PROCESSED') ||
    GmailApp.createLabel('HB_PROCESSED');
  // Plan B: search ONLY for Amex Large Purchase alerts in this account,
  // only unprocessed mail. Tighten the sender/subject terms below to the
  // exact alert wording once a real alert has been inspected
  // (see INGEST_CONTRACT.md). Nothing else is read.
  var threads = GmailApp.search('in:inbox -label:HB_PROCESSED from:(americanexpress.com) "Large Purchase"', 0, 25);
  threads.forEach(function (thread) {
    thread.getMessages().forEach(function (msg) {
      var parsed = parseAmexAlert(msg);
      if (!parsed) {
        // Unparseable: do NOT send, do NOT label. Manual review only.
        Logger.log('Skipping unparseable alert, message id: ' + msg.getId());
        return;
      }
      var nonce = Utilities.getUuid().replace(/-/g, '');
      var timestamp = Math.floor(new Date().getTime() / 1000);
      var payload = {
        messageId: msg.getId(),
        auth_results: msg.getHeader('Authentication-Results') || '',
        amount: parsed.amountCents,
        merchant: parsed.merchant,
        date: parsed.date,
        household_id: householdId,
        card_suffix: parsed.cardSuffix,
        nonce: nonce,
        timestamp: timestamp
      };
      // Canonical string — EXACT order and '.' joins (see contract).
      // amount is String(amountCents) exactly as sent in the payload.
      var canonical = [
        String(timestamp),
        nonce,
        householdId,
        msg.getId(),
        String(parsed.amountCents),
        parsed.merchant,
        parsed.date
      ].join('.');
      var signature = Utilities.computeHmacSha256Signature(canonical, secret);
      var hex = signature.map(function (b) {
        return ('0' + (b < 0 ? b + 256 : b).toString(16)).slice(-2);
      }).join('');
      var response;
      try {
        response = UrlFetchApp.fetch(webhookUrl, {
          method: 'post',
          contentType: 'application/json',
          headers: { 'x-budget-signature': hex },
          payload: JSON.stringify(payload),
          muteHttpExceptions: true
        });
      } catch (e) {
        Logger.log('Ingest fetch failed for ' + msg.getId() + ': ' + e);
        return; // Not stored: do NOT label.
      }
      var stored = false;
      try {
        var body = JSON.parse(response.getContentText());
        stored = body && body.stored === true;
      } catch (e) {
        stored = false;
      }
      // Label ONLY on stored === true. Never on 401/202/500, never
      // unconditionally. A stored:true duplicate (re-delivery) is also
      // safe to label: the purchase is already in transactions.
      if (stored) {
        thread.addLabel(label);
      } else {
        Logger.log('Ingest not stored for ' + msg.getId() +
          ' (HTTP ' + response.getResponseCode() + '): ' + response.getContentText());
      }
    });
  });
}

// Best-effort parser for an Amex Large Purchase alert. Returns null
// when amount or merchant cannot be found — the caller then sends
// nothing. Patterns are provisional until checked against a real
// redacted alert sample; see INGEST_CONTRACT.md §5.
function parseAmexAlert(msg) {
  var text = msg.getPlainBody() || '';
  var subject = msg.getSubject() || '';
  var combined = subject + '\n' + text;
  // Amount: first $ amount in the body, else in the subject.
  var amountMatch = text.match(/\$([\d,]+\.\d{2})/) ||
    combined.match(/\$([\d,]+\.\d{2})/);
  if (!amountMatch) return null;
  var amountCents = Math.round(parseFloat(amountMatch[1].replace(/,/g, '')) * 100);
  if (!amountCents || amountCents <= 0) return null;
  // Merchant: prefer "at <NAME>" phrasing, else the subject tail.
  var merchant = null;
  var atMatch = combined.match(/\bat\s+([A-Za-z0-9][A-Za-z0-9 .&'\-]{1,60})/i);
  if (atMatch) merchant = atMatch[1].trim().replace(/\s+/g, ' ');
  if (!merchant) {
    var subjMatch = subject.match(/[:\-–—]\s*(.+)$/);
    if (subjMatch) merchant = subjMatch[1].trim();
  }
  if (!merchant) return null;
  // Card suffix: "ending in 1234" / "•1234" / "xx1234" if present.
  var suffixMatch = combined.match(/(?:ending in|•|xx|\*)\s?(\d{4})/i);
  var cardSuffix = suffixMatch ? suffixMatch[1] : '0000';
  // Message date in the household timezone, YYYY-MM-DD only.
  var date = Utilities.formatDate(msg.getDate(), 'America/New_York', 'yyyy-MM-dd');
  return { amountCents: amountCents, merchant: merchant, cardSuffix: cardSuffix, date: date };
}
