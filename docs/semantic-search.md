# Semantic Search

Buzz-Bot's inbox search ranks episodes by **meaning**, not keyword match. When you
type a query, it is embedded into the same 1024-dim vector space as your episodes,
and your inbox is re-ordered by cosine similarity to that query.

This document covers the **query-time path** — how a typed query becomes ranked
results. For how episodes get embedded in the first place (the BGE-M3 pipeline,
storage schema, and HNSW index), see [Recommendations](RECOMMENDATIONS.md), which
shares the same embedding stack.

## At a glance

| Stage | Where |
|-------|-------|
| Search input + 300 ms debounce | `src/cljs/buzz_bot/views/inbox.cljs` |
| `::search-inbox` event → `GET /inbox/search?q=…` | `src/cljs/buzz_bot/events.cljs` |
| Route: embed the query, run the ranked SQL | `src/web/routes/inbox.cr` |
| Query embedding (BGE-M3) | `embed-sidecar/handler.py` |
| Vector-ranked SQL over your subscriptions | `src/models/episode.cr` (`for_inbox_semantic`) |
| Stored episode vectors + HNSW index | `episode_embeddings` table (see [Recommendations](RECOMMENDATIONS.md)) |

## End-to-end flow

```
User types "ancient flood myths"
        │  (300 ms debounce, src/cljs/buzz_bot/views/inbox.cljs)
        ▼
::search-inbox  ──►  GET /inbox/search?q=ancient%20flood%20myths
        │            (src/cljs/buzz_bot/events.cljs)
        ▼
Crystal route  (src/web/routes/inbox.cr)
        │  POST { text } ─► embed-sidecar /embed
        ▼
embed-sidecar  (BGE-M3, normalize_embeddings=True) ─► 1024-dim vector
        │
        ▼
Episode.for_inbox_semantic(user_id, query_vec, limit, offset)
        │  ORDER BY (1 - (embedding <=> $query)) DESC NULLS LAST
        ▼
Postgres + pgvector (HNSW cosine index on episode_embeddings)
        │
        ▼
{ episodes: [...], has_more } ─► ::inbox-loaded ─► inbox re-renders
```

## 1. Frontend — debounced search input

The inbox search box keeps a local `query-atom` and a `debounce` timer. On every
keystroke it clears the pending timer and:

- **empty input** → dispatches `::fetch-inbox` immediately (restore chronological order),
- **non-empty input** → schedules `::search-inbox` after **300 ms** of idle typing.

`src/cljs/buzz_bot/views/inbox.cljs`:

```clojure
:on-change (fn [e]
             (let [v (.. e -target -value)]
               (reset! query-atom v)
               (when @debounce (js/clearTimeout @debounce))
               (if (empty? v)
                 (rf/dispatch [::events/fetch-inbox])
                 (reset! debounce
                   (js/setTimeout
                     #(rf/dispatch [::events/search-inbox v])
                     300)))))
```

`::search-inbox` sets `:loading?`, stores the query, and fires the HTTP request;
`::inbox-loaded` writes the returned episodes back into the inbox
(`src/cljs/buzz_bot/events.cljs`):

```clojure
(rf/reg-event-fx
 ::search-inbox
 (fn [{:keys [db]} [_ query]]
   {:db (-> db (assoc-in [:inbox :loading?] true)
               (assoc-in [:inbox :search-query] query))
    ::buzz-bot.fx/http-fetch {:method :get
                              :url (str "/inbox/search?q=" (js/encodeURIComponent query))
                              :on-ok [::inbox-loaded]}}))
```

Search and the plain inbox share `::inbox-loaded` and the `::inbox-episodes`
subscription, so the result list renders through the same component either way.

## 2. Route — embed the query, then rank

`GET /inbox/search` (`src/web/routes/inbox.cr`) is auth-gated, requires a non-empty
`q`, and supports `limit` (clamped 1–500, default 100) and `offset`. It embeds the
query **synchronously** via the in-cluster sidecar, then asks the model layer for a
vector-ranked page:

