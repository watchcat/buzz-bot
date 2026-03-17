// Offline write queue — buffers failed PUT/POST requests in IndexedDB,
// retries them in order when the network comes back.
// Exposes: window.queuedFetch(url, options) → same signature as fetch()

const DB_NAME    = 'buzz-writes';
const DB_VERSION = 1;
const STORE      = 'queue';

let _db = null;

async function _openDb() {
  if (_db) return _db;
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = e => {
      e.target.result.createObjectStore(STORE, { autoIncrement: true });
    };
    req.onsuccess = e => { _db = e.target.result; resolve(_db); };
    req.onerror   = e => reject(e.target.error);
  });
}

async function _enqueue(url, options) {
  const db    = await _openDb();
  const entry = { url, method: options.method, headers: options.headers, body: options.body };
  return new Promise((resolve, reject) => {
    const tx  = db.transaction(STORE, 'readwrite');
    const req = tx.objectStore(STORE).add(entry);
    req.onsuccess = () => resolve(req.result); // key (auto-increment)
    req.onerror   = e => reject(e.target.error);
  });
}

async function _dequeue(key) {
  const db = await _openDb();
  return new Promise((resolve, reject) => {
    const tx  = db.transaction(STORE, 'readwrite');
    const req = tx.objectStore(STORE).delete(key);
    req.onsuccess = () => resolve();
    req.onerror   = e => reject(e.target.error);
  });
}

async function _getAllEntries() {
  const db = await _openDb();
  return new Promise((resolve, reject) => {
    const tx      = db.transaction(STORE, 'readonly');
    const entries = [];
    tx.objectStore(STORE).openCursor().onsuccess = e => {
      const cursor = e.target.result;
      if (cursor) { entries.push({ key: cursor.key, value: cursor.value }); cursor.continue(); }
      else resolve(entries);
    };
    tx.onerror = e => reject(e.target.error);
  });
}

let _flushing = false;

async function _flush() {
  if (_flushing || !navigator.onLine) return;
  _flushing = true;
  try {
    const entries = await _getAllEntries();
    for (const { key, value } of entries) {
      try {
        const resp = await fetch(value.url, {
          method:  value.method,
          headers: value.headers,
          body:    value.body,
        });
        if (resp.ok || resp.status < 500) {
          // Treat 4xx as permanent failure (bad data); discard rather than retry forever.
          await _dequeue(key);
        } else {
          // Server error — stop and retry next time.
          break;
        }
      } catch {
        // Network error — stop and retry next time.
        break;
      }
    }
  } finally {
    _flushing = false;
  }
}

// ── Public API ────────────────────────────────────────────────────────────────

// Drop-in replacement for fetch() that queues on network failure.
window.queuedFetch = async function queuedFetch(url, options = {}) {
  if (navigator.onLine) {
    try {
      const resp = await fetch(url, options);
      return resp;
    } catch {
      // Fall through to enqueue.
    }
  }
  // Offline or fetch failed — enqueue for later.
  await _enqueue(url, options).catch(() => {}); // ignore IDB errors
  // Return a synthetic 202 so callers don't throw.
  return new Response(null, { status: 202, statusText: 'Queued' });
};

// Flush on page load if online.
if (navigator.onLine) _flush().catch(() => {});

// Flush when connectivity is restored.
window.addEventListener('online', () => _flush().catch(() => {}));
