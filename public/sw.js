// Cleanup service worker — clears all caches, takes immediate control,
// then unregisters itself so no SW runs after this.
self.addEventListener('install', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.map(k => caches.delete(k))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    self.clients.claim()
      .then(() => self.registration.unregister())
  );
});
