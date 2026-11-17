// push-notify — the one Edge Function that owns all APNs traffic.
//
// Contract:
//   Request (POST): { type, household_id, ...type-specific fields }.
//     week_closed:      { week_starts: ["YYYY-MM-DD", ...] }
//     new_week:         { }  (amount + week start come from compute-week)
//     new_transaction:  { source: "plaid" | "gmail" }
//     monthly_statement:{ month: "YYYY-MM" }
//     member_joined:    { user_id }
//     member_left:      { user_id, name }
//     gmail_expiring:   { connection_id }
//     fund_request:     { request_id }
//     bank_broken:      { item_id }
//     budget_increased: { kind: "temporary" | "base" | "add", old_cents, new_cents, week_start }
//   Auth, either of (same dual pattern as gmail-poll):
//     (a) a caller JWT: the caller must be a MEMBER of that household
//         (verified via the JWT + household_members lookup). This is
//         the path the native app uses for member_joined / member_left.
//     (b) a server bearer: the Authorization token equals the
//         SERVICE_ROLE_SECRET / SUPABASE_SERVICE_ROLE_KEY env value.
//         This is the path week-close, plaid-sync, and gmail-poll use.
//   The function re-reads the underlying data and derives copy +
//   recipients itself. It never trusts the caller's title, body, or
//   recipients. It respects notification_preferences (a missing row
//   means all on) and dedupes via push_deliveries (plan §1.1).
//   Response: { ok: true, sent, ... } or { ok: true, skipped:
//   "apns_not_configured" } when the .p8 key is not yet configured.
//   Sending is a safe no-op then: it never crashes, never errors,
//   never blocks the caller, and claims no dedupe keys.
//   Per-token failures: 410 / BadDeviceToken / Unregistered delete the
//   token row; 429 / 5xx log and drop (no retry queue in v1).
//   No device tokens, merchant names, or amounts are ever logged.
// DEPLOY NOTE: this file imports './apns.ts' — the copy sitting
// ALONGSIDE it in this directory (same pattern as gmail-poll's
// alongside canonical.ts). Paste both files verbatim; do not rewrite
// the import to ../_shared/... — that path does not exist in the
// dashboard file tree.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  buildCopy,
  currentWeekStartNY,
  dedupeKey,
  dedupePrefixForKind,
  formatMonthLabel,
  notifyTypeForKind,
  screenForType,
  signApnsJwt,
  toggleColumnForKind,
  type ApnsCredentials,
} from './apns.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SERVICE_KEY = Deno.env.get('SERVICE_ROLE_SECRET') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const APNS_BUNDLE_ID = Deno.env.get('APNS_BUNDLE_ID') ?? 'com.onbudget.ios';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/// The APNs credentials, or null when the .p8 key is not configured yet.
function apnsCredentials(): ApnsCredentials | null {
  const keyPem = Deno.env.get('APNS_KEY_P8') ?? '';
  const keyId = Deno.env.get('APNS_KEY_ID') ?? '';
  const teamId = Deno.env.get('APNS_TEAM_ID') ?? '';
  if (!keyPem || !keyId || !teamId) return null;
  return { keyPem, keyId, teamId };
}

type SupabaseAdmin = ReturnType<typeof createClient>;

async function loadMembers(admin: SupabaseAdmin, householdId: string, role?: string): Promise<string[]> {
  let query = admin.from('household_members').select('user_id').eq('household_id', householdId);
  if (role) query = query.eq('role', role);
  const { data, error } = await query;
  if (error) {
    console.error('push-notify: members read failed');
    return [];
  }
  return (data ?? []).map((r: { user_id: string }) => r.user_id);
}

/// Insert dedupe keys, ignoring conflicts; returns the keys that were
/// actually inserted (i.e. the events this call owns). A key that is
/// already present means the event was already notified.
async function claimKeys(admin: SupabaseAdmin, householdId: string, keys: string[]): Promise<string[]> {
  if (keys.length === 0) return [];
  const { data, error } = await admin
    .from('push_deliveries')
    .upsert(keys.map((k) => ({ household_id: householdId, event_key: k })), {
      onConflict: 'household_id,event_key',
      ignoreDuplicates: true,
    })
    .select('event_key');
  if (error) {
    console.error('push-notify: dedupe claim failed');
    return [];
  }
  return (data ?? []).map((r: { event_key: string }) => r.event_key);
}

