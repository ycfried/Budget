// Household Budget — Gmail ingestion poller TEMPLATE (demo, not connected).
// Fill in the placeholders only when the backend exists. Never commit a
// real webhook URL, secret, or mailbox credential to this repo.
//
// Purpose: poll the DEDICATED ingestion Gmail inbox (which receives only
// forwarded copies of Amex Large Purchase alerts), and POST each new alert
// as a signed HTTPS event to the backend. The backend — not this script —
// runs the matcher, checks Authentication-Results, dedupes, and marks
// everything PROVISIONAL. Anything unparseable is quarantined server-side
// and creates no transaction.
//
// Setup (owner performs the Gmail steps; see INTEGRATIONS.md):
//   1. Create the dedicated Gmail account.
//   2. In personal Gmail, add it as a forwarding address and confirm it.
//   3. Create a filter matching Amex Large Purchase alerts ONLY and
//      forward matching mail to the dedicated address. Never forward all mail.
//   4. In Apps Script (script.google.com, bound to the dedicated account),
//      paste this file, set the Script Properties below, and add a
//      time-driven trigger (e.g. every 10 minutes).
//
// Script Properties to set (Apps Script -> Project Settings -> Script Properties):
//   WEBHOOK_URL  - https://<your-backend>/api/ingest/amex-alert   (placeholder)
//   SHARED_SECRET - a long random string, stored only in Script Properties
//                   and in the backend's secret store. Never in this file.
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
  // Search only the dedicated inbox, only unprocessed mail. Tighten the
  // query to the exact Amex alert sender/subject once a real forwarded
  // alert has been inspected (see INTEGRATIONS.md section B, step 5).
  var threads = GmailApp.search('in:inbox -label:HB_PROCESSED', 0, 25);
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
