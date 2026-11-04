// duplicateConnection.mjs — duplicate bank-connection guard, client side.
//
// The rule (owner, Nov 3, 9:42 PM): it must not be possible to connect
// the same bank account twice. A blanket block by institution name is
// WRONG: a household may legitimately hold genuinely different
// accounts at the same bank. A connection is a duplicate only when
// EVERY account it carries is already carried by ONE older, still-active
// connection at the SAME institution, matched on mask AND account
// name. Mask alone is not enough identity (two different cards can
// share a last-4), and name alone is not enough either; the pair is
// what makes a same-real-account match. Anything that cannot be
// proven — missing masks, missing names, missing institution, missing
// or equal created dates — is NOT a duplicate: the guard fails open
// and never deletes or blocks on a guess.
//
// Shape:
//   item: { plaid_item_id, institution_name, created_at,
//           accounts: [{ mask, name }] }
//   keepers: older active items, same shape.
// Returns the keeper's plaid_item_id, or null.

const norm = (v) => String(v ?? '').trim().toLowerCase().replace(/\s+/g, ' ');

export function findDuplicateKeeper(candidate, keepers) {
  if (!candidate || !Array.isArray(candidate.accounts) || candidate.accounts.length === 0) return null;
  const candInst = norm(candidate.institution_name);
  if (!candInst) return null;
  for (const acct of candidate.accounts) {
    if (!acct || !norm(acct.mask) || !norm(acct.name)) return null;
  }
  for (const keeper of keepers ?? []) {
    if (!keeper || keeper.plaid_item_id === candidate.plaid_item_id) continue;
    if (norm(keeper.institution_name) !== candInst) continue;
    // The keeper must be older: the newest fully-duplicated item is
    // the one removed, never the connection already in use. Without
    // both dates this cannot be proven, so it is not a duplicate.
    if (!keeper.created_at || !candidate.created_at) continue;
    if (!(String(keeper.created_at) < String(candidate.created_at))) continue;
    const keeperAccts = Array.isArray(keeper.accounts) ? keeper.accounts : [];
    const covered = candidate.accounts.every((acct) => keeperAccts.some(
      (k) => norm(k.mask) === norm(acct.mask) && norm(k.name) === norm(acct.name),
    ));
    if (covered) return keeper.plaid_item_id;
  }
  return null;
}

// One-line summary for the pre-Link warning: "Institution — Account ••mask, …"
export function describeConnection(item, accounts) {
  const parts = (accounts ?? []).map((a) => `${a.name || 'Account'}${a.mask ? ` ••${a.mask}` : ''}`);
  return `${item.institution_name || 'Bank'} — ${parts.length ? parts.join(', ') : 'no accounts listed yet'}`;
}
