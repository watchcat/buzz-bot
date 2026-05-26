const SHELL_CACHE = 'buzz-shell-v1';
const API_CACHE   = 'buzz-api-v1';
const AUDIO_CACHE = 'buzz-audio-v1';
const IMG_CACHE   = 'buzz-img-v1';
const KEEP_CACHES = new Set([SHELL_CACHE, API_CACHE, AUDIO_CACHE, IMG_CACHE]);

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(SHELL_CACHE)
      .then(c => c.addAll(['/app', '/js/telegram-web-app.js']))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => !KEEP_CACHES.has(k)).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);

  if (url.origin !== self.location.origin || req.method !== 'GET') return;

  // Audio cache endpoint — cache-first (pre-populated by download effect)
  if (/^\/episodes\/\d+\/audio$/.test(url.pathname)) {
    event.respondWith(cacheFirst(AUDIO_CACHE, req));
    return;
  }

  // Versioned static assets — cache-first
  if (url.pathname.startsWith('/js/') || url.pathname.startsWith('/css/')) {
    event.respondWith(cacheFirst(SHELL_CACHE, req));
    return;
  }

  // Audio proxy — streaming download, must not be cached by networkFirst
  if (/^\/episodes\/\d+\/audio_proxy$/.test(url.pathname)) return;

  // Image proxy — stale-while-revalidate. Podcast artwork rarely changes;
  // serving from cache instantly eliminates the per-navigation thundering
  // herd through upstream CDNs (seen as 50+ slow img-proxy fetches per
  // feed-list view in production). Background refresh keeps cache fresh.
  if (url.pathname === '/img-proxy') {
    event.respondWith(staleWhileRevalidate(IMG_CACHE, req));
    return;
  }

  // HTML + API — network-first, stale fallback
  event.respondWith(networkFirst(req));
});

// Map<url, Promise<Response>> — collapses concurrent SW fetches for the
// same URL into one upstream request. Defeats the cold-cache race where
// two near-simultaneous img loads each pass through networkFirst/SWR and
// both hit upstream before either response is committed to cache.
const inFlight = new Map();
function coalescedFetch(url, request) {
  let p = inFlight.get(url);
  if (!p) {
    p = fetch(request).finally(() => inFlight.delete(url));
    inFlight.set(url, p);
  }
  // Each caller needs its own readable body.
  return p.then(resp => resp.clone());
}

async function staleWhileRevalidate(cacheName, request) {
  const cache  = await caches.open(cacheName);
  const cached = await cache.match(new Request(request.url));
  const refresh = coalescedFetch(request.url, request).then(resp => {
    if (resp.ok) cache.put(new Request(request.url), resp.clone());
    return resp;
  }).catch(() => null);
  if (cached) return cached;
  return (await refresh) || new Response('Offline', { status: 503 });
}

async function cacheFirst(cacheName, request) {
  const cache  = await caches.open(cacheName);
  // Match by URL only — Range header must not affect cache lookup
  const cached = await cache.match(new Request(request.url));
  if (cached) {
    const range = request.headers.get('range');
    if (range) return rangeResponse(cached, range);
    return cached;
  }
  try {
    const resp = await fetch(request);
    if (resp.ok) cache.put(new Request(request.url), resp.clone());
    return resp;
  } catch (_) {
    return new Response('Offline', { status: 503 });
  }
}

// Serve a byte-range slice from a fully-cached response.
// Audio elements seek by issuing Range requests; without this the browser
// receives a 200 with the full file and restarts playback from byte 0.
async function rangeResponse(fullResp, rangeHeader) {
  const buf   = await fullResp.arrayBuffer();
  const total = buf.byteLength;
  const [, a, b] = rangeHeader.match(/bytes=(\d*)-(\d*)/) || [];
  const start = a ? parseInt(a, 10) : 0;
  const end   = b ? Math.min(parseInt(b, 10), total - 1) : total - 1;
  return new Response(buf.slice(start, end + 1), {
    status:  206,
    headers: {
      'Content-Type':   fullResp.headers.get('Content-Type') || 'audio/mpeg',
      'Content-Range':  `bytes ${start}-${end}/${total}`,
      'Content-Length': String(end - start + 1),
      'Accept-Ranges':  'bytes',
    },
  });
}

async function networkFirst(request) {
  const cache = await caches.open(API_CACHE);
  try {
    const resp = await fetch(request);
    if (resp.ok) {
      // Key by URL only — X-Init-Data header must not affect cache matching
      cache.put(new Request(request.url), resp.clone());
    }
    return resp;
  } catch (_) {
    const cached = await cache.match(new Request(request.url));
    return cached || new Response(
      JSON.stringify({ error: 'offline' }),
      { status: 503, headers: { 'Content-Type': 'application/json' } }
    );
  }
}
