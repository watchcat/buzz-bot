# Embedding-based topic clustering — design

Date: 2026-05-16
Status: approved (pre-implementation)
Repo: buzz-bot

## Problem

KeyBERT extracts free-text keyword strings per episode into
`episode_embeddings.topics text[]`. With the BGE-M3 migration these strings are
now **multilingual** (English / Russian / Dutch). The tag cloud
(`top_tags_for_user`) groups by the raw string, so the same concept fragments
into many tags: `machine learning` / `ML` / `машинное обучение` /
`machinaal leren` are four separate, low-count entries instead of one
consolidated topic. Counts are diluted and the cloud is noisy.

BGE-M3 embeds these strings into a shared cross-lingual space, so cosine
similarity between topic-string vectors can merge synonyms and translations.

## Goals

- Consolidate semantically-equivalent topic strings (incl. cross-language) into
  one canonical tag in the cloud, with summed counts.
- No Gemini / LLM dependency in the hot path. Deterministic, stable labels.
- No frontend or API contract changes — the tag cloud keeps sending/receiving
  label strings.
- Minimal schema, minimal new infra, reuse existing patterns (embed CronJob,
  embed-sidecar, `user_hidden_topics`).

## Non-goals

- Per-user clustering. Clustering is content-meaning, user-independent → done
  **globally**, once per night.
- Hierarchical / multi-level topics. Flat clusters only.
- Re-labelling via LLM. Label = most-frequent member string.

## Locked decisions (from brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Cluster label | Most-frequent member string | Deterministic, stable, no LLM, zero hot-path cost. Label is whatever language dominates globally for that concept. |
| Cadence | Nightly global rebuild + raw-string fallback | Topics not yet clustered render as singleton raw strings until the next nightly run. |
| Hide model | Hide by cluster label, reuse `user_hidden_topics` | No schema change, no migration. Aggregation excludes clusters whose current label is hidden; old raw-string hides keep working for singletons. |
| Threshold tuning | Offline experiment first | The cosine-distance threshold can't be eyeballed from theory; pick it from real data before building the prod job. |
| Prod mechanism | Experiment decides | Single-linkage (in-DB graph) vs average/complete (sklearn) chosen by experiment quality, not guessed. |

## Grounded facts (verified against the codebase 2026-05-16)

- Embed cron: `k8s/embed-cronjob.yaml` → `POST /internal/embed`. The nightly
  cluster job mirrors this pattern.
- `embed-sidecar` (FastAPI, BGE-M3, deployed at image `2.0`):
  `POST /embed {text} → {vector}`, single text. Directly reusable for topic
  strings; add a batch endpoint only if per-topic latency is a problem.
- **No GIN index on `episode_embeddings.topics`** exists (migration 015 adds the
  column only). Current `for_topic` `$2 = ANY(ee.topics)` is a seq scan.
- `top_tags_for_user` SQL (`src/models/episode_embedding.cr`):
  `episodes e JOIN user_feeds uf ON uf.feed_id=e.feed_id JOIN
  episode_embeddings ee ON ee.episode_id=e.id, unnest(ee.topics) t
  WHERE uf.user_id=$1 AND t NOT IN (hidden) GROUP BY t ORDER BY count DESC`.
  Uses `COUNT(*)` over (episode, topic) pairs.
- `for_topic` (`src/models/episode.cr`): `WHERE uf.user_id=$1 AND
  $2 = ANY(ee.topics)`.
- `hide_topic`: inserts the passed string verbatim into
  `user_hidden_topics(user_id, topic)`.

## Phase 1 — Offline experiment (gates Phase 3 mechanism)

`scripts/topic_cluster_experiment.py` — kept in-repo, re-runnable when the
corpus or model changes.

- Connects to Neon (reuse `k8s/embed-progress.sh` DATABASE_URL extraction:
  `kubectl get secret … | base64 -d | sed 's#\?.*#?sslmode=require#'`).
- Pulls distinct topics with global episode counts.
- Embeds with `SentenceTransformer("BAAI/bge-m3")` (one-time ~2.2 GB local
  download via nix-shell; fallback: one-off k8s Job on the node where the
  `embed-sidecar:2.0` image already has the model cached).
- Grid: **linkage ∈ {single, average, complete} × cosine-distance
  T ∈ {0.20, 0.25, 0.30, 0.35, 0.40} × prefilter K ∈ {2, 3, 5}**.
- Per cell → `scripts/experiment-output/<linkage>_T<…>_K<…>.txt` (gitignored):
  clusters sorted by size, member strings, chosen label; summary stats
  (#clusters, largest cluster size, #singletons, % topics in multi-member
  clusters, **total distinct topics** — reveals whether sklearn's O(n²) matrix
  is feasible).

**Gate:** review output → choose `(linkage, T, K)`.

**Prod-mechanism decision rule:**
- single-linkage acceptable at chosen T → lean **in-DB Crystal** job
  (HNSW k-NN graph + union-find connected components).
- average/complete needed → **Python sklearn CronJob** (reuses
  `embed-sidecar:2.0` image).

## Phase 2 — Schema: `migrations/018_topic_clusters.sql`

