# Semantic Inbox Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a search box to the inbox page that re-sorts episodes by semantic similarity to a text query, powered by a lightweight Python sidecar that embeds the query using the same model as the episode embeddings.

**Architecture:** A FastAPI sidecar loads all-MiniLM-L6-v2 and exposes a `/embed` endpoint. The Crystal server calls it synchronously when handling `GET /inbox/search?q=...`, then queries pgvector to re-rank inbox episodes by cosine similarity. The frontend adds a debounced search input above the inbox filters.

**Tech Stack:** Python/FastAPI/sentence-transformers (sidecar), Crystal/Kemal (backend), ClojureScript/Reagent/re-frame (frontend), pgvector (Postgres)

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `embed-sidecar/handler.py` | FastAPI app with `/embed` endpoint |
| Create | `embed-sidecar/requirements.txt` | Python dependencies |
| Create | `embed-sidecar/Dockerfile` | Container image with pre-downloaded model |
| Create | `embed-sidecar/VERSION` | Image version tag |
| Create | `embed-sidecar/build.sh` | Build and push script |
| Create | `k8s/embed-sidecar-deployment.yaml` | k8s Deployment + Service |
| Modify | `src/config.cr:73-79` | Add `embed_sidecar_url` accessor |
| Modify | `src/models/episode.cr` | Add `for_inbox_semantic` query method |
| Modify | `src/web/routes/inbox.cr` | Add `GET /inbox/search` endpoint |
| Modify | `src/cljs/buzz_bot/db.cljs:8-9` | Add `:search-query` to inbox state |
| Modify | `src/cljs/buzz_bot/events.cljs:62-84` | Add `::search-inbox` event |
| Modify | `src/cljs/buzz_bot/views/inbox.cljs:82-138` | Add search input |

---

### Task 1: Embed Sidecar Service

**Files:**
- Create: `embed-sidecar/handler.py`
- Create: `embed-sidecar/requirements.txt`
- Create: `embed-sidecar/Dockerfile`
- Create: `embed-sidecar/VERSION`
- Create: `embed-sidecar/build.sh`

- [ ] **Step 1: Create requirements.txt**

Create `embed-sidecar/requirements.txt`:

```
fastapi==0.115.0
uvicorn==0.30.6
sentence-transformers==3.0.1
torch==2.3.1
numpy<2
```

- [ ] **Step 2: Create handler.py**

Create `embed-sidecar/handler.py`:

```python
# embed-sidecar/handler.py
import os
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

MODEL_NAME = os.environ.get("MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")

app = FastAPI()
model = None


def get_model():
    global model
    if model is None:
        model = SentenceTransformer(MODEL_NAME)
    return model


class EmbedRequest(BaseModel):
    text: str


class EmbedResponse(BaseModel):
    vector: list[float]


@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest):
    m = get_model()
    vec = m.encode([req.text], normalize_embeddings=True)[0]
    return EmbedResponse(vector=vec.tolist())


@app.get("/health")
def health():
    return {"ok": True}
```

- [ ] **Step 3: Create Dockerfile**

Create `embed-sidecar/Dockerfile`:

```dockerfile
# embed-sidecar/Dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download model at build time
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2')"

COPY handler.py .
COPY VERSION .

ARG VERSION=dev
LABEL version=$VERSION

CMD ["uvicorn", "handler:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 4: Create VERSION file**

Create `embed-sidecar/VERSION`:

```
1.0
```

(With trailing newline)

- [ ] **Step 5: Create build.sh**

Create `embed-sidecar/build.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

VERSION=$(cat VERSION)
IMAGE="watchcat/embed-sidecar:${VERSION}"

echo "Building ${IMAGE} for linux/amd64..."
docker buildx build --platform linux/amd64 --build-arg VERSION="${VERSION}" -t "${IMAGE}" --push .

echo "Pushed ${IMAGE}"
```

Make it executable:

```bash
chmod +x embed-sidecar/build.sh
```

- [ ] **Step 6: Test locally**

```bash
cd embed-sidecar
nix-shell -p python311 python311Packages.pip --run "
  pip install -r requirements.txt --quiet
  python -c \"
