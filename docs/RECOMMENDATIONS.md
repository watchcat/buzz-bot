# Recommendations

Buzz-Bot uses a hybrid recommendation system that combines semantic similarity with collaborative filtering to surface relevant episodes.

## How It Works

Each episode is scored against the currently playing episode using two signals, then ranked by a weighted combination:

| Signal | Weight | Source |
|--------|--------|--------|
| **Vector similarity** | 70% | Cosine similarity between episode embeddings (pgvector) |
| **Collaborative boost** | 30% | How many users who liked the current episode also liked the candidate |

The top 5 candidates are shown in the "Listeners also liked" section of the player.

## Embeddings

Episode text (title + description, upgraded to full transcript after dubbing) is embedded using [BGE-M3](https://huggingface.co/BAAI/bge-m3) (1024 dimensions). BGE-M3 supports up to 8192 tokens natively in a single pass, covering even hour-long transcripts without chunking.

### Embedding pipeline

| Component | Role |
|-----------|------|
| `embed-worker/` | RunPod Serverless worker — loads the model, embeds text, extracts topics, posts results back |
| `/internal/embed` | Trigger endpoint — finds un-embedded episodes, dispatches to RunPod |
| `/internal/embeddings_result` | Callback — receives vectors + topics from RunPod, stores in Postgres |
| `k8s/embed-cronjob.yaml` | Hourly `embed-trigger` CronJob → `/internal/embed` |
| `cluster-worker/` | Nightly k8s Job — clusters distinct topic strings (see Topic Clustering) |
| `k8s/cluster-cronjob.yaml` | Nightly `cluster-trigger` CronJob (03:00) → `cluster-worker` |

The callback is authenticated with a shared `INTERNAL_WEBHOOK_SECRET` (Bearer token).

### Storage

```
episode_embeddings
├── episode_id    BIGINT PRIMARY KEY
├── embedding     vector(1024)         -- pgvector, HNSW (cosine) index
├── topics        TEXT[]               -- cleaned KeyBERT keyphrases; GIN index
├── source        VARCHAR(20)          -- "title"       (current pipeline)
│                                      -- "transcript"  (post-dub upgrade)
│                                      -- "description"  (sentinel: re-queue
│                                      --                 for a full re-extract)
├── created_at    TIMESTAMPTZ
└── updated_at    TIMESTAMPTZ

topic_vectors                          -- per-distinct-topic BGE-M3 cache
├── topic         TEXT PRIMARY KEY
├── embedding     vector(1024)
└── updated_at    TIMESTAMPTZ

topic_clusters                         -- nightly global clustering result
├── topic         TEXT PRIMARY KEY     -- a raw KeyBERT topic string
├── cluster_id    INTEGER
├── label         TEXT                 -- canonical tag (most-frequent member)
└── updated_at    TIMESTAMPTZ
```

## Topic Extraction

Alongside the embedding, `embed-worker` runs [KeyBERT](https://github.com/MaartenGr/KeyBERT) over the episode text to produce up to **10 keyphrases**, stored in `episode_embeddings.topics`. The pipeline is deliberately surgical so the tag cloud stays meaningful for a multilingual (EN / RU / NL) corpus:

1. **Input cleaning** — leading chapter timestamps (`00:00 — …`, `1:23:45 …`) and inline time/date strings are stripped *before* KeyBERT, so digits never become keyphrases.
2. **Multilingual KeyBERT** — KeyBERT with a `CountVectorizer` using a vendored EN+RU+NL stop-word set and `ngram_range=(1,2)`, with Maximal Marginal Relevance (`diversity=0.3`) for variety. It over-fetches the top 15 candidates.
3. **Noise guard** — candidates that are *entirely* numeric/date fragments (`is_noise_topic`) are dropped; number-bearing real topics (`covid 19`, `9 мая`) survive.
4. **Dedupe & trim** — case-insensitive de-dupe, keep the first 10. An episode whose cleaned text yields no real keyphrase stores `topics = '{}'` (legitimately topic-less).

`is_noise_topic` lives in **three synchronised places** — `embed-worker` (the root fix), the nightly cluster job (safety net), and the tag-cloud read query (belt-and-suspenders); a shared test table guards them against drift.

### How an episode gets its topics

The hourly `embed-trigger` CronJob hits `/internal/embed`, which selects work in priority order: **un-embedded** episodes → episodes still missing topics that have *not* been through the current pipeline → rows explicitly flagged for a full re-extract (`source = 'description'`). The batch is dispatched to RunPod; the callback upserts vectors + topics and resets `source = 'title'`. Flipping a row's `source` to `'description'` is the supported way to re-queue it after an extraction change.

## Topic Clustering & Tag Cloud

Raw KeyBERT strings fragment one concept across morphology and language (`war` / `война` / `oorlog`). A **nightly global clustering job** consolidates them so the cloud shows a single canonical tag per concept.

`cluster-worker` (`cluster-trigger` CronJob, 03:00):

1. Collect every distinct topic appearing in ≥ `TOPIC_CLUSTER_MIN_COUNT` (default **3**) episodes, excluding `is_noise_topic` strings.
2. Embed any not-yet-cached topic *string* with BGE-M3 (via `embed-sidecar`) into `topic_vectors`.
3. `sklearn` `AgglomerativeClustering` — **complete** linkage, cosine `distance_threshold` = `TOPIC_CLUSTER_DISTANCE` (default **0.30**). Parameters were chosen from an offline experiment; single-linkage was rejected for chaining.
4. Label each cluster by its **most-frequent member string** (deterministic tie-break: shortest, then lexicographic — stable across runs, no LLM).
5. Atomically `TRUNCATE` + rebuild `topic_clusters` so the cloud never sees a half-built state.

Clustering is global (content-defined, not per-user) and flat.

### Read path

`GET /topics` (the Topics tab):

- **`top_tags_for_user`** unnests each subscribed episode's `topics`, `LEFT JOIN`s `topic_clusters`, and groups by `COALESCE(cluster_label, raw_topic)` with `COUNT(DISTINCT episode_id)` (so an episode tagged with two synonyms of one cluster isn't double-counted). Un-clustered topics fall back to themselves as singletons. Excluded: the user's hidden tags and a SQL date/number-regex backstop.
- **Tapping a tag** (`for_topic`) matches episodes whose `topics` overlaps *any* member of that cluster (`&&`, GIN-indexed), falling back to an exact match for un-clustered tags.
- **Hiding a tag** (`×`) stores the canonical label in `user_hidden_topics`, removing the whole cluster from the cloud.

Topics also power **explainable recommendations** (shared keywords between two episodes — see below).

## Explainability

The player has a "Show scores" toggle in the recommendations section. When enabled, each recommendation shows:

- **Matching topics** (if available): `AI, machine learning, GPT +2 more | collab: 0.45 | combined: 0.69`
- **Numeric fallback** (if no topics yet): `vector: 0.82 | collab: 0.45 | combined: 0.69`

Topic overlap is computed at query time using Postgres array intersection (`INTERSECT` on unnested arrays). Up to 3 topics are shown, with a "+N more" indicator for additional matches.

## Recommendation Query

The SQL uses three CTEs:

1. **vector_recs** — finds 20 nearest neighbors by cosine distance (`<=>` operator)
2. **collab_recs** — counts shared "likers" for collaborative signal
3. **combined** — merges both with `FULL OUTER JOIN`, applies 70/30 weighting

The final SELECT joins episode metadata, computes topic overlap, and returns the top 5.

## Transcript Upgrade

When an episode is dubbed, the full transcript becomes available. The dub result callback automatically dispatches a re-embedding request with `source: "transcript"`, upgrading the episode's vector from title+description to the richer full transcript.

## Semantic Inbox Search

The inbox search box re-ranks the user's **subscribed episodes** by vector similarity to a text query. (Scope note: the semantic query ranks *all* episodes from the user's feeds — `for_inbox_semantic` joins `user_feeds` only; it does **not** apply the unheard/listened filter the normal inbox view uses.) A lightweight Python FastAPI sidecar (`embed-sidecar/`) loads the BGE-M3 model and embeds the query in real time (low-latency, with the model kept warm). The Crystal server then queries pgvector to order those episodes by cosine similarity to the query vector.

- Sidecar runs as a k8s Deployment in the `buzz-bot` namespace (`embed-sidecar:8000`), loading BGE-M3
- Episodes without embeddings sort to the bottom (`NULLS LAST`)
- 300ms debounced input; clearing restores chronological order

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `EMBED_ENDPOINT_ID` | RunPod serverless endpoint ID |
| `EMBED_SIDECAR_URL` | Embed sidecar URL (default: `http://embed-sidecar.buzz-bot.svc.cluster.local:8000`) |
| `INTERNAL_WEBHOOK_SECRET` | Bearer token for callback authentication |
| `MODEL_NAME` | Embedding model — must stay `BAAI/bge-m3`; a stale per-endpoint override silently runs the wrong model |
| `TOPIC_CLUSTER_DISTANCE` | Agglomerative cosine-distance threshold (default `0.30`) |
| `TOPIC_CLUSTER_MIN_COUNT` | Min distinct episodes for a topic to be clustered (default `3`) |
| `CLUSTER_LINKAGE` | sklearn linkage (default `complete`) |
