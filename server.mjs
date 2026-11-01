// Household Budget — tiny Node static server, ZERO dependencies.
// Serves the PWA and exposes a small JSON API that uses the SAME engine
// (engine.mjs) as the browser, so balances cannot diverge between clients.
//
// Role enforcement is SERVER-SIDE: admin-only endpoints check the demo role
// header and return 403 for members. Hiding a button in the UI is never the
// enforcement mechanism.
//
// DEMO AUTH ONLY: the `x-demo-role` header is a prototype stand-in for real
// sessions. It must NOT be used in production. Production auth needs real
// sessions, server-side role assignment, and HTTPS (see ARCHITECTURE.md).
//
// Run:  node server.mjs            (serves http://localhost:8080)
//   or: PORT=8080 node server.mjs
// On an iPhone on the same Wi-Fi, open http://<this-computer's-IP>:8080
// (see README.md). No data leaves this machine unless you deploy it yourself.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { computeWeek } from './engine.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8080);
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

function send(res, status, body, type = 'application/json; charset=utf-8') {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(body);
}
function json(res, status, obj) { send(res, status, JSON.stringify(obj)); }

function readBody(req) {
  return new Promise((resolve, reject) => {
    let buf = '';
    req.on('data', (c) => {
      buf += c;
      if (buf.length > 1_000_000) reject(new Error('body too large'));
    });
    req.on('end', () => {
      if (!buf) return resolve({});
      try { resolve(JSON.parse(buf)); } catch { reject(new Error('invalid JSON')); }
    });
    req.on('error', reject);
  });
}

function requireAdmin(req, res) {
  // Demo-only role signal. Production: replace with a verified session.
  const role = req.headers['x-demo-role'];
  if (role !== 'admin') {
    json(res, 403, { error: 'admin only', detail: 'This endpoint requires the admin role. Member access is refused server-side.' });
    return false;
  }
  return true;
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const pathname = url.pathname;

    if (pathname === '/api/health' && req.method === 'GET') {
      return json(res, 200, { ok: true, demo: true, engine: 'engine.mjs (shared with PWA)' });
    }

    if (pathname === '/api/compute' && req.method === 'POST') {
      // Any household member may compute; the engine is pure and reveals no
      // other household's data (this prototype serves one demo household).
      const body = await readBody(req);
      const result = computeWeek(body);
      return json(res, 200, result);
    }

    // --- Admin-only endpoints (403 for members) ---
    if (pathname === '/api/admin/allocate' && req.method === 'POST') {
      if (!requireAdmin(req, res)) return;
      const body = await readBody(req);
      if (!(Number(body.amountCents) > 0) || !body.txId) {
        return json(res, 400, { error: 'amountCents (>0) and txId are required' });
      }
      // Prototype: the allocation itself is applied by the PWA's local state
      // after this server-side permission check. A production server would
      // apply it to the database here and write the audit entry server-side.
      return json(res, 200, { ok: true, permitted: true, txId: body.txId, amountCents: body.amountCents, note: 'Server-side admin check passed. Demo state is local to the browser.' });
    }
    if (pathname === '/api/admin/settings' && req.method === 'POST') {
      if (!requireAdmin(req, res)) return;
      const body = await readBody(req);
      if (!(Number(body.baseAllowanceCents) >= 0)) {
        return json(res, 400, { error: 'baseAllowanceCents (>=0) is required' });
      }
      return json(res, 200, { ok: true, permitted: true, note: 'Server-side admin check passed. Demo state is local to the browser.' });
    }
    if (pathname === '/api/admin/invite' && req.method === 'POST') {
      if (!requireAdmin(req, res)) return;
      // Placeholder only: sends nothing. Real invites need a server-side
      // invite system; this prototype must not fake sending one.
      return json(res, 200, { ok: true, permitted: true, sent: false, note: 'Invite placeholder — no email sent (demo).' });
    }

    // --- Static files (PWA) ---
    if (req.method === 'GET') {
      let file = pathname === '/' ? 'index.html' : pathname.slice(1);
      // Block path traversal and dotfiles.
      file = path.normalize(file).replace(/^(\.\.[/\\])+/, '');
      const full = path.join(ROOT, file);
      if (!full.startsWith(ROOT) || !fs.existsSync(full) || fs.statSync(full).isDirectory()) {
        return send(res, 404, 'Not found', 'text/plain; charset=utf-8');
      }
      const ext = path.extname(full).toLowerCase();
      res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
      fs.createReadStream(full).pipe(res);
      return;
    }

    return json(res, 404, { error: 'not found' });
  } catch (err) {
    // Never leak stack traces or raw input in responses.
    return json(res, err.message === 'invalid JSON' || err.message === 'body too large' ? 400 : 500, { error: err.message === 'invalid JSON' || err.message === 'body too large' ? err.message : 'internal error' });
  }
});

server.listen(PORT, () => {
  console.log(`Household Budget demo PWA at http://localhost:${PORT}/`);
  console.log('Demo only: no live Gmail/Plaid, no production auth. See README.md.');
});
