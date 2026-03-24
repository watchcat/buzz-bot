(ns buzz-bot.cache)

;; Single IDB connection, opened once at app init.
(defonce db-conn (atom nil))

;; ── Open ─────────────────────────────────────────────────────────────────────

(defn open-db! []
  (js/Promise.
    (fn [resolve reject]
      (let [req (.open js/indexedDB "buzz-audio" 1)]
        (set! (.-onupgradeneeded req)
              (fn [e]
                (let [db (.. e -target -result)]
                  (when-not (.contains (.-objectStoreNames db) "blobs")
                    (.createObjectStore db "blobs")))))
        (set! (.-onsuccess req)
              (fn [e]
                (reset! db-conn (.. e -target -result))
                (resolve (.. e -target -result))))
        (set! (.-onerror req)
              (fn [e] (reject (.. e -target -error))))))))

;; ── Helpers ───────────────────────────────────────────────────────────────────

(defn- store [mode]
  (-> @db-conn (.transaction "blobs" mode) (.objectStore "blobs")))

;; ── Read ─────────────────────────────────────────────────────────────────────

(defn get-blob! [episode-id]
  ;; Resolves with the IDB record object {blob: Blob, episodeId: string}
  ;; or nil if not found / IDB unavailable.
  (js/Promise.
    (fn [resolve _reject]
      (if-not @db-conn
        (resolve nil)
        (let [req (.get (store "readonly") episode-id)]
          (set! (.-onsuccess req) (fn [e] (resolve (.. e -target -result))))
          (set! (.-onerror req)   (fn [_] (resolve nil))))))))

;; ── Write ─────────────────────────────────────────────────────────────────────

(defn put-blob! [episode-id blob]
  (js/Promise.
    (fn [resolve reject]
      (if-not @db-conn
        (reject (js/Error. "IDB not open"))
        (let [req (.put (store "readwrite")
                        #js{:blob blob :episodeId episode-id}
                        episode-id)]
          (set! (.-onsuccess req) (fn [_] (resolve true)))
          (set! (.-onerror req)   (fn [e] (reject (.. e -target -error)))))))))

;; ── Keys ─────────────────────────────────────────────────────────────────────

(defn get-all-keys! []
  ;; Resolves with a JS array of all keys in the blobs store.
  (js/Promise.
    (fn [resolve _reject]
      (if-not @db-conn
        (resolve #js [])
        (let [req (.getAllKeys (store "readonly"))]
          (set! (.-onsuccess req) (fn [e] (resolve (.. e -target -result))))
          (set! (.-onerror req)   (fn [_] (resolve #js []))))))))

;; ── Delete ────────────────────────────────────────────────────────────────────

(defn delete-blob! [episode-id]
  (when @db-conn
    (.delete (store "readwrite") episode-id)))

;; ── Clear all ────────────────────────────────────────────────────────────────

(defn clear-all-blobs! []
  (when @db-conn
    (.clear (store "readwrite"))))