from handler import get_model, EmbedRequest
m = get_model()
vec = m.encode(['economics and trade'], normalize_embeddings=True)[0]
print(f'Vector dims: {len(vec)}')
assert len(vec) == 384
print('OK')
\"
"
```

Expected: `Vector dims: 384`, `OK`

- [ ] **Step 7: Commit**

```bash
git add embed-sidecar/
git commit -m "feat: add embed-sidecar FastAPI service for query embedding"
```

---

### Task 2: k8s Deployment for Sidecar

**Files:**
- Create: `k8s/embed-sidecar-deployment.yaml`

- [ ] **Step 1: Create the deployment manifest**

Create `k8s/embed-sidecar-deployment.yaml`:

```yaml
# k8s/embed-sidecar-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: embed-sidecar
  namespace: buzz-bot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: embed-sidecar
  template:
    metadata:
      labels:
        app: embed-sidecar
    spec:
      containers:
      - name: sidecar
        image: watchcat/embed-sidecar:1.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8000
        resources:
          requests:
            memory: "512Mi"
          limits:
            memory: "1Gi"
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: embed-sidecar
  namespace: buzz-bot
spec:
  selector:
    app: embed-sidecar
  ports:
  - port: 8000
    targetPort: 8000
```

- [ ] **Step 2: Commit**

```bash
git add k8s/embed-sidecar-deployment.yaml
git commit -m "feat: add k8s deployment for embed-sidecar"
```

---

### Task 3: Backend — Config and Semantic Inbox Query

**Files:**
- Modify: `src/config.cr:73-79`
- Modify: `src/models/episode.cr`
- Modify: `src/web/routes/inbox.cr`

- [ ] **Step 1: Add sidecar URL config**

In `src/config.cr`, add after the `internal_webhook_secret` method (after line 79):

```crystal
def self.embed_sidecar_url : String
  ENV.fetch("EMBED_SIDECAR_URL", "http://embed-sidecar.buzz-bot.svc.cluster.local:8000")
end
```

- [ ] **Step 2: Add semantic inbox query to Episode model**

In `src/models/episode.cr`, add after the `for_inbox` method (after line 104):

```crystal
def self.for_inbox_semantic(user_id : Int64, query_vec : Array(Float64), limit : Int32 = 100, offset : Int32 = 0) : Array(Episode)
  vector_str = "[#{query_vec.join(",")}]"
  episodes = [] of Episode
  AppDB.pool.query_each(
    <<-SQL,
      SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url
      FROM episodes e
      JOIN user_feeds uf ON uf.feed_id = e.feed_id
      LEFT JOIN episode_embeddings ee ON ee.episode_id = e.id
      WHERE uf.user_id = $1
      ORDER BY (1 - (ee.embedding <=> $2::vector)) DESC NULLS LAST
      LIMIT $3 OFFSET $4
    SQL
    user_id, vector_str, limit, offset
  ) { |rs| episodes << from_rs(rs) }
  episodes
end
```

- [ ] **Step 3: Add search endpoint to inbox routes**

In `src/web/routes/inbox.cr`, add the search endpoint inside the `register` method, after the existing `/inbox` route (after line 19, before `end`):

```crystal
get "/inbox/search" do |env|
  user = Auth.current_user(env)
  halt env, status_code: 401, response: "Unauthorized" unless user

  query = env.params.query["q"]?.to_s.strip
  halt env, status_code: 400, response: %({"error":"q required"}) if query.empty?

  limit  = (env.params.query["limit"]?.try(&.to_i32) || 100).clamp(1, 500)
  offset = env.params.query["offset"]?.try(&.to_i32) || 0

  # Call embed sidecar to get query vector
  sidecar_url = Config.embed_sidecar_url
  sidecar_resp = HTTP::Client.post(
    "#{sidecar_url}/embed",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
    body: {text: query}.to_json
  )

  unless sidecar_resp.success?
    Log.error { "Embed sidecar failed: #{sidecar_resp.status_code}" }
    halt env, status_code: 502, response: %({"error":"Embedding service unavailable"})
  end

  query_vec = JSON.parse(sidecar_resp.body)["vector"].as_a.map(&.as_f)

  episodes = Episode.for_inbox_semantic(user.id, query_vec, limit + 1, offset)
  has_more = episodes.size > limit
  episodes = episodes.first(limit) if has_more

  items = Web.build_episode_list(episodes, user.id)

  env.response.content_type = "application/json"
  {episodes: items, has_more: has_more}.to_json
end
```

Also add `require "http/client"` at the top of the file if not already present. The current file starts with `require "json"` — add after it:

```crystal
require "http/client"
```

- [ ] **Step 4: Build to verify compilation**

```bash
nix-shell -p crystal shards pkg-config openssl --run 'crystal build src/buzz_bot.cr --no-codegen'
```

Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add src/config.cr src/models/episode.cr src/web/routes/inbox.cr
git commit -m "feat: add semantic inbox search endpoint with sidecar embedding"
```