/// compute-week for the current week (the single source of truth for
/// the week's available). Needs compute-week's service-key path.
async function callComputeWeek(householdId: string): Promise<{ week_start: string; available_cents: number } | null> {
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/compute-week`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${SERVICE_KEY}` },
      body: JSON.stringify({ household_id: householdId }),
    });
    if (!res.ok) {
      console.error('push-notify: compute-week failed');
      return null;
    }
    const body = await res.json();
    if (typeof body.available_cents !== 'number' || typeof body.week_start !== 'string') return null;
    return { week_start: body.week_start, available_cents: body.available_cents };
  } catch {
    console.error('push-notify: compute-week error');
    return null;
  }
}

interface TokenRow {
  device_token: string;
  environment: string;
}

async function sendToToken(
  token: TokenRow,
  jwt: string,
  title: string,
  body: string,
  data: Record<string, unknown>,
  collapseId: string,
): Promise<Response> {
  const host = token.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
  return await fetch(`https://${host}/3/device/${token.device_token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': APNS_BUNDLE_ID,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'apns-collapse-id': collapseId,
    },
    body: JSON.stringify({ aps: { alert: { title, body }, sound: 'default' }, data }),
  });
}

async function deleteToken(admin: SupabaseAdmin, householdId: string, deviceToken: string): Promise<void> {
  await admin.from('push_tokens').delete().eq('household_id', householdId).eq('device_token', deviceToken);
}

interface SendOptions {
  householdId: string;
  recipientUserIds: string[];
  toggleColumn: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  collapseId: string;
  jwt: string;
}

/// Send one notification to the recipients who have the type turned on.
/// Returns how many pushes Apple accepted and how many tokens were tried.
async function sendPush(admin: SupabaseAdmin, opts: SendOptions): Promise<{ sent: number; tokens: number }> {
  if (opts.recipientUserIds.length === 0) return { sent: 0, tokens: 0 };
  // Preferences: a missing row means all on. The master on/off
  // (notifications_enabled) gates everything: a user with it off
  // gets nothing, whatever the per-type flag says. A missing column
  // (migration lag) reads as on — fail-open, same as the toggles.
  const { data: prefs } = await admin
    .from('notification_preferences')
    .select(`user_id,notifications_enabled,${opts.toggleColumn}`)
    .eq('household_id', opts.householdId)
    .in('user_id', opts.recipientUserIds);
  const allowedByUser = new Map<string, boolean>(
    (prefs ?? []).map((p: Record<string, unknown>) => [
      String(p.user_id),
      p.notifications_enabled !== false && p[opts.toggleColumn] !== false,
    ]),
  );
  const allowed = opts.recipientUserIds.filter((id) => allowedByUser.get(id) !== false);
  if (allowed.length === 0) return { sent: 0, tokens: 0 };
  const { data: tokens } = await admin
    .from('push_tokens')
    .select('device_token, environment')
    .eq('household_id', opts.householdId)
    .in('user_id', allowed);
  if (!tokens || tokens.length === 0) return { sent: 0, tokens: 0 };
  let sent = 0;
  for (const token of tokens as TokenRow[]) {
    let res: Response;
    try {
      res = await sendToToken(token, opts.jwt, opts.title, opts.body, opts.data, opts.collapseId);
    } catch {
      console.error('push-notify: APNs request failed');
      continue;
    }
    if (res.status === 200) {
      sent += 1;
      continue;
    }
    if (res.status === 410) {
      await deleteToken(admin, opts.householdId, token.device_token);
      continue;
    }
    if (res.status === 400) {
      const parsed = await res.json().catch(() => ({}));
      const reason = String((parsed as { reason?: unknown }).reason ?? '');
      if (reason === 'BadDeviceToken' || reason === 'Unregistered') {
        await deleteToken(admin, opts.householdId, token.device_token);
      } else {
        console.error('push-notify: APNs 400');
      }
      continue;
    }
    console.error('push-notify: APNs non-200 status');
  }
  return { sent, tokens: tokens.length };
}

/// Over-budget check, shared by the new-transaction and week-close
/// paths: if the current week's available is below $0 and this week
/// has not been notified yet, send one over-budget push.
async function maybeNotifyOverBudget(
  admin: SupabaseAdmin,
  householdId: string,
  jwt: string,
): Promise<{ sent: number }> {
  const week = await callComputeWeek(householdId);
  if (!week || week.available_cents >= 0) return { sent: 0 };
  const claimed = await claimKeys(admin, householdId, [
    dedupeKey('over_budget', [householdId, week.week_start]),
  ]);
  if (claimed.length === 0) return { sent: 0 };
  const members = await loadMembers(admin, householdId);
  const copy = buildCopy('over_budget', { overCents: -week.available_cents });
  const result = await sendPush(admin, {
    householdId,
    recipientUserIds: members,
    toggleColumn: 'over_budget',
    title: copy.title,
    body: copy.body,
    data: { type: 'over_budget', household_id: householdId, week_start: week.week_start, screen: 'week' },
    collapseId: `${householdId}:over_budget`,
    jwt,
  });
  return { sent: result.sent };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  try {
    const auth = req.headers.get('Authorization') ?? '';
    if (!auth.startsWith('Bearer ')) return json({ error: 'missing authorization' }, 401);
    const bearer = auth.slice('Bearer '.length);
    if (!SUPABASE_URL || !SERVICE_KEY) return json({ error: 'service key not configured' }, 503);

    const body = await req.json().catch(() => ({}));
    const type = String(body.type ?? '');
    const householdId = String(body.household_id ?? '');
    if (!type) return json({ error: 'type required' }, 400);
    if (!householdId) return json({ error: 'household_id required' }, 400);

    // Dual auth (gmail-poll pattern): a user JWT must belong to a
    // member of this household; otherwise the bearer must be the
    // service key.
    const supabaseUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: auth } },
    });
    const { data: { user } } = await supabaseUser.auth.getUser();
    if (user) {
      const { data: membership } = await supabaseUser
        .from('household_members')
        .select('user_id')
        .eq('household_id', householdId)
        .eq('user_id', user.id)
        .maybeSingle();
      if (!membership) return json({ error: 'not a household member' }, 403);
    } else if (!timingSafeEqual(bearer, SERVICE_KEY)) {
      return json({ error: 'unauthorized' }, 401);
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // Graceful no-op while the .p8 key is not configured: claim no
    // dedupe keys, send nothing, never error.
    const creds = apnsCredentials();
    if (!creds) {
      console.log('push-notify: APNs not configured, skipping');
      return json({ ok: true, sent: 0, skipped: 'apns_not_configured' });
    }
    const jwt = await signApnsJwt(creds);
    const today = new Date().toISOString().slice(0, 10);

    switch (type) {
      case 'week_closed': {
        const weekStarts: string[] = Array.isArray(body.week_starts)
          ? body.week_starts.map(String).sort()
          : [];
        if (weekStarts.length === 0) return json({ error: 'week_starts required' }, 400);
        const latest = weekStarts[weekStarts.length - 1];
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('week_closed', [householdId, latest]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const { data: closes } = await admin
          .from('week_closes')
          .select('week_start, surplus_cents')
          .eq('household_id', householdId)
          .in('week_start', weekStarts);
        const surplus = (closes ?? []).reduce(
          (sum: number, c: { surplus_cents?: number }) => sum + (c.surplus_cents ?? 0),
          0,
        );
        const { data: household } = await admin
          .from('households')
          .select('fund_names')
          .eq('id', householdId)
          .maybeSingle();
        const fundName = (household?.fund_names as { fund?: string } | null)?.fund ?? 'Extra Fund';
        const members = await loadMembers(admin, householdId);
        const copy = buildCopy('week_closed', { weekStarts, surplusCents: surplus, fundName });
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: members,
          toggleColumn: 'week_closed',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, week_start: latest, weeks_closed: weekStarts.length, screen: 'week' },
          collapseId: `${householdId}:week_closed`,
          jwt,
        });
        const over = await maybeNotifyOverBudget(admin, householdId, jwt);
        return json({ ok: true, sent: result.sent, over_budget_sent: over.sent });
      }

      case 'new_week': {
        const week = await callComputeWeek(householdId);
        const weekStart = week?.week_start ?? currentWeekStartNY();
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('new_week', [householdId, weekStart]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const members = await loadMembers(admin, householdId);
        const copy = buildCopy('new_week', { availableCents: week?.available_cents ?? null });
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: members,
          toggleColumn: 'new_week',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, week_start: weekStart, screen: 'week' },
          collapseId: `${householdId}:new_week`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      case 'new_transaction': {
        const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
        const { data: rows } = await admin
          .from('transactions')
          .select('id, kind, merchant, amount_cents, dedupe_hash, created_at')
          .eq('household_id', householdId)
          .in('kind', ['charge', 'income', 'charity'])
          .in('state', ['provisional', 'verified'])
          .gte('created_at', since)
          .order('created_at', { ascending: false })
          .limit(20);
        if (!rows || rows.length === 0) {
          return json({ ok: true, sent: 0, reason: 'no_new_transactions' });
        }
        const members = await loadMembers(admin, householdId);
        // Large-purchase threshold (Spending fund setting; $100
        // default when the column is not yet migrated).
        let largeThreshold = 10000;
        const { data: householdRow } = await admin
          .from('households')
          .select('large_purchase_threshold_cents')
          .eq('id', householdId)
          .maybeSingle();
        if (householdRow && typeof (householdRow as { large_purchase_threshold_cents?: unknown }).large_purchase_threshold_cents === 'number') {
          largeThreshold = (householdRow as { large_purchase_threshold_cents: number }).large_purchase_threshold_cents;
        }
        let totalSent = 0;
        const perKind: Record<string, number> = {};
        for (const kind of ['charge', 'income', 'charity'] as const) {
          const group = (rows as Array<Record<string, unknown>>).filter((r) => r.kind === kind);
          if (group.length === 0) continue;
          const prefix = dedupePrefixForKind(kind);
          const keyFor = (r: Record<string, unknown>) =>
            dedupeKey(prefix, [String(r.dedupe_hash ?? r.id)]);
          const claimed = await claimKeys(admin, householdId, group.map(keyFor));
          if (claimed.length === 0) continue;
          const claimedRows = group.filter((r) => claimed.includes(keyFor(r)));
          const notifyType = notifyTypeForKind(kind);
          // Large purchases (kind charge, amount >= threshold) are
          // notified as large purchases INSTEAD of regular new
          // purchases — one push per transaction, never two. The
          // remaining (small) charges still get the regular push.
          const sendGroup = async (
            subset: Array<Record<string, unknown>>,
            type: string,
            toggle: string,
          ): Promise<number> => {
            if (subset.length === 0) return 0;
            const newest = subset[0];
            const total = subset.reduce((s, r) => s + Number(r.amount_cents ?? 0), 0);
            const copy = buildCopy(type, {
              count: subset.length,
              totalCents: total,
              merchant: String(newest.merchant ?? ''),
              amountCents: Number(newest.amount_cents ?? 0),
            });
            const result = await sendPush(admin, {
              householdId,
              recipientUserIds: members,
              toggleColumn: toggle,
              title: copy.title,
              body: copy.body,
              data: { type, household_id: householdId, screen: screenForType(type) },
              collapseId: `${householdId}:${type}`,
              jwt,
            });
            perKind[type] = result.sent;
            return result.sent;
          };
          if (kind === 'charge') {
            const large = claimedRows.filter((r) => Number(r.amount_cents ?? 0) >= largeThreshold);
            const regular = claimedRows.filter((r) => Number(r.amount_cents ?? 0) < largeThreshold);
            totalSent += await sendGroup(large, 'large_purchase', 'large_purchase');
            totalSent += await sendGroup(regular, notifyType, toggleColumnForKind(kind));
          } else {
            totalSent += await sendGroup(claimedRows, notifyType, toggleColumnForKind(kind));
          }
        }
        const over = await maybeNotifyOverBudget(admin, householdId, jwt);
        return json({ ok: true, sent: totalSent, per_kind: perKind, over_budget_sent: over.sent });
      }

      case 'monthly_statement': {
        const month = String(body.month ?? '');
        if (!/^\d{4}-\d{2}$/.test(month)) return json({ error: 'month required (YYYY-MM)' }, 400);
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('monthly_statement', [householdId, month]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const members = await loadMembers(admin, householdId);
        const copy = buildCopy('monthly_statement', { monthLabel: formatMonthLabel(month) });
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: members,
          toggleColumn: 'monthly_statement',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, month, screen: screenForType(type) },
          collapseId: `${householdId}:monthly_statement`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      case 'member_joined': {
        const userId = String(body.user_id ?? '');
        if (!userId) return json({ error: 'user_id required' }, 400);
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('member_joined', [householdId, userId, today]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const { data: member } = await admin
          .from('household_members')
          .select('display_name')
          .eq('household_id', householdId)
          .eq('user_id', userId)
          .maybeSingle();
        const name = (member?.display_name as string | null) ?? 'A member';
        const members = (await loadMembers(admin, householdId)).filter((id) => id !== userId);
        const copy = buildCopy('member_joined', { name });
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: members,
          toggleColumn: 'member_joined',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, user_id: userId, screen: screenForType(type) },
          collapseId: `${householdId}:member_joined`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      case 'member_left': {
        const userId = String(body.user_id ?? '');
        if (!userId) return json({ error: 'user_id required' }, 400);
        // The member row is already deleted, so the caller passes the
        // display name it showed in the member list.
        const name = String(body.name ?? '') || 'A member';
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('member_left', [householdId, userId, today]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const members = await loadMembers(admin, householdId);
        const copy = buildCopy('member_left', { name });
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: members,
          toggleColumn: 'member_left',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, user_id: userId, screen: screenForType(type) },
          collapseId: `${householdId}:member_left`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      case 'gmail_expiring': {
        const connectionId = String(body.connection_id ?? '');
        if (!connectionId) return json({ error: 'connection_id required' }, 400);
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('gmail_expiring', [householdId, connectionId, today]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const admins = await loadMembers(admin, householdId, 'admin');
        const copy = buildCopy('gmail_expiring', {});
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: admins,
          toggleColumn: 'gmail_expiring',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, connection_id: connectionId, screen: screenForType(type) },
          collapseId: `${householdId}:gmail_expiring`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      case 'fund_request': {
        const requestId = String(body.request_id ?? '');
        if (!requestId) return json({ error: 'request_id required' }, 400);
        const { data: request } = await admin
          .from('fund_requests')
          .select('id, requested_by, amount_cents, note, status')
          .eq('id', requestId)
          .eq('household_id', householdId)
          .maybeSingle();
        if (!request) return json({ error: 'request not found' }, 404);
        if (request.status !== 'pending') return json({ ok: true, sent: 0, reason: 'not_pending' });
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('fund_request', [requestId]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const { data: member } = await admin
          .from('household_members')
          .select('display_name')
          .eq('household_id', householdId)
          .eq('user_id', request.requested_by)
          .maybeSingle();
        const name = (member?.display_name as string | null) ?? 'A member';
        const { data: household } = await admin
          .from('households')
          .select('fund_names')
          .eq('id', householdId)
          .maybeSingle();
        const fundName = (household?.fund_names as { fund?: string } | null)?.fund ?? 'Extra Fund';
        const admins = (await loadMembers(admin, householdId, 'admin'))
          .filter((id) => id !== request.requested_by);
        const copy = buildCopy('fund_request', {
          name,
          amountCents: request.amount_cents,
          fundName,
          note: (request.note as string) || undefined,
        });
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: admins,
          toggleColumn: 'fund_request',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, request_id: requestId, screen: screenForType(type) },
          collapseId: `${householdId}:fund_request`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      case 'needs_review': {
        // Review queue (Nov 16, ~11:56 PM): whenever something needs
        // admin/owner attention — a new possible duplicate or a held
        // refund. Fund requests are NOT re-notified here: they have
        // their own `fund_request` trigger with specific copy, and
        // each Review item maps to exactly one trigger type, so the
        // same item can never fire twice. Refund suggestions are
        // computed client-side (no server creation event), so they
        // are not covered — they appear in Review when the admin
        // opens it.
        const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
        const { data: dupes } = await admin
          .from('duplicate_candidates')
          .select('id')
          .eq('household_id', householdId)
          .eq('status', 'pending')
          .gte('created_at', since)
          .order('created_at', { ascending: false })
          .limit(10);
        const { data: held } = await admin
          .from('held_refunds')
          .select('id, held_cents')
          .eq('household_id', householdId)
          .in('status', ['held', 'pending'])
          .gte('created_at', since)
          .order('created_at', { ascending: false })
          .limit(10);
        const keys: string[] = [];
        const kinds: string[] = [];
        for (const d of (dupes ?? []) as { id: string }[]) {
          keys.push(dedupeKey('needs_review:duplicate', [d.id]));
          kinds.push('duplicate');
        }
        for (const h of (held ?? []) as { id: string }[]) {
          keys.push(dedupeKey('needs_review:held_refund', [h.id]));
          kinds.push('held_refund');
        }
        if (keys.length === 0) {
          return json({ ok: true, sent: 0, reason: 'nothing_new' });
        }
        const claimed = await claimKeys(admin, householdId, keys);
        if (claimed.length === 0) {
          return json({ ok: true, sent: 0, reason: 'already_sent' });
        }
        // claimed is in key order, so kinds line up 1:1.
        const claimedKinds = claimed.map((key) => kinds[keys.indexOf(key)]);
        const heldRows = (held ?? []) as { id: string; held_cents: number }[];
        const singleHeld = claimedKinds.length === 1 && claimedKinds[0] === 'held_refund'
          ? heldRows.find((h) => claimed[0] === dedupeKey('needs_review:held_refund', [h.id]))
          : undefined;
        const admins = await loadMembers(admin, householdId, 'admin');
        const copy = buildCopy('needs_review', {
          count: claimed.length,
          kinds: claimedKinds,
          amountCents: singleHeld?.held_cents,
        });
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: admins,
          toggleColumn: 'needs_review',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, count: claimed.length, screen: screenForType(type) },
          collapseId: `${householdId}:needs_review`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      case 'bank_broken': {
        const itemId = String(body.item_id ?? '');
        if (!itemId) return json({ error: 'item_id required' }, 400);
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('bank_broken', [householdId, itemId, today]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const admins = await loadMembers(admin, householdId, 'admin');
        const copy = buildCopy('bank_broken', {});
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: admins,
          toggleColumn: 'bank_broken',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, item_id: itemId, screen: screenForType(type) },
          collapseId: `${householdId}:bank_broken`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      case 'budget_increased': {
        const kind = String(body.kind ?? '');
        const oldCents = Number(body.old_cents ?? NaN);
        const newCents = Number(body.new_cents ?? NaN);
        const weekStart = String(body.week_start ?? '');
        if (!kind || !Number.isFinite(oldCents) || !Number.isFinite(newCents)) {
          return json({ error: 'kind, old_cents and new_cents required' }, 400);
        }
        // Only increases notify — never a decrease.
        if (newCents <= oldCents) return json({ ok: true, sent: 0, reason: 'not_an_increase' });
        // Verify the stored value matches the claimed new value.
        if (kind === 'temporary' || kind === 'add') {
          if (!weekStart) return json({ error: 'week_start required' }, 400);
          const { data: override } = await admin
            .from('weekly_allowance_overrides')
            .select('allowance_cents')
            .eq('household_id', householdId)
            .eq('week_start', weekStart)
            .maybeSingle();
          if (!override || override.allowance_cents !== newCents) {
            return json({ error: 'no matching increase found' }, 400);
          }
        } else if (kind === 'base') {
          const { data: household } = await admin
            .from('households')
            .select('base_allowance_cents')
            .eq('id', householdId)
            .maybeSingle();
          if (!household || household.base_allowance_cents !== newCents) {
            return json({ error: 'no matching increase found' }, 400);
          }
        } else {
          return json({ error: 'kind must be temporary, base, or add' }, 400);
        }
        const keyWeek = weekStart || currentWeekStartNY();
        const claimed = await claimKeys(admin, householdId, [
          dedupeKey('budget_increased', [householdId, keyWeek, today]),
        ]);
        if (claimed.length === 0) return json({ ok: true, sent: 0, reason: 'already_sent' });
        const members = await loadMembers(admin, householdId);
        // The admin who made the change already knows — notify the
        // other member(s). (Server-to-server calls have no caller, so
        // everyone is notified.)
        const recipients = user ? members.filter((id) => id !== user.id) : members;
        const copy = buildCopy('budget_increased', {
          addedCents: newCents - oldCents,
          newAllowanceCents: newCents,
        });
        const result = await sendPush(admin, {
          householdId,
          recipientUserIds: recipients,
          toggleColumn: 'budget_increased',
          title: copy.title,
          body: copy.body,
          data: { type, household_id: householdId, week_start: keyWeek, screen: screenForType(type) },
          collapseId: `${householdId}:budget_increased`,
          jwt,
        });
        return json({ ok: true, sent: result.sent });
      }

      default:
        return json({ error: `unknown type ${type}` }, 400);
    }
  } catch (e) {
    console.error('push-notify failed:', (e as Error)?.message ?? e);
    return json({ error: 'could not send notification' }, 500);
  }
});
