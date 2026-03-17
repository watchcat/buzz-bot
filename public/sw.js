const STATIC_CACHE = 'buzz-static-v1';
const HTML_CACHE   = 'buzz-html-v1';

// Take control immediately — no need to wait for existing SW to retire
self.addEventListener('install',  ()  => self.skipWaiting());
self.addEventListener('activate', e   => e.waitUntil(self.clients.claim()));

self.addEventListener('fetch', e => {
  const { request } = e;
  const url = new URL(request.url);

  // Only handle same-origin GETs
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;

  // Never intercept: audio proxy (IndexedDB in cache.js owns that) or webhooks
  if (url.pathname.includes('/audio_proxy') || url.pathname.startsWith('/webhook')) return;

  // Static assets (JS/CSS) — cache-first.
  // Version query params (?v=TIMESTAMP) mean a new deploy = new URL = cache miss,
  // so stale assets are never served after a deploy.
  if (url.pathname.startsWith('/js/') || url.pathname.startsWith('/css/')) {
    e.respondWith(_cacheFirst(request, STATIC_CACHE));
    return;
  }

  // HTML pages and HTMX fragments — network-first, fall back to cached copy.
  // Covers the app shell, inbox, feeds, episode lists, player, discover.
  const HTML_PREFIXES = ['/', '/app', '/inbox', '/feeds', '/episodes', '/discover'];
  if (HTML_PREFIXES.some(p => url.pathname === p || url.pathname.startsWith(p + '/'))) {
    e.respondWith(_networkFirst(request, HTML_CACHE));
    return;
  }
});

// ── Strategies ────────────────────────────────────────────────────────────────

async function _cacheFirst(request, cacheName) {
  const cached = await caches.match(request);
  if (cached) return cached;

  const resp = await fetch(request);
  if (resp.ok) (await caches.open(cacheName)).put(request, resp.clone());
  return resp;
}

async function _networkFirst(request, cacheName) {
  try {
    const resp = await fetch(request);
    if (resp.ok) (await caches.open(cacheName)).put(request, resp.clone());
    return resp;
  } catch {
    const cached = await caches.match(request);
    return cached ?? new Response(
      '<div class="error-msg">You\'re offline and this page hasn\'t been cached yet.</div>',
      { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
    );
  }
}