---

### Task 4: Frontend — Search Input and Event

**Files:**
- Modify: `src/cljs/buzz_bot/db.cljs:8-9`
- Modify: `src/cljs/buzz_bot/events.cljs:62-84`
- Modify: `src/cljs/buzz_bot/views/inbox.cljs:82-138`

- [ ] **Step 1: Add search-query to default DB**

In `src/cljs/buzz_bot/db.cljs`, update the `:inbox` map (line 8) from:

```clojure
:inbox       {:episodes [] :loading? false
              :filters  {:hide-listened? false :compact? false :excluded-feeds #{}}}
```

To:

```clojure
:inbox       {:episodes [] :loading? false :search-query ""
              :filters  {:hide-listened? false :compact? false :excluded-feeds #{}}}
```

- [ ] **Step 2: Add search-inbox event**

In `src/cljs/buzz_bot/events.cljs`, add after the `::inbox-loaded` event (after line 84):

```clojure
(rf/reg-event-fx
 ::search-inbox
 (fn [{:keys [db]} [_ query]]
   {:db (-> db
            (assoc-in [:inbox :loading?] true)
            (assoc-in [:inbox :search-query] query))
    ::buzz-bot.fx/http-fetch {:method :get
                              :url    (str "/inbox/search?q=" (js/encodeURIComponent query))
                              :on-ok  [::inbox-loaded] :on-err [::fetch-error]}}))
```

This reuses `::inbox-loaded` to store results — same response shape.

- [ ] **Step 3: Update fetch-inbox to clear search query**

In `src/cljs/buzz_bot/events.cljs`, update the `::fetch-inbox` event (lines 63-72). Replace:

```clojure
(rf/reg-event-fx
 ::fetch-inbox
 (fn [{:keys [db]} _]
   (let [saved (:saved-list db)
         limit (when (and (= (:view saved) :inbox) (pos? (:count saved)))
                 (:count saved))
         url   (if limit (str "/inbox?limit=" limit) "/inbox")]
     {:db         (assoc-in db [:inbox :loading?] true)
      ::buzz-bot.fx/http-fetch {:method :get :url url
                                :on-ok  [::inbox-loaded] :on-err [::fetch-error]}})))
```

With:

```clojure
(rf/reg-event-fx
 ::fetch-inbox
 (fn [{:keys [db]} _]
   (let [saved (:saved-list db)
         limit (when (and (= (:view saved) :inbox) (pos? (:count saved)))
                 (:count saved))
         url   (if limit (str "/inbox?limit=" limit) "/inbox")]
     {:db         (-> db
                      (assoc-in [:inbox :loading?] true)
                      (assoc-in [:inbox :search-query] ""))
      ::buzz-bot.fx/http-fetch {:method :get :url url
                                :on-ok  [::inbox-loaded] :on-err [::fetch-error]}})))
```

- [ ] **Step 4: Add search input to inbox view**

In `src/cljs/buzz_bot/views/inbox.cljs`, the `view` function needs to become a form-2 component to hold the debounce timer. Replace the entire `view` function (lines 82-138) with:

