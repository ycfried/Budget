// Household Budget — Gmail ingestion poller (LIVE, Plan B).
// Never commit a real secret or mailbox credential to this repo.
// The secret lives ONLY in Script Properties and in the Supabase
// Edge Function secrets (INGEST_SECRET) — both set by the agent via
// the dashboards, never pasted into this file or into chat.
//
// PLAN B (active, owner decision Nov 1, 2026): this script runs bound to
// the PERSONAL Gmail account and searches ONLY for Amex Large Purchase
// alerts. No dedicated inbox, no forwarding. See INTEGRATIONS.md.
// (The dedicated-inbox / forwarding variant is deferred, not active.)
//
// Purpose: poll for Amex Large Purchase alerts and POST each new alert
// as a signed HTTPS event to the backend. The backend — not this script —
// runs the matcher, checks Authentication-Results, dedupes, and marks
// everything PROVISIONAL. Anything unparseable is quarantined server-side
// and creates no transaction.
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
//   WEBHOOK_URL  - https://tnkhvdkmwmwiogiienee.supabase.co/functions/v1/ingest-amex-alert
//   SHARED_SECRET - the INGEST_SECRET value already set as a Supabase
//                   Edge Function secret (agent sets it here too, from
//                   the same generated value). Never in this file.
//
// Security notes:
//   - Never trust the From header alone. The backend must verify
//     Authentication-Results (SPF/DKIM) for the Amex sender domain
//     before accepting an alert.
//   - This script sends only: message id, date, subject, sender, and the
//     plain-text body of the alert. It never sends full mailbox contents.
//   - Processed messages get the label HB_PROCESSED so a re-run cannot
//     double-send them; the backend dedupes by stable hash as well.

function pollAmexAlerts() {
  var props = PropertiesService.getScriptProperties();
  var webhookUrl = props.getProperty('WEBHOOK_URL');
  var secret = props.getProperty('SHARED_SECRET');
  if (!webhookUrl || !secret) {
    Logger.log('WEBHOOK_URL / SHARED_SECRET not set. See INTEGRATIONS.md.');
    return;
  }
  var label = GmailApp.getUserLabelByName('HB_PROCESSED') ||
    GmailApp.createLabel('HB_PROCESSED');
  // Plan B: search ONLY for Amex Large Purchase alerts in this account,
  // only unprocessed mail. Tighten the sender/subject terms below to the
  // exact alert wording once a real alert has been inspected
  // (see INTEGRATIONS.md section B). Nothing else is read.
  var threads = GmailApp.search('in:inbox -label:HB_PROCESSED from:(americanexpress.com) "Large Purchase"', 0, 25);
  threads.forEach(function (thread) {
    thread.getMessages().forEach(function (msg) {
      var payload = {
        messageId: msg.getId(),
        date: msg.getDate().toISOString(),
        from: msg.getFrom(),
        subject: msg.getSubject(),
        body: msg.getPlainBody()
      };
      var signature = Utilities.computeHmacSha256Signature(
        JSON.stringify(payload), secret);
      var hex = signature.map(function (b) {
        return ('0' + (b < 0 ? b + 256 : b).toString(16)).slice(-2);
      }).join('');
      UrlFetchApp.fetch(webhookUrl, {
        method: 'post',
        contentType: 'application/json',
        headers: { 'X-HB-Signature': hex },
        payload: JSON.stringify(payload),
        muteHttpExceptions: true
      });
      thread.addLabel(label);
    });
  });
}
