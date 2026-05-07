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

Episode text (title + description, upgraded to full transcript after dubbing) is embedded using [all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) (384 dimensions).

### Long text handling

Transcripts from hour-long podcasts are chunked into 512-token windows with 50-token overlap. Each chunk is embedded independently, then all chunk vectors are mean-pooled and L2-normalized into a single 384-dim vector.

### Embedding pipeline

| Component | Role |
|-----------|------|
| `embed-worker/` | RunPod Serverless worker — loads the model, embeds text, extracts topics, posts results back |
| `/internal/embed` | Trigger endpoint — finds un-embedded episodes, dispatches to RunPod |
| `/internal/embeddings_result` | Callback — receives vectors + topics from RunPod, stores in Postgres |
| `k8s/embed-cronjob.yaml` | Hourly CronJob that hits `/internal/embed` to process new episodes |

The callback is authenticated with a shared `INTERNAL_WEBHOOK_SECRET` (Bearer token).

### Storage

```
episode_embeddings
├── episode_id    BIGINT PRIMARY KEY
├── embedding     vector(384)          -- pgvector, HNSW index
├── topics        TEXT[]               -- KeyBERT-extracted keyphrases
├── source        VARCHAR(20)          -- "description" or "transcript"
├── created_at    TIMESTAMPTZ
└── updated_at    TIMESTAMPTZ
```

## Topic Extraction

Alongside embeddings, [KeyBERT](https://github.com/MaartenGr/KeyBERT) extracts up to 10 keyphrases per episode using the same loaded sentence-transformer model. KeyBERT uses Maximal Marginal Relevance (MMR) to ensure diverse topics rather than near-duplicates.

Topics serve two purposes:

1. **Explainable recommendations** — the player shows which keywords two episodes share in common
2. **Tag cloud browsing** — the Topics tab aggregates all topics across a user's subscriptions into a visual tag cloud; tapping a tag filters the episode list to only matching episodes

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

The inbox search box re-ranks episodes by vector similarity to a text query. A lightweight Python FastAPI sidecar (`embed-sidecar/`) loads the same all-MiniLM-L6-v2 model and embeds the query in real time (<50ms). The Crystal server queries pgvector to order inbox episodes by cosine similarity to the query vector.

- Sidecar runs as a k8s Deployment in the `buzz-bot` namespace (`embed-sidecar:8000`)
- Episodes without embeddings sort to the bottom (`NULLS LAST`)
- 300ms debounced input; clearing restores chronological order

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `EMBED_ENDPOINT_ID` | RunPod serverless endpoint ID |
| `EMBED_SIDECAR_URL` | Embed sidecar URL (default: `http://embed-sidecar.buzz-bot.svc.cluster.local:8000`) |
| `INTERNAL_WEBHOOK_SECRET` | Bearer token for callback authentication |
