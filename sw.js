// Household Budget PWA service worker — app-shell cache only, no network
// analytics, no external requests. Bump CACHE when the shell changes.
const CACHE = 'hb-demo-v2';
const SHELL = ['.', 'index.html', 'styles.css', 'app.js', 'engine.mjs', 'manifest.json', 'icon.svg'];
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  // Network-first: a new deploy must actually reach the phone. The cache
  // is only a fallback for when the phone is offline.
  e.respondWith(fetch(e.request).then((res) => {
    const copy = res.clone();
    caches.open(CACHE).then((c) => c.put(e.request, copy));
    return res;
  }).catch(() => caches.match(e.request).then((hit) => hit || caches.match('index.html'))));
});
