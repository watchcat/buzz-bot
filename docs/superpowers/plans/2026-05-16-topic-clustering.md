# Topic Clustering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate semantically-equivalent (incl. cross-lingual) KeyBERT topic strings into one canonical tag in the buzz-bot tag cloud, via nightly BGE-M3 embedding clustering, with no frontend/API changes.

**Architecture:** Experiment-first and **gated**. Phase 1 is an offline Python experiment that picks `(linkage, T, K)` and the production mechanism. A hard human gate (Task 4) records that decision. Only then does production code get written: a mechanism-independent schema migration + read-path SQL, plus exactly one of two fully-specified nightly-job branches (3A in-DB Crystal single-linkage, or 3B Python sklearn CronJob average/complete).

**Tech Stack:** Crystal/Kemal, PostgreSQL + pgvector (Neon), BGE-M3 via `embed-sidecar` (FastAPI), Python (sentence-transformers, scikit-learn, psycopg2), k8s CronJob, nix-shell.

**Spec:** `docs/superpowers/specs/2026-05-16-topic-clustering-design.md`

---

## How the gate works (read before starting)

- Tasks 1–3 build and run the offline experiment. **No production code is written in Phase 1.**
- **Task 4 is a STOP.** A human reviews `scripts/experiment-output/` and fills
  `docs/superpowers/specs/2026-05-16-topic-clustering-DECISION.md` with the chosen
  `linkage`, `T`, `K`, and `mechanism ∈ {in-db-crystal, python-sklearn}`.
- Tasks 5–6 (migration, read-path) are mechanism-independent — safe after the gate.
- **Execute exactly one of Task 7A or Task 7B**, whichever the DECISION file names. The
  other branch is left unexecuted. Both are fully specified; this is not a placeholder.
- Task 8 (deploy/backfill) is shared.

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `scripts/requirements-experiment.txt` | Pinned Python deps for the experiment | 1 |
| `scripts/topic_cluster_experiment.py` | DB pull, embed, clustering grid, output dump | 1 |
| `scripts/test_topic_cluster_experiment.py` | pytest for pure logic (label pick, grouping) | 1 |
| `scripts/topic-cluster-experiment.sh` | Runner: extract DATABASE_URL, venv, run script | 1 |
| `docs/superpowers/specs/2026-05-16-topic-clustering-DECISION.md` | Gate decision record | 1 |
| `migrations/018_topic_clusters.sql` | `topic_vectors`, `topic_clusters`, GIN index | 2 |
| ~~`src/models/topic_cluster.cr`~~ | 3A only — **NOT EXECUTED** (gate=sklearn) | ~~3A~~ |
| `src/models/episode_embedding.cr` | Modify `top_tags_for_user` (cluster-aware) | 4 |
| `src/models/episode.cr` | Modify `for_topic` (member overlap + fallback) | 4 |
| ~~`src/topic_clustering/union_find.cr`~~ | 3A only — **NOT EXECUTED** | ~~3A~~ |
| ~~`spec/...union_find_spec.cr`~~ | 3A only — **NOT EXECUTED** | ~~3A~~ |
| ~~`src/web/routes/topic_clusters.cr`~~ | 3A only — **NOT EXECUTED** | ~~3A~~ |
| ~~`src/web/server.cr`~~ | 3A only — **NOT EXECUTED** | ~~3A~~ |
| ~~`migrations/019_topic_vectors_hnsw.sql`~~ | 3A only — **NOT CREATED** | ~~3A~~ |
| `cluster-worker/cluster_job.py` | sklearn nightly job + `is_noise_topic` | 3B ✅ |
| `cluster-worker/test_cluster_job.py` | pytest for `is_noise_topic` (gate amendment) | 3B ✅ |
| `cluster-worker/Dockerfile`, `requirements.txt` | 3B prod image (no pytest) | 3B ✅ |
| `k8s/cluster-cronjob.yaml` | Nightly trigger (sklearn body) | 3B/8 ✅ |

---

## Phase 1 — Offline experiment (gated)

### Task 1: Experiment deps + pure logic (TDD)

**Files:**
- Create: `scripts/requirements-experiment.txt`
- Create: `scripts/topic_cluster_experiment.py`
- Test: `scripts/test_topic_cluster_experiment.py`

- [ ] **Step 1: Pin deps**

Create `scripts/requirements-experiment.txt`:

```
sentence-transformers==3.0.1
scikit-learn==1.5.1
psycopg2-binary==2.9.9
numpy==1.26.4
pytest==8.2.2
```

- [ ] **Step 2: Write the failing test**

Create `scripts/test_topic_cluster_experiment.py`:

```python
from topic_cluster_experiment import pick_label, groups_from_labels


def test_pick_label_prefers_highest_count():
    members = ["ml", "machine learning", "машинное обучение"]
    counts = {"ml": 5, "machine learning": 12, "машинное обучение": 7}
    assert pick_label(members, counts) == "machine learning"


def test_pick_label_tiebreak_shortest_then_lexicographic():
    members = ["bbb", "aa", "cc"]
    counts = {"bbb": 4, "aa": 4, "cc": 4}
    # all tie on count -> shortest (len 2) -> lexicographic among {"aa","cc"} -> "aa"
    assert pick_label(members, counts) == "aa"


def test_groups_from_labels_buckets_by_cluster_id():
    topics = ["a", "b", "c", "d"]
    labels = [0, 1, 0, 1]
    assert groups_from_labels(topics, labels) == {0: ["a", "c"], 1: ["b", "d"]}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd scripts && python -m pytest test_topic_cluster_experiment.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'topic_cluster_experiment'`

- [ ] **Step 4: Write minimal implementation**

Create `scripts/topic_cluster_experiment.py` (logic only for now):

