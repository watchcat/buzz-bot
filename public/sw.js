const STATIC_CACHE = 'buzz-static-v1';
const HTML_CACHE   = 'buzz-html-v1';

// Precache the app shell and vendored scripts on install so the app works
// offline immediately after the first online visit.
const PRECACHE_ASSETS = [
  '/js/telegram-web-app.js',
  '/js/htmx.min.js',
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(STATIC_CACHE)
      .then(cache => cache.addAll(PRECACHE_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

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
  // Cache key strips initData: Telegram rotates it each session so the raw URL
  // would never match a previously cached response.
  const HTML_PREFIXES = ['/', '/app', '/inbox', '/feeds', '/episodes', '/discover'];
  if (HTML_PREFIXES.some(p => url.pathname === p || url.pathname.startsWith(p + '/'))) {
    e.respondWith(_networkFirst(request, HTML_CACHE));
    return;
  }
});

// Strip initData from the URL before using it as a cache key.
// initData is a Telegram auth token that rotates each session — without this,
// every new session would miss the cache even for identical page content.
function _htmlCacheKey(request) {
  const url = new URL(request.url);
  url.searchParams.delete('initData');
  return url.toString();
}

// ── Strategies ────────────────────────────────────────────────────────────────

async function _cacheFirst(request, cacheName) {
  const cached = await caches.match(request);
  if (cached) return cached;

  const resp = await fetch(request);
  if (resp.ok) (await caches.open(cacheName)).put(request, resp.clone());
  return resp;
}

async function _networkFirst(request, cacheName) {
  const cacheKey = _htmlCacheKey(request);
  try {
    const resp = await fetch(request);
    if (resp.ok) (await caches.open(cacheName)).put(cacheKey, resp.clone());
    return resp;
  } catch {
    const cached = await caches.match(cacheKey);
    return cached ?? new Response(
      '<div class="error-msg">You\'re offline and this page hasn\'t been cached yet.</div>',
      { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
    );
  }
}
