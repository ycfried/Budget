// OnBudget live service worker — app-shell cache only, no analytics,
// no external requests, no API caching. Network-first: a new deploy
// must actually reach the phone when it is online; the cache is only
// a fallback for when the phone is offline. Bump CACHE when the shell
// changes. (The repo's older sw.js caches demo-era files and must
// NOT be registered for the live app.)
const CACHE = 'onbudget-live-v1';
const SHELL = new Set(['live.html', 'styles.css', 'live.js', 'manifest-live.json', 'icon-192.png', 'icon-512.png', 'apple-touch-icon.png']);
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(['live.html', 'styles.css', 'live.js'])).then(() => self.skipWaiting()).catch(() => {}));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin) return;
  const base = url.pathname.split('/').pop();
  const isShell = SHELL.has(base);
  const isNav = e.request.mode === 'navigate';
  if (!isShell && !isNav) return; // API + everything else passes through untouched
  e.respondWith(fetch(e.request).then((res) => {
    const copy = res.clone();
    caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
    return res;
  }).catch(() => caches.match(e.request).then((hit) => hit || caches.match('live.html'))));
});