```clojure
(defn view []
  (let [expanded-feeds (r/atom #{})
        query-atom     (r/atom "")
        debounce       (r/atom nil)]
    (fn []
      (let [episodes   @(rf/subscribe [::subs/inbox-episodes])
            loading?   @(rf/subscribe [::subs/inbox-loading?])
            filters    @(rf/subscribe [::subs/inbox-filters])
            playing-id @(rf/subscribe [::subs/audio-episode-id])
            cached-ids @(rf/subscribe [::subs/cached-ids])
            {:keys [hide-listened? compact?]} filters
            visible    (filter #(episode-visible? % filters) episodes)]
        [:div.episodes-container
         [:div.section-header
          [:div.section-header-row
           [:h2 "Inbox"]
           (when (seq cached-ids)
             [:button.btn-clear-cache
              {:title    "Clear cached audio"
               :on-click #(rf/dispatch [::events/audio-cache-clear-all])}
              "🗑"])
           [:button.btn-icon
            {:title    "Refresh"
             :class    (when loading? "btn-icon--spinning")
             :on-click (fn [_]
                         (reset! query-atom "")
                         (rf/dispatch [::events/fetch-inbox]))}
            "↻"]
           [:div.section-controls
            [:label.filter-label
             {:on-click (fn [e]
                          (.preventDefault e)
                          (rf/dispatch [::events/toggle-hide-listened]))}
             [:input.filter-checkbox
              {:type      "checkbox"
               :checked   hide-listened?
               :read-only true}]
             [:span.filter-switch]
             [:span.filter-text "Hide\u00a0✓"]]
            [:label.filter-label
             {:on-click (fn [e]
                          (.preventDefault e)
                          (reset! expanded-feeds #{})
                          (rf/dispatch [::events/toggle-compact]))}
             [:input.filter-checkbox
              {:type      "checkbox"
               :checked   compact?
               :read-only true}]
             [:span.filter-switch]
             [:span.filter-text "Compact"]]]]]
         [:div.search-section
          [:input.search-input
           {:type        "search"
            :placeholder "Search episodes..."
            :value       @query-atom
            :on-change   (fn [e]
                           (let [v (.. e -target -value)]
                             (reset! query-atom v)
                             (when @debounce (js/clearTimeout @debounce))
                             (if (empty? v)
                               (rf/dispatch [::events/fetch-inbox])
                               (reset! debounce
                                 (js/setTimeout
                                   #(rf/dispatch [::events/search-inbox v])
                                   300)))))}]]
         (cond
           loading?         [:div.loading "Loading..."]
           (empty? visible) [:div.empty-msg "No episodes. Subscribe to some feeds!"]
           :else
           [:ul#episode-list.episode-list
            (if compact?
              (let [groups (partition-by :feed_id visible)]
                (for [grp groups]
                  (compact-group grp playing-id expanded-feeds cached-ids)))
              (for [ep visible]
                ^{:key (:id ep)} [episode-item ep playing-id cached-ids]))])]))))
```

Key changes:
- Added `query-atom` and `debounce` atoms
- Added `[:div.search-section ...]` with a search input between the header and the episode list
- 300ms debounce dispatches `::search-inbox` with the query
- Clearing the input dispatches `::fetch-inbox` immediately (restores chronological order)
- Refresh button also clears the search query

- [ ] **Step 5: Compile ClojureScript**

```bash
npx shadow-cljs release app
```

Expected: Build success, 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add src/cljs/buzz_bot/db.cljs src/cljs/buzz_bot/events.cljs src/cljs/buzz_bot/views/inbox.cljs
git add -f public/js/main.js
git commit -m "feat: add semantic search input to inbox page"
```

---

### Task 5: Build, Deploy, and Verify

- [ ] **Step 1: Build and push the sidecar image**

```bash
bash embed-sidecar/build.sh
```

- [ ] **Step 2: Import sidecar image to k3s node**

If using Docker Hub, the k3s node needs to pull the image. Either:

```bash
docker save watchcat/embed-sidecar:1.0 -o /tmp/embed-sidecar.tar
scp /tmp/embed-sidecar.tar root@46.225.0.50:/tmp/
ssh root@46.225.0.50 "k3s ctr images import /tmp/embed-sidecar.tar && rm /tmp/embed-sidecar.tar"
```

Or pull directly on the node:

```bash
ssh root@46.225.0.50 "k3s ctr images pull docker.io/watchcat/embed-sidecar:1.0"
```

- [ ] **Step 3: Deploy the sidecar**

```bash
KUBECONFIG=k8s/kubeconfig kubectl apply -f k8s/embed-sidecar-deployment.yaml
```

Verify it's running:

```bash
KUBECONFIG=k8s/kubeconfig kubectl -n buzz-bot get pods -l app=embed-sidecar
```

Expected: 1/1 Running

- [ ] **Step 4: Add EMBED_SIDECAR_URL to buzz-bot env**

The default URL (`http://embed-sidecar.buzz-bot.svc.cluster.local:8000`) should work if the sidecar Service is in the same namespace. No env var change needed unless using a custom URL.

- [ ] **Step 5: Deploy the Crystal app**

```bash
bash k8s/deploy.sh
```

- [ ] **Step 6: Verify the search endpoint**

```bash
curl -s "https://app.buzz-bot.top/inbox/search?q=economics" \
  -H "X-Init-Data: <your-init-data>" | jq '.episodes | length'
```

Expected: A number (up to 100 episodes, re-ranked by similarity).

- [ ] **Step 7: Test in the app**

Open the inbox in the Telegram Mini App. Type "economics" in the search box. Episodes should re-sort with economics-related episodes at the top. Clear the search box — episodes should return to chronological order.

- [ ] **Step 8: Commit any remaining changes and push**

```bash
git push
```
