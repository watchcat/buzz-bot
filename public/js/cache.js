const CACHE_NAME    = 'buzz-audio-v1';
const CACHE_IDS_KEY = 'buzz-cached-ids'; // localStorage: JSON array of episode ID strings

function _getCachedIds() {
  try { return JSON.parse(localStorage.getItem(CACHE_IDS_KEY) || '[]'); } catch { return []; }
}
function _saveCachedIds(ids) { localStorage.setItem(CACHE_IDS_KEY, JSON.stringify(ids)); }
function _cacheKey(id) { return `/cached-audio/${id}`; }

// Synchronous — for fast initial UI check
function isCachedSync(episodeId) {
  return _getCachedIds().includes(String(episodeId));
}

// Returns a blob: URL if cached, null otherwise. Caller must revoke when done.
async function getCachedBlobUrl(episodeId) {
  if (!('caches' in window) || !isCachedSync(episodeId)) return null;
  try {
    const cache    = await caches.open(CACHE_NAME);
    const response = await cache.match(_cacheKey(episodeId));
    if (!response) return null;
    return URL.createObjectURL(await response.blob());
  } catch { return null; }
}

// Download via proxy, storing in CacheStorage.
// onProgress(0..1) called per chunk; null argument if Content-Length unknown.
async function downloadAndCache(episodeId, initData, onProgress) {
  if (!('caches' in window)) throw new Error('Cache API not available');
  const resp = await fetch(`/episodes/${episodeId}/audio_proxy`, {
    headers: { 'X-Init-Data': initData }
  });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

  const total       = parseInt(resp.headers.get('Content-Length') || '0');
  const contentType = resp.headers.get('Content-Type') || 'audio/mpeg';
  const reader = resp.body.getReader();
  const chunks = [];
  let received = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.byteLength;
    onProgress(total > 0 ? received / total : null);
  }

  const blob = new Blob(chunks, { type: contentType });
  const cache = await caches.open(CACHE_NAME);
  await cache.put(_cacheKey(episodeId), new Response(blob, { headers: { 'Content-Type': contentType } }));

  const ids = _getCachedIds().filter(id => id !== String(episodeId));
  ids.push(String(episodeId));
  _saveCachedIds(ids);
}