```python
"""Offline experiment: cluster BGE-M3 topic-string embeddings across a grid.

Run via scripts/topic-cluster-experiment.sh (sets DATABASE_URL, venv).
Phase 1 of docs/superpowers/specs/2026-05-16-topic-clustering-design.md.
NO production code: read-only against the DB, writes only to experiment-output/.
"""
from __future__ import annotations


def pick_label(members: list[str], counts: dict[str, int]) -> str:
    """Canonical label = member with max global episode count.
    Deterministic tie-break: highest count, then shortest string, then
    lexicographic. Keeps labels stable across nightly runs.
    """
    return min(members, key=lambda m: (-counts.get(m, 0), len(m), m))


def groups_from_labels(topics: list[str], labels: list[int]) -> dict[int, list[str]]:
    """Bucket topic strings by their assigned cluster id (sklearn .labels_)."""
    out: dict[int, list[str]] = {}
    for topic, cid in zip(topics, labels):
        out.setdefault(int(cid), []).append(topic)
    return out
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd scripts && python -m pytest test_topic_cluster_experiment.py -v`
Expected: PASS (3 passed)

- [ ] **Step 6: Commit**

```bash
git add scripts/requirements-experiment.txt scripts/topic_cluster_experiment.py scripts/test_topic_cluster_experiment.py
git commit -m "feat: topic-cluster experiment pure logic (label pick, grouping)"
```

---

### Task 2: Experiment DB pull + clustering grid

**Files:**
- Modify: `scripts/topic_cluster_experiment.py` (append `main()` and helpers)

- [ ] **Step 0: Tighten `pick_label` docstring (Task 1 review follow-up)**

`pick_label` now gains more callers. Replace its docstring body to state the
preconditions the Task 1 reviewer flagged. The function code is unchanged; only
the docstring:

```python
def pick_label(members: list[str], counts: dict[str, int]) -> str:
    """Canonical label = member with max global episode count.

    Deterministic tie-break: highest count, then shortest string, then
    lexicographic (case-sensitive: Python codepoint order, so uppercase
    sorts before lowercase — 'AI' < 'ai'). Keeps labels stable across
    nightly runs.

    Precondition: `members` must be non-empty (min() raises ValueError on []).
    Callers cluster real members, so this always holds in practice.
    """
    return min(members, key=lambda m: (-counts.get(m, 0), len(m), m))
```

(Re-run `python -m pytest test_topic_cluster_experiment.py -v` after — still 3 passed; behavior unchanged, docstring only.)

- [ ] **Step 1: Append DB + grid code**

Append to `scripts/topic_cluster_experiment.py`:

```python
import os
import sys
import itertools
import pathlib

import numpy as np
import psycopg2
from sentence_transformers import SentenceTransformer
from sklearn.cluster import AgglomerativeClustering

OUT_DIR = pathlib.Path(__file__).parent / "experiment-output"
LINKAGES = ["single", "average", "complete"]
THRESHOLDS = [0.20, 0.25, 0.30, 0.35, 0.40]  # cosine distance
PREFILTERS = [2, 3, 5]                        # min distinct episodes (K)


def fetch_topics(dsn: str) -> dict[str, int]:
    """topic string -> global distinct-episode count, across ALL episodes."""
    sql = (
        "SELECT t, COUNT(DISTINCT episode_id)::int "
        "FROM episode_embeddings, unnest(topics) AS t "
        "GROUP BY t"
    )
    with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
        cur.execute(sql)
        return {row[0]: row[1] for row in cur.fetchall()}


def cluster(vectors: np.ndarray, linkage: str, threshold: float) -> list[int]:
    model = AgglomerativeClustering(
        n_clusters=None,
        metric="cosine",
        linkage=linkage,
        distance_threshold=threshold,
    )
    return model.fit_predict(vectors).tolist()


def write_report(path: pathlib.Path, topics: list[str], counts: dict[str, int],
                 labels: list[int]) -> None:
    groups = groups_from_labels(topics, labels)
    multi = {c: m for c, m in groups.items() if len(m) > 1}
    singletons = len(groups) - len(multi)
    total = len(topics)
    in_multi = sum(len(m) for m in multi.values())
    lines = [
        f"distinct_topics={total}  clusters={len(groups)}  "
        f"multi_member={len(multi)}  singletons={singletons}  "
        f"pct_in_multi={100*in_multi/total:.1f}%",
        f"largest_cluster={max((len(m) for m in groups.values()), default=0)}",
        "",
    ]
    for cid, members in sorted(multi.items(), key=lambda kv: -len(kv[1])):
        label = pick_label(members, counts)
        lines.append(f"[{len(members)}] LABEL={label!r}")
        for m in sorted(members, key=lambda x: -counts.get(x, 0)):
            lines.append(f"    {counts.get(m,0):>5}  {m}")
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    dsn = os.environ["DATABASE_URL"]
    OUT_DIR.mkdir(exist_ok=True)
    counts = fetch_topics(dsn)
    print(f"fetched {len(counts)} distinct topics", file=sys.stderr)

    model = SentenceTransformer("BAAI/bge-m3")
    for k in PREFILTERS:
        topics = sorted([t for t, c in counts.items() if c >= k])
        if len(topics) < 3:
            print(f"K={k}: only {len(topics)} topics, skipping", file=sys.stderr)
            continue
        vecs = np.asarray(model.encode(topics, normalize_embeddings=True))
        for linkage, thr in itertools.product(LINKAGES, THRESHOLDS):
            labels = cluster(vecs, linkage, thr)
            fn = OUT_DIR / f"{linkage}_T{thr:.2f}_K{k}.txt"
            write_report(fn, topics, counts, labels)
            print(f"wrote {fn.name}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Re-run unit tests (no regression in pure logic)**

Run: `cd scripts && python -m pytest test_topic_cluster_experiment.py -v`
Expected: PASS (3 passed) — imports still resolve, pure functions unchanged.

- [ ] **Step 3: Commit**

```bash
git add scripts/topic_cluster_experiment.py
git commit -m "feat: topic-cluster experiment DB pull + clustering grid"
```

---

### Task 3: Experiment runner + run it

**Files:**
- Create: `scripts/topic-cluster-experiment.sh`
- Modify: `.gitignore` (ignore experiment output + venv)

- [ ] **Step 1: Write the runner**

Create `scripts/topic-cluster-experiment.sh`:

```bash
#!/usr/bin/env bash
# Phase 1 offline experiment runner. Read-only against Neon.
set -euo pipefail
cd "$(dirname "$0")"

