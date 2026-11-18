// Refund-link suggestions (Nov 9, 2026) — pure client-side matcher
// for the Review area's "Refund Links" section (live.js).
//
// WHY: auto_link_refund links a refund at ingestion ONLY when exactly
// one purchase matches (same card, normalized merchant, exact amount,
// within 90 days, not fully refunded). Everything else arrives
// unlinked — two identical purchases, a partial refund, a refund
// whose merchant is spelled differently — and the only path was
// Actions → Link to Purchase on one row at a time. These suggestions
// surface those unlinked refunds next to Possible Duplicates, with
// the reason each purchase is suggested, so the admin links from
// the Review area instead of hunting row by row.
//
// Matching mirrors the server matcher (supabase/refund-linking.sql):
// same card suffix (a NULL suffix never matches), purchase on or
// before the refund, within 90 days, and the refund must fit in
// what the purchase has left to refund (linked live refunds count
// against it — a fully refunded purchase is never suggested).
// Merchant matching mirrors canonical.ts: normalized names equal,
// one contains the other, or a confirmed alias pair. NOTHING here
// links anything — Link calls the existing link_refund RPC, whose
// server-side fit check stays the guard.
//
// A dismissed (refund, purchase) pair never reappears: the caller
// passes the dismissals read from refund_link_dismissals, and this
// module filters those pairs out before returning suggestions.

// Same normalization as canonical.ts normalizeMerchant: UPPER,
// trimmed, whitespace collapsed. "AMAZON" and "AMAZON MARKEPLACE
// NA PA" normalize differently — that is why they are lookalikes,
// not identical; relatedness (below) is what connects them.
export function normalizeMerchant(merchant) {
  return String(merchant ?? '').toUpperCase().trim().replace(/\s+/g, ' ');
}

// Same rule as canonical.ts merchantsRelated: names that differ but
// one contains the other (and both are at least 4 chars). Identical
// names return false here — equality is checked separately, so a
// caller never double-counts "same name" as "related name".
export function merchantsRelated(a, b) {
  const na = normalizeMerchant(a);
  const nb = normalizeMerchant(b);
  if (!na || !nb || na === nb) return false;
  if (na.length < 4 || nb.length < 4) return false;
  return na.includes(nb) || nb.includes(na);
}

// Confirmed alias pairs, as read from merchant_aliases. Aliases
// alone merge nothing (dedupe-review-queue.sql); here they are
// evidence that two spellings are the same place.
export function aliasSetFromRows(aliasRows) {
  const set = new Set();
  for (const a of aliasRows ?? []) {
    const x = normalizeMerchant(a.name_a);
    const y = normalizeMerchant(a.name_b);
    if (x && y) { set.add(`${x}|${y}`); set.add(`${y}|${x}`); }
  }
  return set;
}

export function merchantMatches(a, b, aliasSet) {
  const na = normalizeMerchant(a);
  const nb = normalizeMerchant(b);
  if (!na || !nb) return false;
  if (na === nb) return true;
  if (merchantsRelated(a, b)) return true;
  return !!(aliasSet && aliasSet.has(`${na}|${nb}`));
}

// What a purchase still has left to refund, in cents: its amount
// minus live refunds already linked to it. A purchase is only a
// candidate while this is positive.
export function remainingRefundRoom(purchaseAmountCents, linkedTotalCents) {
  return purchaseAmountCents - (linkedTotalCents ?? 0);
}

