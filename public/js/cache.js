const DB_NAME       = 'buzz-audio';
const DB_VERSION    = 1;
const STORE_NAME    = 'blobs';
const CACHE_IDS_KEY = 'buzz-cached-ids'; // localStorage index for synchronous checks

function _getCachedIds() {
  try { return JSON.parse(localStorage.getItem(CACHE_IDS_KEY) || '[]'); } catch { return []; }
}
function _saveCachedIds(ids) { localStorage.setItem(CACHE_IDS_KEY, JSON.stringify(ids)); }

function _openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = e => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME, { keyPath: 'id' });
      }
    };
    req.onsuccess = e => resolve(e.target.result);
    req.onerror   = e => reject(e.target.error);
  });
}

// Synchronous — for fast initial UI check (reads localStorage index, not IDB)
function isCachedSync(episodeId) {
  return _getCachedIds().includes(String(episodeId));
}

// Returns a blob: URL if cached, null otherwise. Caller must revoke when done.
async function getCachedBlobUrl(episodeId) {
  if (!isCachedSync(episodeId)) return null;
  try {
    const db = await _openDb();
    const record = await new Promise((resolve, reject) => {
      const req = db.transaction(STORE_NAME, 'readonly')
                    .objectStore(STORE_NAME)
                    .get(String(episodeId));
      req.onsuccess = e => resolve(e.target.result);
      req.onerror   = e => reject(e.target.error);
    });
    if (!record) return null;
    return URL.createObjectURL(record.blob);
  } catch { return null; }
}

// Download via proxy, storing blob in IndexedDB.
// onProgress(0..1) called per chunk; null if Content-Length unknown.
async function downloadAndCache(episodeId, initData, onProgress) {
  const resp = await fetch(`/episodes/${episodeId}/audio_proxy`, {
    headers: { 'X-Init-Data': initData }
  });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

  const total       = parseInt(resp.headers.get('Content-Length') || '0');
  const contentType = resp.headers.get('Content-Type') || 'audio/mpeg';
  const reader      = resp.body.getReader();
  const chunks      = [];
  let received      = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.byteLength;
    onProgress(total > 0 ? received / total : null);
  }

  const blob = new Blob(chunks, { type: contentType });

  const db = await _openDb();
  await new Promise((resolve, reject) => {
    const req = db.transaction(STORE_NAME, 'readwrite')
                  .objectStore(STORE_NAME)
                  .put({ id: String(episodeId), blob, contentType, cachedAt: Date.now() });
    req.onsuccess = () => resolve();
    req.onerror   = e => reject(e.target.error);
  });

  // Request persistent storage so the browser won't evict the DB under pressure
  navigator.storage?.persist?.();

  const ids = _getCachedIds().filter(id => id !== String(episodeId));
  ids.push(String(episodeId));
  _saveCachedIds(ids);
}