DBURL=$(kubectl --kubeconfig ../k8s/kubeconfig -n buzz-bot get secret buzz-bot-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
[ -n "$DBURL" ] || { echo "ERROR: DATABASE_URL extracted as empty (secret missing key?)" >&2; exit 1; }
export DATABASE_URL="$DBURL"

nix-shell --packages python311 gcc --run '
  set -e
  [ -d .venv-exp ] || python3 -m venv .venv-exp
  ./.venv-exp/bin/pip install -q -r requirements-experiment.txt
  ./.venv-exp/bin/python -m pytest test_topic_cluster_experiment.py -q
  ./.venv-exp/bin/python topic_cluster_experiment.py
'
echo "Done. Review scripts/experiment-output/*.txt"
```

- [ ] **Step 2: Make executable + gitignore artifacts**

Run:
```bash
chmod +x scripts/topic-cluster-experiment.sh
printf '\nscripts/experiment-output/\nscripts/.venv-exp/\nscripts/__pycache__/\n' >> .gitignore
```

(`scripts/__pycache__/` included per Task 1 code review — pytest creates it.)

- [ ] **Step 3: Commit the runner**

```bash
git add scripts/topic-cluster-experiment.sh .gitignore
git commit -m "feat: topic-cluster experiment runner script"
```

- [ ] **Step 4: Run the experiment**

Run: `./scripts/topic-cluster-experiment.sh`
Expected: pytest passes; stderr prints `fetched N distinct topics`; `scripts/experiment-output/` fills with `*_T*_K*.txt` files. First run downloads BGE-M3 (~2.2 GB) into the venv's HF cache.

If `scripts/experiment-output/` is empty or the model download fails locally, fall back to a one-off k8s Job on the node where `embed-sidecar:2.0` has the model cached — but attempt the local run first.

- [ ] **Step 5: Eyeball + summarize**

Read the report files. For each `(linkage, T, K)` note: are multi-member clusters genuinely synonyms/translations (good) or unrelated chained junk (bad, esp. `single`)? Note `distinct_topics` (sklearn O(n²) feasibility) and `pct_in_multi`. Produce a short written comparison for the human reviewer.

---

### Task 4: 🚦 GATE — record the decision (STOP)

**Files:**
- Create: `docs/superpowers/specs/2026-05-16-topic-clustering-DECISION.md`

- [ ] **Step 1: Human reviews experiment output and fills the decision record**

Create `docs/superpowers/specs/2026-05-16-topic-clustering-DECISION.md`:

```markdown
# Topic clustering — gate decision

Reviewed: <date>
Reviewer: <name>

distinct_topics (from experiment): <N>

## Chosen parameters
- linkage: <single | average | complete>
- T (cosine distance threshold): <value>
- K (global min distinct-episode prefilter): <value>

## Chosen production mechanism
mechanism: <in-db-crystal | python-sklearn>

Rule applied:
- single-linkage acceptable at chosen T  -> in-db-crystal (Task 7A)
- average/complete needed for quality     -> python-sklearn (Task 7B)

## Rationale
<2-4 sentences: why this linkage/T/K, why this mechanism, any concerns>
```

- [ ] **Step 2: Commit the decision**

```bash
git add docs/superpowers/specs/2026-05-16-topic-clustering-DECISION.md
git commit -m "docs: record topic-clustering gate decision"
```

- [ ] **Step 3: HARD STOP — do not proceed to production tasks until this file exists, is committed, and names a `mechanism`.** Subsequent tasks read `T`, `K`, `linkage`, `mechanism` from it. Substitute those values wherever this plan writes `<T>`, `<K>`, `<linkage>`.

---

## Phase 2 — Schema (mechanism-independent)

### Task 5: Migration 018 — cluster tables + GIN index

**Files:**
- Create: `migrations/018_topic_clusters.sql`

- [ ] **Step 1: Write the migration**

Create `migrations/018_topic_clusters.sql`:

```sql
-- migrations/018_topic_clusters.sql
-- Topic-string vector cache + nightly global clustering result.
-- HNSW index on topic_vectors is deferred to 019 (only if in-db-crystal wins).

CREATE TABLE IF NOT EXISTS topic_vectors (
  topic      text PRIMARY KEY,
  embedding  vector(1024) NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS topic_clusters (
  topic      text PRIMARY KEY,
  cluster_id integer NOT NULL,
  label      text    NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS topic_clusters_label_idx
  ON topic_clusters (label);

CREATE INDEX IF NOT EXISTS episode_embeddings_topics_gin
  ON episode_embeddings USING gin (topics);
```

- [ ] **Step 2: Apply the migration**

Run:
```bash
DBURL=$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
nix-shell --packages postgresql --run "psql \"$DBURL\" -v ON_ERROR_STOP=1 -f migrations/018_topic_clusters.sql"
```
Expected: `CREATE TABLE` ×2, `CREATE INDEX` ×2, no errors.

- [ ] **Step 3: Verify schema**

Run:
```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -c '\\d topic_clusters' -c '\\d topic_vectors' -c \"SELECT indexname FROM pg_indexes WHERE tablename='episode_embeddings' AND indexname='episode_embeddings_topics_gin';\""
```
Expected: both tables shown with correct columns; `episode_embeddings_topics_gin` row present.

- [ ] **Step 4: Commit**

```bash
git add migrations/018_topic_clusters.sql
git commit -m "feat: migration 018 - topic_vectors, topic_clusters, topics GIN index"
```

---

## Phase 3 — Nightly job (execute ONLY the branch named in the DECISION file)

> **GATE OUTCOME (2026-05-16):** `mechanism: python-sklearn` →
> **execute Task 7B; SKIP Task 7A entirely.** Migration 019 (HNSW on
> `topic_vectors`) is 7A-only and is **NOT created/applied**. Task 7A below is
> retained for the record only — do not implement it.

### Task 7A: In-DB Crystal nightly clustering (single-linkage) — ❌ NOT EXECUTED (gate chose python-sklearn)

**Files:**
- Create: `src/topic_clustering/union_find.cr`
- Create: `spec/spec_helper.cr`, `spec/topic_clustering/union_find_spec.cr`
- Create: `migrations/019_topic_vectors_hnsw.sql`
- Create: `src/models/topic_cluster.cr`
- Create: `src/web/routes/topic_clusters.cr`
- Modify: `src/web/server.cr` (register route)
- Create: `k8s/cluster-cronjob.yaml`

- [ ] **Step 1: Write the failing union-find spec**

Create `spec/spec_helper.cr`:

```crystal
require "spec"
require "../src/topic_clustering/union_find"
```

Create `spec/topic_clustering/union_find_spec.cr`:

```crystal
require "../spec_helper"

describe TopicClustering::UnionFind do
  it "isolated nodes are their own components" do
    uf = TopicClustering::UnionFind.new(3)
    uf.components.values.map(&.sort).sort_by(&.first).should eq([[0], [1], [2]])
  end

  it "transitively merges single-linkage chains" do
    uf = TopicClustering::UnionFind.new(4)
    uf.union(0, 1)
    uf.union(1, 2)            # 0-1-2 chain -> one component
    comps = uf.components.values.map(&.sort).sort_by(&.size)
    comps.should eq([[3], [0, 1, 2]])
  end
end
```

- [ ] **Step 2: Run spec to verify it fails**

Run: `crystal spec spec/topic_clustering/union_find_spec.cr`
Expected: FAIL — `can't find file './src/topic_clustering/union_find'`

- [ ] **Step 3: Implement union-find**

Create `src/topic_clustering/union_find.cr`:

```crystal
module TopicClustering
  # Disjoint-set over 0..n-1. Connected components of a thresholded
  # cosine-distance graph == single-linkage agglomerative clusters.
  class UnionFind
    def initialize(n : Int32)
      @parent = Array(Int32).new(n) { |i| i }
      @rank = Array(Int32).new(n, 0)
    end

    def find(x : Int32) : Int32
      root = x
      root = @parent[root] while @parent[root] != root
      while @parent[x] != root # path compression
        @parent[x], x = root, @parent[x]
      end
      root
    end

    def union(a : Int32, b : Int32) : Nil
      ra, rb = find(a), find(b)
      return if ra == rb
      if @rank[ra] < @rank[rb]
        ra, rb = rb, ra
      end
      @parent[rb] = ra
      @rank[ra] += 1 if @rank[ra] == @rank[rb]
    end

    # component root => member indices
    def components : Hash(Int32, Array(Int32))
      out = Hash(Int32, Array(Int32)).new
      (0...@parent.size).each { |i| (out[find(i)] ||= [] of Int32) << i }
      out
    end
  end
end
```

- [ ] **Step 4: Run spec to verify it passes**

Run: `crystal spec spec/topic_clustering/union_find_spec.cr`
Expected: PASS (2 examples, 0 failures)

- [ ] **Step 5: Commit pure logic**

```bash
git add src/topic_clustering/union_find.cr spec/spec_helper.cr spec/topic_clustering/union_find_spec.cr
git commit -m "feat: union-find for in-db topic clustering"
```

- [ ] **Step 6: HNSW index migration**

Create `migrations/019_topic_vectors_hnsw.sql`:

```sql
-- migrations/019_topic_vectors_hnsw.sql
-- Only applied when mechanism = in-db-crystal (k-NN neighbor probe).
CREATE INDEX IF NOT EXISTS topic_vectors_hnsw_idx
  ON topic_vectors USING hnsw (embedding vector_cosine_ops);
```

Apply:
```bash
DBURL=$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
nix-shell --packages postgresql --run "psql \"$DBURL\" -v ON_ERROR_STOP=1 -f migrations/019_topic_vectors_hnsw.sql"
```
Expected: `CREATE INDEX`, no error.

- [ ] **Step 7: Topic-cluster read+rebuild model**

Create `src/models/topic_cluster.cr`:

```crystal
require "../db"

module TopicCluster
  # Atomically replace the whole clustering. groups: cluster_id => member topics.
  # labels: cluster_id => canonical label.
  def self.rebuild(groups : Hash(Int32, Array(String)),
                   labels : Hash(Int32, String)) : Nil
    AppDB.pool.transaction do |tx|
      c = tx.connection
      c.exec("TRUNCATE topic_clusters")
      groups.each do |cid, members|
        lbl = labels[cid]
        members.each do |t|
          c.exec(
            "INSERT INTO topic_clusters (topic, cluster_id, label, updated_at) " \
            "VALUES ($1, $2, $3, now())", t, cid, lbl
          )
        end
      end
    end
  end

  # topic => global distinct-episode count, prefiltered at K.
  def self.qualifying_topics(min_count : Int32) : Hash(String, Int32)
    out = Hash(String, Int32).new
    AppDB.pool.query_each(
      "SELECT t, COUNT(DISTINCT episode_id)::int " \
      "FROM episode_embeddings, unnest(topics) AS t " \
      "GROUP BY t HAVING COUNT(DISTINCT episode_id) >= $1", min_count
    ) { |rs| out[rs.read(String)] = rs.read(Int32) }
    out
  end

  # Topics needing a fresh BGE-M3 vector (not yet in topic_vectors).
  def self.uncached_topics(all : Array(String)) : Array(String)
    return [] of String if all.empty?
    cached = Set(String).new
    AppDB.pool.query_each("SELECT topic FROM topic_vectors") do |rs|
      cached << rs.read(String)
    end
    all.reject { |t| cached.includes?(t) }
  end

  def self.upsert_vector(topic : String, vec : Array(Float64)) : Nil
    AppDB.pool.exec(
      "INSERT INTO topic_vectors (topic, embedding, updated_at) " \
      "VALUES ($1, $2::vector, now()) " \
      "ON CONFLICT (topic) DO UPDATE SET embedding = EXCLUDED.embedding, " \
      "updated_at = now()",
      topic, "[#{vec.join(",")}]"
    )
  end

  # k-NN neighbors within cosine distance < threshold, via HNSW.
  record Edge, a : String, b : String
  def self.edges_within(threshold : Float64, k : Int32 = 20) : Array(Edge)
    topics = [] of String
    AppDB.pool.query_each("SELECT topic FROM topic_vectors ORDER BY topic") do |rs|
      topics << rs.read(String)
    end
    edges = [] of Edge
    topics.each do |t|
      AppDB.pool.query_each(
        "SELECT n.topic, (tv.embedding <=> n.embedding) AS dist " \
        "FROM topic_vectors tv, topic_vectors n " \
        "WHERE tv.topic = $1 AND n.topic <> $1 " \
        "ORDER BY tv.embedding <=> n.embedding LIMIT $2",
        t, k
      ) do |rs|
        nb = rs.read(String)
        dist = rs.read(Float64)
        edges << Edge.new(t, nb) if dist < threshold
      end
    end
    edges
  end
end
```

- [ ] **Step 8: The clustering endpoint**

Create `src/web/routes/topic_clusters.cr` (replace `<T>`, `<K>` with the DECISION values; default env knob keeps `<K>`):

```crystal
require "json"
require "http/client"
require "../../models/topic_cluster"
require "../../topic_clustering/union_find"
require "../../config"

module Web::Routes::TopicClusters
  Log = ::Log.for("topic_clusters")

  def self.register
    # Triggered nightly by k8s CronJob. Global rebuild.
    post "/internal/cluster-topics" do |env|
      min_count = (ENV["TOPIC_CLUSTER_MIN_COUNT"]? || "<K>").to_i
      threshold = (ENV["TOPIC_CLUSTER_DISTANCE"]? || "<T>").to_f
      sidecar = Config.embed_sidecar_url # e.g. http://embed-sidecar:8000

      counts = TopicCluster.qualifying_topics(min_count)
      all_topics = counts.keys

      # 1. Embed uncached topic strings via the BGE-M3 sidecar.
      TopicCluster.uncached_topics(all_topics).each do |t|
        resp = HTTP::Client.post(
          "#{sidecar}/embed",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: {text: t}.to_json
        )
        unless resp.status_code == 200
          Log.warn { "sidecar #{resp.status_code} for topic #{t.inspect}" }
          next
        end
        vec = Array(Float64).from_json(JSON.parse(resp.body)["vector"].to_json)
        TopicCluster.upsert_vector(t, vec)
      end

      # 2. Build the thresholded k-NN graph over cached vectors.
      idx = {} of String => Int32
      all_topics.each_with_index { |t, i| idx[t] = i }
      uf = TopicClustering::UnionFind.new(all_topics.size)
      TopicCluster.edges_within(threshold).each do |e|
        ia, ib = idx[e.a]?, idx[e.b]?
        uf.union(ia, ib) if ia && ib
      end

      # 3. Components -> groups; label = max-count member (deterministic).
      groups = {} of Int32 => Array(String)
      labels = {} of Int32 => String
      uf.components.each do |root, members|
        topics = members.map { |i| all_topics[i] }
        groups[root] = topics
        labels[root] = topics.min_by { |m| {-counts[m], m.size, m} }
      end

      TopicCluster.rebuild(groups, labels)
      Log.info { "clustered #{all_topics.size} topics into #{groups.size}" }
      env.response.content_type = "application/json"
      {ok: true, topics: all_topics.size, clusters: groups.size}.to_json
    end
  end
end
```

- [ ] **Step 9: Register the route + verify config accessor**

Confirm `Config.embed_sidecar_url` exists:
Run: `grep -n "embed_sidecar_url\|EMBED_SIDECAR" src/config.cr`
If absent, add to `src/config.cr` (match the file's existing accessor style):

```crystal
def self.embed_sidecar_url : String
  ENV["EMBED_SIDECAR_URL"]? || "http://embed-sidecar:8000"
end
```

In `src/web/server.cr`, after line `Web::Routes::Topics.register` add:

```crystal
    Web::Routes::TopicClusters.register
```

Add near the other route requires in `server.cr` (match existing `require` block):

```crystal
require "./routes/topic_clusters"
```

- [ ] **Step 10: Compile check**

Run: `crystal build src/buzz_bot.cr -o /tmp/buzz_bot_check`
Expected: builds with no errors.

- [ ] **Step 11: CronJob manifest**

Create `k8s/cluster-cronjob.yaml`:

```yaml
# k8s/cluster-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cluster-trigger
  namespace: buzz-bot
spec:
  schedule: "0 3 * * *"   # nightly 03:00, after the hourly embed cron
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: trigger
            image: alpine:3.20
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              apk add --no-cache curl >/dev/null 2>&1
              curl -s -X POST http://buzz-bot.buzz-bot.svc.cluster.local:3000/internal/cluster-topics \
                -H "Content-Type: application/json" \
                -w "\nHTTP %{http_code}\n"
          restartPolicy: OnFailure
```

- [ ] **Step 12: Commit branch 7A**

```bash
git add src/models/topic_cluster.cr src/web/routes/topic_clusters.cr src/web/server.cr src/config.cr migrations/019_topic_vectors_hnsw.sql k8s/cluster-cronjob.yaml
git commit -m "feat: in-db Crystal nightly topic clustering (single-linkage)"
```

---

### Task 7B: Python sklearn nightly CronJob — ✅ EXECUTE THIS BRANCH

Gate-locked params (from DECISION file): **linkage=complete, T=0.30, K=3**.
Plus a **TDD'd `is_noise_topic()` date/number filter** (gate amendment — the
topic corpus is polluted with date/timestamp fragments that would otherwise
become the biggest tags). The same `min(... -count, len, str)` tie-break as
`scripts/topic_cluster_experiment.py`'s `pick_label` is reused here.

**Files:**
- Create: `cluster-worker/cluster_job.py`
- Create: `cluster-worker/test_cluster_job.py` (pytest for `is_noise_topic`)
- Create: `cluster-worker/requirements.txt`
- Create: `cluster-worker/Dockerfile`
- Create: `cluster-worker/VERSION` (single source of truth, parity with embed-worker)
- Create: `cluster-worker/build.sh` (ctr-import build, parity with embed-worker)
- Create: `k8s/cluster-cronjob.yaml`

> No Crystal model is needed in this branch: Python does all writes, and the
> read path (Task 6) is inlined SQL against the `topic_clusters` table. The
> table is the only cross-branch contract.
> `requirements.txt` deliberately has NO pytest (don't bloat the prod image);
> run `test_cluster_job.py` in a throwaway venv that also has the runtime deps
> (numpy/psycopg2-binary/scikit-learn/requests) so `import cluster_job` resolves.

- [ ] **Step 1: Write the failing noise-filter test**

Create `cluster-worker/test_cluster_job.py`:

```python
from cluster_job import is_noise_topic


def test_filters_pure_date_number_noise():
    for s in ["03", "05", "00 00", "20 03", "13 03", "2026", "2026 07",
              "26 2026", "03 2026", "  12  05 ", "2026 год", "2026 году",
              "04 26", "00 01", "2026 14"]:
        assert is_noise_topic(s), f"should be noise: {s!r}"


def test_keeps_real_topics():
    for s in ["war", "экономика", "ukraine", "oorlog", "covid 19",
              "9 мая", "g7", "iran war", "блокировки telegram"]:
        assert not is_noise_topic(s), f"should be kept: {s!r}"
```

- [ ] **Step 2: Run test to verify it fails**

Run (venv with deps so `import cluster_job` resolves):
```bash
python3.11 -m venv /tmp/cw-venv && /tmp/cw-venv/bin/pip -q install pytest numpy psycopg2-binary scikit-learn requests
cd cluster-worker && PYTHONPATH=. /tmp/cw-venv/bin/python -m pytest test_cluster_job.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'cluster_job'`

- [ ] **Step 3: Create the job script**

Create `cluster-worker/cluster_job.py` (params already substituted to the gate decision; reuses Phase-1 pure logic by copy to keep the image self-contained):

```python
"""Nightly global topic clustering (sklearn). mechanism = python-sklearn.
Reads DATABASE_URL and embeds via the in-cluster BGE-M3 sidecar.
Gate decision: complete linkage, cosine-distance 0.30, K=3.
"""
import os
import re
import numpy as np
import psycopg2
import requests
from sklearn.cluster import AgglomerativeClustering

LINKAGE = os.environ.get("CLUSTER_LINKAGE", "complete")
THRESHOLD = float(os.environ.get("TOPIC_CLUSTER_DISTANCE", "0.30"))
K = int(os.environ.get("TOPIC_CLUSTER_MIN_COUNT", "3"))
SIDECAR = os.environ.get("EMBED_SIDECAR_URL", "http://embed-sidecar:8000")

# Gate amendment: drop date/number/timestamp fragments KeyBERT extracts from
# episode dates & timestamped show-notes. Without this they form the largest
# clusters and would dominate the tag cloud. Deterministic; unit-tested.
_NUM_ONLY = re.compile(r"[\d\s:.\-/]+")
_YEAR_WORD = re.compile(r"20\d{2}(\s+(год|году|year|jaar))?", re.IGNORECASE)


def is_noise_topic(t: str) -> bool:
    """True if the topic string is a pure date/number fragment (no real word).
    Conservative: only nukes strings that are ENTIRELY digits/separators, or a
    bare 4-digit year optionally followed by a year-word. Anything containing a
    real word (any language) is kept ('covid 19', '9 мая' survive).
    """
    s = t.strip()
    if not s:
        return True
    if _NUM_ONLY.fullmatch(s):
        return True
    if _YEAR_WORD.fullmatch(s):
        return True
    return False


def pick_label(members, counts):
    return min(members, key=lambda m: (-counts.get(m, 0), len(m), m))


def normalize_dsn(url):
    # buzz-bot's DATABASE_URL carries non-standard params (auth_methods, options)
    # that libpq/psycopg2 reject. psycopg2 sends SNI, so ?sslmode=require is
    # sufficient for Neon. Same strip embed-progress.sh applies for psql.
    return re.sub(r"\?.*$", "?sslmode=require", url)


def main():
    dsn = normalize_dsn(os.environ["DATABASE_URL"])
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()
    cur.execute(
        "SELECT t, COUNT(DISTINCT episode_id)::int "
        "FROM episode_embeddings, unnest(topics) AS t "
        "GROUP BY t HAVING COUNT(DISTINCT episode_id) >= %s", (K,))
    counts = {r[0]: r[1] for r in cur.fetchall()}
    # Gate amendment: strip date/number noise before embed/cluster/label.
    counts = {t: c for t, c in counts.items() if not is_noise_topic(t)}
    topics = sorted(counts)
    if len(topics) < 3:
        print(f"only {len(topics)} topics >= K={K}, nothing to do")
        return

    # Embed via sidecar; cache into topic_vectors.
    cur.execute("SELECT topic FROM topic_vectors")
    cached = {r[0] for r in cur.fetchall()}
    for t in topics:
        if t in cached:
            continue
        v = requests.post(f"{SIDECAR}/embed", json={"text": t}, timeout=60)
        v.raise_for_status()
        vec = v.json()["vector"]
        cur.execute(
            "INSERT INTO topic_vectors (topic, embedding, updated_at) "
            "VALUES (%s, %s::vector, now()) "
            "ON CONFLICT (topic) DO UPDATE SET embedding = EXCLUDED.embedding, "
            "updated_at = now()",
            (t, "[" + ",".join(map(str, vec)) + "]"))
    conn.commit()

    # Load all vectors for qualifying topics, in topic order.
    cur.execute(
        "SELECT topic, embedding FROM topic_vectors WHERE topic = ANY(%s) "
        "ORDER BY topic", (topics,))
    rows = cur.fetchall()
    ordered = [r[0] for r in rows]
    vecs = np.asarray(
        [[float(x) for x in r[1].strip("[]").split(",")] for r in rows])

    labels = AgglomerativeClustering(
        n_clusters=None, metric="cosine", linkage=LINKAGE,
        distance_threshold=THRESHOLD).fit_predict(vecs)

    groups = {}
    for topic, cid in zip(ordered, labels):
        groups.setdefault(int(cid), []).append(topic)

    # psycopg2 autocommit is off: TRUNCATE + all INSERTs commit as one atomic
    # transaction, so the tag cloud never sees a half-rebuilt clustering.
    cur.execute("TRUNCATE topic_clusters")
    for cid, members in groups.items():
        lbl = pick_label(members, counts)
        for t in members:
            cur.execute(
                "INSERT INTO topic_clusters (topic, cluster_id, label, updated_at) "
                "VALUES (%s, %s, %s, now())", (t, cid, lbl))
    conn.commit()
    print(f"clustered {len(ordered)} topics into {len(groups)} clusters")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run noise-filter test (passes) + syntax check**

Run:
```bash
cd cluster-worker && PYTHONPATH=. /tmp/cw-venv/bin/python -m pytest test_cluster_job.py -v
python -c "import ast; ast.parse(open('cluster_job.py').read()); print('syntax OK')"
```
Expected: `2 passed`; then `syntax OK`.

- [ ] **Step 5: Deps + image**

Create `cluster-worker/requirements.txt` (runtime only — NO pytest, keep the
prod image lean; the test runs in the dev venv from Step 2):

```
scikit-learn==1.5.1
psycopg2-binary==2.9.9
numpy==1.26.4
requests==2.32.3
```

Create `cluster-worker/VERSION` (single source of truth, parity with
`embed-worker/VERSION`):

```
1.0
```

Create `cluster-worker/Dockerfile` (`-u` for unbuffered logs + `ARG`/`LABEL`
version, matching `embed-worker/Dockerfile`):

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY cluster_job.py .
COPY VERSION .
ARG VERSION=dev
LABEL version=$VERSION
CMD ["python", "-u", "cluster_job.py"]
```

Create `cluster-worker/build.sh` (`chmod +x`). Unlike embed-worker/embed-sidecar
which `--push` to Docker Hub, cluster-worker is a LOCAL self-managed image
imported into k3s containerd (`imagePullPolicy:Never`), per project memory
`project_k3s_image_import`:

```bash
#!/usr/bin/env bash
# Build cluster-worker and import it into the single-node k3s containerd.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
IMAGE="cluster-worker:${VERSION}"
NODE="root@46.225.0.50"

echo "Building ${IMAGE} for linux/amd64..."
docker build --platform linux/amd64 --build-arg VERSION="${VERSION}" -t "${IMAGE}" .
docker save "${IMAGE}" -o /tmp/cluster-worker.tar
scp -i ~/.ssh/id_rsa /tmp/cluster-worker.tar "${NODE}:/tmp/"
ssh -i ~/.ssh/id_rsa "${NODE}" "ctr -n k8s.io images import /tmp/cluster-worker.tar"
echo "Imported ${IMAGE} into k3s (k8s.io namespace)"
```

- [ ] **Step 6: Build + import image into k3s** (controller runs this in Task 8)

Run the versioned build script (it does docker build → save → scp → `ctr -n
k8s.io images import`, per `project_k3s_image_import` memory):
```bash
./cluster-worker/build.sh
```
Expected: ends with `Imported cluster-worker:1.0 into k3s (k8s.io namespace)`.

- [ ] **Step 7: CronJob manifest**

Create `k8s/cluster-cronjob.yaml`:

```yaml
# k8s/cluster-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cluster-trigger
  namespace: buzz-bot
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cluster
            image: cluster-worker:1.0
            imagePullPolicy: Never
            envFrom:
            - secretRef:
                name: buzz-bot-env
            env:
            - name: EMBED_SIDECAR_URL
              value: "http://embed-sidecar:8000"
          restartPolicy: OnFailure
```

- [ ] **Step 8: Commit branch 7B**

```bash
git add cluster-worker/ k8s/cluster-cronjob.yaml
git commit -m "feat: python sklearn nightly topic clustering CronJob + date-noise filter"
```

---

## Phase 4 — Read path (mechanism-independent)

### Task 6: Cluster-aware tag cloud + filter SQL

**Files:**
- Modify: `src/models/episode_embedding.cr` (`top_tags_for_user`)
- Modify: `src/models/episode.cr` (`for_topic`)

> Do this after Task 5. It depends only on the `topic_clusters` table existing,
> not on which mechanism populates it. Until the first nightly run the table is
> empty and every topic falls back to a raw-string singleton (designed behavior).

- [ ] **Step 1: Rewrite `top_tags_for_user`**

In `src/models/episode_embedding.cr`, replace the SQL inside `top_tags_for_user` with:

```crystal
        SELECT COALESCE(tc.label, t) AS tag, COUNT(DISTINCT e.id)::int AS count
        FROM episodes e
        JOIN user_feeds uf ON uf.feed_id = e.feed_id
        JOIN episode_embeddings ee ON ee.episode_id = e.id,
             unnest(ee.topics) AS t
        LEFT JOIN topic_clusters tc ON tc.topic = t
        WHERE uf.user_id = $1
          AND COALESCE(tc.label, t) NOT IN (
            SELECT topic FROM user_hidden_topics WHERE user_id = $1)
        GROUP BY COALESCE(tc.label, t)
        ORDER BY count DESC
        LIMIT $2 OFFSET $3
```

(Leave the surrounding `query_each`, params `user_id, limit, offset`, and
`TagCount.new(rs.read(String), rs.read(Int32))` mapping unchanged.)

- [ ] **Step 2: Rewrite `for_topic`**

In `src/models/episode.cr`, locate the `for_topic` query (`WHERE uf.user_id = $1 AND $2 = ANY(ee.topics)`). Replace just the topic predicate so it matches any cluster member, falling back to exact match for un-clustered labels. Change the `WHERE` clause to:

```crystal
        WHERE uf.user_id = $1
          AND ee.topics && COALESCE(
            (SELECT array_agg(topic) FROM topic_clusters WHERE label = $2),
            ARRAY[$2]::text[])
```

(Keep `$1`/`$2`/`$3`/`$4` param order, ordering, `LIMIT`/`OFFSET`, and the
result mapping exactly as they were — only the topic-matching predicate changes.)

- [ ] **Step 3: Compile check**

Run: `crystal build src/buzz_bot.cr -o /tmp/buzz_bot_check`
Expected: builds with no errors.

- [ ] **Step 4: Manual SQL verification (empty `topic_clusters` → fallback)**

Run (substitute a real `user_id` that has topics):
```bash
DBURL=$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
nix-shell --packages postgresql --run "psql \"$DBURL\" -c \"
  SELECT COALESCE(tc.label,t) tag, COUNT(DISTINCT e.id) c
  FROM episodes e JOIN user_feeds uf ON uf.feed_id=e.feed_id
  JOIN episode_embeddings ee ON ee.episode_id=e.id, unnest(ee.topics) t
  LEFT JOIN topic_clusters tc ON tc.topic=t
  WHERE uf.user_id=(SELECT id FROM users LIMIT 1)
  GROUP BY 1 ORDER BY c DESC LIMIT 5;\""
```
Expected: returns raw topic strings with counts (no errors) — confirms the
LEFT JOIN/COALESCE works before any clustering exists.

- [ ] **Step 5: Commit**

```bash
git add src/models/episode_embedding.cr src/models/episode.cr
git commit -m "feat: cluster-aware tag cloud aggregation + topic filter"
```

---

## Phase 5 — Deploy + backfill

### Task 8: Deploy, first run, verify

**Files:** none (operational)

- [ ] **Step 1: Deploy buzz-bot (read-path changes) + build cluster-worker image**

```bash
k8s/deploy.sh            # buzz-bot: build, tar, scp, containerd import, rollout
./cluster-worker/build.sh   # cluster-worker:1.0 → k3s containerd (k8s.io ns)
```
Expected: buzz-bot rollout succeeds; build.sh ends with
`Imported cluster-worker:1.0 into k3s (k8s.io namespace)`. (The CronJob in the
next step references `cluster-worker:1.0` with `imagePullPolicy:Never`, so the
image MUST be imported first or the pod will `ErrImageNeverPull`.)

- [ ] **Step 2: Apply the CronJob**

Run:
```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot apply -f k8s/cluster-cronjob.yaml
```
Expected: `cronjob.batch/cluster-trigger created`.

- [ ] **Step 3: Trigger the first run manually**

```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot create job --from=cronjob/cluster-trigger cluster-manual-1
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot logs -f job/cluster-manual-1
```
Expected: job logs `clustered N topics into M clusters` (gate=3B/sklearn).

- [ ] **Step 4: Verify clustering landed**

```bash
DBURL=$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
nix-shell --packages postgresql --run "psql \"$DBURL\" \
  -c 'SELECT count(*) topics, count(DISTINCT cluster_id) clusters FROM topic_clusters;' \
  -c 'SELECT label, count(*) FROM topic_clusters GROUP BY label HAVING count(*)>1 ORDER BY 2 DESC LIMIT 10;'"
```
Expected: non-zero topics/clusters; multi-member clusters show plausible synonym/translation groupings.

- [ ] **Step 5: Verify the tag cloud end-to-end**

Open https://app.buzz-bot.top, go to Topics. Expected: consolidated cross-lingual tags with summed counts; clicking a clustered tag lists episodes from any member string; the × hides the whole cluster; un-clustered tags still behave as before.

- [ ] **Step 6: Clean up the manual job**

```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot delete job cluster-manual-1
```

- [ ] **Step 7: Final commit (if any operational tweaks were needed)**

```bash
# scope explicitly — never `git add -A` (untracked .superpowers/, docs/ideas.md,
# k8s/tg-api-ingress.yaml are unrelated and must NOT be committed)
git add cluster-worker/ k8s/cluster-cronjob.yaml docs/superpowers/ 2>/dev/null
git commit -m "chore: topic clustering deployed + verified" || echo "nothing to commit"
```

---

## Self-review notes (author)

- **Spec coverage:** Phase 1 experiment+gate → spec Phase 1 + locked "threshold/mechanism" decisions. Task 5 → spec Phase 2 schema. Task 6 → spec Phase 4 read path (all 3 SQL changes; `hide_topic` intentionally unmodified — covered by the aggregation's `COALESCE(label,t) NOT IN hidden`). Tasks 7A/7B → spec Phase 3 (both mechanisms fully written; gate picks one). Task 8 → spec "implementation order" #5.
- **Accepted-risk fidelity:** multilingual label, stale-hide, global-vs-per-user, TRUNCATE lock — all inherited from the spec; no task attempts to "fix" an accepted trade-off.
- **Cross-branch contract:** Task 6's read path is inlined SQL against the `topic_clusters` *table* — it works identically whether 7A (Crystal) or 7B (Python) populated it. No shared Crystal helper, so no signature-drift surface.
- **Type consistency:** `pick_label` tie-break key `(-count, len, str)` is identical in Python (`scripts/topic_cluster_experiment.py`, `cluster-worker/cluster_job.py`) and Crystal (7A `min_by { {-counts[m], m.size, m} }`); Crystal Tuple compares element-wise so behavior matches Python's tuple key. `normalize_dsn` (7B) mirrors the `embed-progress.sh` / Task-3-runner strip so all three Python DB entry points reach Neon identically.
- **No placeholders:** `<T>/<K>/<linkage>/<mechanism>` are explicitly defined as substitution tokens sourced from the committed DECISION file (Task 4), not TODOs.
