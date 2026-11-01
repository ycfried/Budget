// Household Budget PWA service worker — app-shell cache only, no network
// analytics, no external requests. Bump CACHE when the shell changes.
const CACHE = 'hb-demo-v1';
const SHELL = ['.', 'index.html', 'styles.css', 'app.js', 'engine.mjs', 'manifest.json', 'icon.svg'];
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  e.respondWith(caches.match(e.request).then((hit) => hit || fetch(e.request).catch(() => caches.match('index.html'))));
});