```crystal
get "/inbox/search" do |env|
  user = Auth.current_user(env)
  halt env, status_code: 401, response: "Unauthorized" unless user

  query = env.params.query["q"]?.to_s.strip
  halt env, status_code: 400, response: %({"error":"q required"}) if query.empty?

  limit  = (env.params.query["limit"]?.try(&.to_i32) || 100).clamp(1, 500)
  offset = env.params.query["offset"]?.try(&.to_i32) || 0

  # Call embed sidecar to get query vector
  sidecar_resp = HTTP::Client.post(
    "#{Config.embed_sidecar_url}/embed",
    headers: HTTP::Headers{"Content-Type" => "application/json"},
    body: {text: query}.to_json
  )
  halt env, status_code: 502, ... unless sidecar_resp.success?

  query_vec = JSON.parse(sidecar_resp.body)["vector"].as_a.map(&.as_f)

  episodes = Episode.for_inbox_semantic(user.id, query_vec, limit + 1, offset)
  has_more = episodes.size > limit
  episodes = episodes.first(limit) if has_more

  {episodes: Web.build_episode_list(episodes, user.id), has_more: has_more}.to_json
end
```

`has_more` is detected by over-fetching one row (`limit + 1`) and trimming it off.
If the sidecar is unreachable the route returns **502** — search degrades loudly
rather than silently falling back to keyword matching.

## 3. Query embedding — the sidecar

Queries are embedded by a small always-on FastAPI service so latency stays low
(no cold start per search). It loads BGE-M3 once and L2-normalizes the output, so
the query vector lives in the exact same space as the stored episode vectors.

`embed-sidecar/handler.py`:

```python
MODEL_NAME = os.environ.get("MODEL_NAME", "BAAI/bge-m3")

@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest):
    m = get_model()
    vec = m.encode([req.text], normalize_embeddings=True)[0]
    return EmbedResponse(vector=vec.tolist())
```

- **Deployment:** k8s `Deployment` in the `buzz-bot` namespace, reached at
  `http://embed-sidecar.buzz-bot.svc.cluster.local:8000` (override with
  `EMBED_SIDECAR_URL`). It is **internal-only** — never exposed via ingress.
- **Why a sidecar (not the RunPod worker)?** The RunPod serverless worker
  (`embed-worker/`) embeds episodes in hourly batches where cold starts are fine.
  Search needs a sub-second, single-text round trip, so it uses the resident
  sidecar instead.

## 4. Ranking SQL — vector similarity over your subscriptions

`Episode.for_inbox_semantic` (`src/models/episode.cr`) joins episodes to the
caller's subscriptions and orders by cosine **similarity** to the query vector:

```crystal
def self.for_inbox_semantic(user_id : Int64, query_vec : Array(Float64),
                            limit : Int32 = 100, offset : Int32 = 0) : Array(Episode)
  vector_str = "[#{query_vec.join(",")}]"
  episodes = [] of Episode
  AppDB.pool.query_each(
    <<-SQL,
      SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url,
             e.duration_sec, e.published_at, e.image_url
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

Things worth noting:

- **`<=>` is pgvector's cosine-distance operator.** `1 - distance` turns it into a
  similarity (1.0 = identical, 0.0 = orthogonal); `DESC` puts the closest matches first.
- **`LEFT JOIN` + `NULLS LAST`** — episodes that have not been embedded yet still
  appear, but sink to the bottom instead of being dropped.
- **Scoped to `user_feeds`** — you only ever search your own subscriptions.
- **No similarity threshold.** Every subscribed episode is ranked; results are a
  re-ordering of your inbox, not a filtered subset. Pagination is plain limit/offset.

## 5. Stored vectors and the index

The episode side of the vector space — the `episode_embeddings` table, the
`vector(1024)` column, the HNSW (`vector_cosine_ops`) index, the BGE-M3 batch
worker, and how transcripts upgrade an episode's embedding — is documented in
[Recommendations → Embeddings](RECOMMENDATIONS.md). Semantic search reads from
exactly that table and index; it adds no storage of its own.

## Failure modes & gotchas

- **Sidecar down → 502.** Search does not silently fall back to substring matching.
- **Dimension agreement is load-bearing.** The sidecar, the batch worker, and the
  `vector(1024)` column must all be BGE-M3. A model mismatch yields meaningless
  rankings rather than an error — see the BGE-M3 migration notes in
  [Recommendations](RECOMMENDATIONS.md).
- **Unembedded episodes rank last,** never disappear (the `LEFT JOIN … NULLS LAST`).
- **Multilingual by design.** BGE-M3 embeds EN/RU/NL alike, so an English query can
  surface a Russian-language episode about the same subject.