```sql
CREATE TABLE topic_vectors (
  topic      text PRIMARY KEY,
  embedding  vector(1024) NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE topic_clusters (
  topic      text PRIMARY KEY,
  cluster_id integer NOT NULL,
  label      text    NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX topic_clusters_label_idx ON topic_clusters (label);
CREATE INDEX episode_embeddings_topics_gin ON episode_embeddings USING gin (topics);
```

HNSW index on `topic_vectors` is **deferred** to a follow-up migration, added
only if the in-DB single-linkage path wins (sklearn path loads all vectors and
doesn't need it).

## Phase 3 — Nightly job

- New endpoint `POST /internal/cluster-topics` (in-DB path) **or** standalone
  Python job (sklearn path).
- `k8s/cluster-cronjob.yaml`, schedule `0 3 * * *` (after the embed cron has
  populated the day's topics).
- Config knob `TOPIC_CLUSTER_MIN_COUNT` (default `3`) = global prefilter K.

Steps:

1. `SELECT t, COUNT(DISTINCT episode_id) c FROM episode_embeddings,
   unnest(topics) t GROUP BY t HAVING COUNT(DISTINCT episode_id) >= K`
2. Topics absent from `topic_vectors` → embed via sidecar → upsert
   (incremental; most cached after first run).
3. Load all qualifying vectors → cluster (mechanism per Phase 1).
4. Label = member with max global episode count; tie-break **shortest string,
   then lexicographic** (deterministic → labels don't flicker across runs).
5. `BEGIN; TRUNCATE topic_clusters; INSERT …; COMMIT;` — atomic full rebuild so
   the tag cloud never observes a half-built state.

## Phase 4 — Read path (3 SQL changes, no API/frontend changes)

### `top_tags_for_user`

```sql
SELECT COALESCE(tc.label, t) AS tag, COUNT(DISTINCT e.id)::int AS count
FROM episodes e
JOIN user_feeds uf ON uf.feed_id = e.feed_id
JOIN episode_embeddings ee ON ee.episode_id = e.id,
     unnest(ee.topics) AS t
LEFT JOIN topic_clusters tc ON tc.topic = t
WHERE uf.user_id = $1
  AND COALESCE(tc.label, t) NOT IN (SELECT topic FROM user_hidden_topics WHERE user_id = $1)
GROUP BY COALESCE(tc.label, t)
ORDER BY count DESC
LIMIT $2 OFFSET $3
```

`COUNT(DISTINCT e.id)` replaces `COUNT(*)`: an episode tagged with two synonyms
of one cluster must not double-count. Slightly changes existing singleton counts
in the rare case an episode lists duplicate strings — accepted, more correct.

### `for_topic`

```sql
WITH members AS (SELECT array_agg(topic) a FROM topic_clusters WHERE label = $2)
... WHERE uf.user_id = $1
    AND ee.topics && COALESCE((SELECT a FROM members), ARRAY[$2])
```

Clicked label → member set → array-overlap (`&&`, GIN-indexed). If the label is
an un-clustered raw string (no rows in `topic_clusters`), `members.a` is NULL →
falls back to `ARRAY[$2]`, i.e. exact-match on the single string (current
behavior preserved).

### `hide_topic`

Code unchanged. The clicked label is stored verbatim in `user_hidden_topics`;
the aggregation's `COALESCE(tc.label, t) NOT IN (hidden)` makes that hide the
whole cluster. Old raw-string hides keep working for singletons.

## Risks / accepted trade-offs

- **Multilingual label** is the globally dominant language for the concept —
  may be Russian for an English-leaning user. Accepted (most-frequent-member,
  no Gemini).
- **Stale hide:** a topic hidden as a raw string *before* it later joins a
  cluster whose label differs → that old hide stops working. Accepted per
  "reuse table, no migration". Documented for support.
- **Global ≠ per-user.** Original "≥N in user's subscriptions" splits into:
  global prefilter **K** (clustering scale) vs per-user display (existing
  `LIMIT` / order-by-count). No per-user `HAVING` added — display behavior
  unchanged.
- **Distinct-topic count unknown** until Phase 1 — it determines sklearn O(n²)
  feasibility, which is exactly why the experiment runs first.
- **Sidecar throughput:** per-topic `POST /embed`. First nightly run embeds the
  full backlog; subsequent runs are incremental (only new topics). Add a batch
  endpoint only if the first run is unacceptably slow.

## Success criteria

- Tag cloud shows consolidated cross-lingual topics with summed counts; no
  duplicate-concept tags above the prefilter.
- Clicking a clustered tag returns episodes matching **any** member string.
- Hiding a clustered tag removes the whole cluster from the cloud.
- Nightly job idempotent, atomic, incremental on `topic_vectors`.
- Zero frontend/API changes; existing singleton + raw-string-hide behavior
  intact for un-clustered topics.

## Implementation order

1. Phase 1 experiment script + run + choose `(linkage, T, K)` and prod
   mechanism. **(gate)**
2. Migration 018 (tables + GIN index).
3. Phase 3 nightly job (mechanism per #1) + CronJob manifest.
4. Phase 4 read-path SQL changes.
5. Backfill: first manual job run; verify cloud; deploy CronJob.