function daysBefore(isoDate, days) {
  const d = new Date(`${isoDate}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

// Compute suggestions for unlinked refunds.
//   refunds: [{ id, merchant, amount_cents (negative), date, card_suffix }]
//     — kind='refund', original_purchase_id null, not excluded/reversed.
//   purchases: [{ id, merchant, amount_cents (positive), date, card_suffix, source }]
//     — kind in ('charge','fund_charge'), not excluded/reversed.
//   aliases: merchant_aliases rows [{ name_a, name_b }].
//   dismissals: refund_link_dismissals rows [{ refund_id, purchase_id }].
//   linkedTotals: Map purchaseId -> sum of |amount_cents| of live linked refunds.
// Returns [{ refund, purchase, reason, strength }] sorted by refund
// date (newest first), then exact matches before partials, then
// purchase date (newest first). Reasons:
//   'only-match' — the only purchase that matches (same amount,
//     card, and place). Auto-link would have taken this at ingestion,
//     so one still unlinked means auto-link never ran for it —
//     e.g. it arrived while live auto-linking was broken (Nov 9,
//     2026 max(uuid) bug) — and the suggestion is the repair path.
//   'exact-multi' — same amount, card, and place, but more than one
//     purchase matches; the admin picks the right one.
//   'partial' — smaller than the purchase and fits in the purchase's
//     remaining refund room; merchant matches.
//   'different-merchant' — same amount and card, in the window, but
//     the merchant names do not match; the admin checks it is the
//     right purchase before linking.
// A partial refund whose merchant does not match is NOT suggested:
// too weak to be useful, and the manual picker already lists every
// same-card charge in the window as its fallback.
export function computeRefundSuggestions({ refunds, purchases, aliases, dismissals, linkedTotals }) {
  const aliasSet = aliasSetFromRows(aliases);
  const dismissed = new Set((dismissals ?? []).map((d) => `${d.refund_id}|${d.purchase_id}`));
  const out = [];
  for (const refund of refunds ?? []) {
    if (!refund || refund.amount_cents >= 0) continue;
    const refundAbs = Math.abs(refund.amount_cents);
    const since = daysBefore(refund.date, 90);
    const exact = [];
    const partial = [];
    const differentMerchant = [];
    for (const purchase of purchases ?? []) {
      if (!purchase || purchase.amount_cents <= 0) continue;
      // Same card, and a NULL suffix on either side never matches
      // (same rule as link_refund P2-N8 / auto_link_refund).
      if (!refund.card_suffix || !purchase.card_suffix || refund.card_suffix !== purchase.card_suffix) continue;
      if (purchase.date > refund.date || purchase.date < since) continue;
      const room = remainingRefundRoom(purchase.amount_cents, linkedTotals?.get(purchase.id));
      if (room <= 0 || refundAbs > room) continue;
      if (dismissed.has(`${refund.id}|${purchase.id}`)) continue;
      const namesMatch = merchantMatches(refund.merchant, purchase.merchant, aliasSet);
      if (refundAbs === purchase.amount_cents) {
        if (namesMatch) exact.push(purchase);
        else differentMerchant.push(purchase);
      } else if (refundAbs < purchase.amount_cents) {
        if (namesMatch) partial.push(purchase);
      }
    }
    if (exact.length === 1) {
      out.push({ refund, purchase: exact[0], reason: 'only-match', strength: 'exact' });
    } else {
      for (const purchase of exact) {
        out.push({ refund, purchase, reason: 'exact-multi', strength: 'exact' });
      }
    }
    for (const purchase of partial) {
      out.push({ refund, purchase, reason: 'partial', strength: 'partial' });
    }
    for (const purchase of differentMerchant) {
      out.push({ refund, purchase, reason: 'different-merchant', strength: 'different-merchant' });
    }
  }
  const strengthRank = { exact: 0, partial: 1, 'different-merchant': 2 };
  out.sort((a, b) => {
    if (a.refund.date !== b.refund.date) return a.refund.date < b.refund.date ? 1 : -1;
    if (strengthRank[a.strength] !== strengthRank[b.strength]) return strengthRank[a.strength] - strengthRank[b.strength];
    if (a.purchase.date !== b.purchase.date) return a.purchase.date < b.purchase.date ? 1 : -1;
    return 0;
  });
  return out;
}

export const REFUND_SUGGESTION_REASONS = {
  'only-match': 'Only one purchase matches — same amount, card, and place.',
  'exact-multi': 'Same amount, card, and place — more than one purchase matches, pick the right one.',
  partial: 'Partial refund — fits in what this purchase has left to refund.',
  'different-merchant': 'Same amount and card, different place — check this is the right purchase before linking.',
};
