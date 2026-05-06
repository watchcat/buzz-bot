# Explain Topics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add human-readable topic keywords to recommendation explanations — show matching topics instead of raw vector scores.

**Architecture:** KeyBERT extracts topics at embed time in the RunPod worker, stored in `episode_embeddings.topics`. The recommendation SQL computes topic overlap using Postgres array intersection. The frontend shows matching topics in place of the vector score number.

**Tech Stack:** KeyBERT (Python), pgvector + Postgres arrays (SQL), Crystal/Kemal (backend), ClojureScript/Reagent (frontend)

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `migrations/015_episode_topics.sql` | Add topics column to episode_embeddings |
| Create | `embed-worker/VERSION` | Image version tag |
| Modify | `embed-worker/requirements.txt` | Add keybert dependency |
| Modify | `embed-worker/handler.py` | Extract topics with KeyBERT alongside embeddings |
| Modify | `embed-worker/Dockerfile` | Pre-download keybert, version label |
| Modify | `src/web/routes/embeddings.cr` | Accept topics in callback, backfill query |
| Modify | `src/models/episode_embedding.cr` | Store/read topics, backfill method |
| Modify | `src/models/episode.cr:171-222` | Add matching_topics to ScoredEpisode + SQL |
| Modify | `src/web/json_helpers.cr:49-68` | Add matching_topics to RecJson |
| Modify | `src/cljs/buzz_bot/views/player.cljs:135-160` | Show topics in place of vector score |

---

### Task 1: Database Migration

**Files:**
- Create: `migrations/015_episode_topics.sql`

- [ ] **Step 1: Create the migration file**

```sql
-- migrations/015_episode_topics.sql
ALTER TABLE episode_embeddings ADD COLUMN topics TEXT[] NOT NULL DEFAULT '{}';
```

- [ ] **Step 2: Run the migration against Neon**

```bash
DB_URL=$(grep ^DATABASE_URL .env | cut -d= -f2- | sed 's/&auth_methods=[^&]*//')
nix-shell -p postgresql --run "psql '$DB_URL' -f migrations/015_episode_topics.sql"
```

Expected: `ALTER TABLE`

- [ ] **Step 3: Verify the column exists**

```bash
nix-shell -p postgresql --run "psql '$DB_URL' -c \"SELECT column_name, data_type FROM information_schema.columns WHERE table_name='episode_embeddings' AND column_name='topics'\""
```

Expected: One row showing `topics | ARRAY`

- [ ] **Step 4: Commit**

```bash
git add migrations/015_episode_topics.sql
git commit -m "feat: add topics column to episode_embeddings"
```

---

### Task 2: Embed Worker — KeyBERT Topic Extraction

**Files:**
- Create: `embed-worker/VERSION`
- Modify: `embed-worker/requirements.txt`
- Modify: `embed-worker/handler.py`
- Modify: `embed-worker/Dockerfile`

- [ ] **Step 1: Create VERSION file**

```
1.1
```

Write this to `embed-worker/VERSION`.

- [ ] **Step 2: Add keybert to requirements.txt**

Add this line to `embed-worker/requirements.txt`:

```
keybert==0.8.5
```

Full file becomes:

```
runpod==1.6.2
sentence-transformers==3.0.1
torch==2.3.1
requests==2.32.3
keybert==0.8.5
```

- [ ] **Step 3: Add topic extraction to handler.py**

Add the KeyBERT import and extractor initialization after the existing model globals (after line 12):

```python
from keybert import KeyBERT

kw_model = None

def get_kw_model():
    global kw_model
    if kw_model is None:
        kw_model = KeyBERT(model=get_model())
    return kw_model
```

Add a new function after `embed_episode` (after line 55):

```python
def extract_topics(text: str, top_n: int = 10) -> list[str]:
    """Extract diverse keyphrases from text using KeyBERT + MMR."""
    km = get_kw_model()
    keywords = km.extract_keywords(
        text,
        keyphrase_ngram_range=(1, 2),
        top_n=top_n,
        use_mmr=True,
        diversity=0.3,
    )
    return [kw for kw, _score in keywords]
```

Modify the episode processing loop in `handler` (lines 66-71) to also extract topics:

```python
    results = []
    for ep in episodes:
        try:
            vector = embed_episode(ep)
            topics = extract_topics(ep["text"])
            results.append({"id": ep["id"], "vector": vector, "topics": topics})
        except Exception as e:
            print(f"Failed to embed episode {ep.get('id')}: {e}")
            continue
```

Update the callback payload (line 79) to include topics:

```python
    payload = {"embeddings": results, "source": source}
```

No change needed — `results` already includes topics in each item dict. The callback endpoint will read them.

- [ ] **Step 4: Update Dockerfile with version label**

Replace the entire Dockerfile with:

```dockerfile
# embed-worker/Dockerfile
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

CMD ["python", "-u", "handler.py"]
```

Build with: `docker build --build-arg VERSION=$(cat embed-worker/VERSION) -t embed-worker:$(cat embed-worker/VERSION) embed-worker/`

- [ ] **Step 5: Test locally (smoke test)**

```bash
cd embed-worker
nix-shell -p python311 python311Packages.pip --run "
  pip install -r requirements.txt --quiet
  python -c \"
from handler import embed_episode, extract_topics
text = 'Machine learning is transforming how we build software. Deep neural networks and transformers power modern AI.'
vec = embed_episode({'id': 1, 'text': text})
topics = extract_topics(text)
print(f'Vector dims: {len(vec)}')
print(f'Topics: {topics}')
assert len(vec) == 384
assert len(topics) > 0
assert len(topics) <= 10
print('OK')
\"
"
```

Expected: `Vector dims: 384`, `Topics: [...]` with relevant ML keywords, `OK`

- [ ] **Step 6: Commit**

```bash
git add embed-worker/VERSION embed-worker/requirements.txt embed-worker/handler.py embed-worker/Dockerfile
git commit -m "feat: add KeyBERT topic extraction to embed worker"
```

---

### Task 3: Backend — Accept Topics in Callback and Store

**Files:**
- Modify: `src/models/episode_embedding.cr`
- Modify: `src/web/routes/embeddings.cr`

- [ ] **Step 1: Update EpisodeEmbedding.upsert to accept topics**

In `src/models/episode_embedding.cr`, replace the `upsert` method (lines 5-18) with:

```crystal
def self.upsert(episode_id : Int64, embedding : Array(Float64), source : String, topics : Array(String) = [] of String)
  vector_str = "[#{embedding.join(",")}]"
  topics_literal = "{#{topics.map { |t| "\"#{t.gsub("\"", "\\\"")}\"" }.join(",")}}"
  AppDB.pool.exec(
    <<-SQL,
      INSERT INTO episode_embeddings (episode_id, embedding, source, topics, updated_at)
      VALUES ($1, $2::vector, $3, $4::text[], now())
      ON CONFLICT (episode_id) DO UPDATE SET
        embedding  = EXCLUDED.embedding,
        source     = EXCLUDED.source,
        topics     = EXCLUDED.topics,
        updated_at = now()
    SQL
    episode_id, vector_str, source, topics_literal
  )
end
```

Add a method for the backfill query (after `unembedded_episode_ids`, after line 47):

```crystal
# Returns episode IDs that have embeddings but no topics (for backfill).
def self.untopicked_episode_ids(limit : Int32 = 100) : Array(NamedTuple(id: Int64, title: String, description: String?))
  results = [] of NamedTuple(id: Int64, title: String, description: String?)
  AppDB.pool.query_each(
    <<-SQL,
      SELECT e.id, e.title, e.description
      FROM episodes e
      JOIN episode_embeddings ee ON ee.episode_id = e.id
      WHERE ee.topics = '{}'
      ORDER BY e.published_at DESC NULLS LAST
      LIMIT $1
    SQL
    limit
  ) do |rs|
    results << {id: rs.read(Int64), title: rs.read(String), description: rs.read(String?)}
  end
  results
end
```

- [ ] **Step 2: Update CallbackPayload and EmbeddingResult structs**

In `src/web/routes/embeddings.cr`, update the `EmbeddingResult` struct (lines 10-14) to include topics:

```crystal
private struct EmbeddingResult
  include JSON::Serializable
  getter id : Int64
  getter vector : Array(Float64)
  getter topics : Array(String) = [] of String
end
```

- [ ] **Step 3: Pass topics through in the callback handler**

In `src/web/routes/embeddings.cr`, update the embedding storage loop (lines 98-103) to pass topics:

```crystal
count = 0
payload.embeddings.each do |item|
  next if item.vector.size != 384
  EpisodeEmbedding.upsert(item.id, item.vector, payload.source, item.topics)
  count += 1
end
```

- [ ] **Step 4: Extend the embed trigger to also backfill topics**

In `src/web/routes/embeddings.cr`, in the `/internal/embed` handler, after the `if episodes.empty?` block (after line 36), add a fallback to backfill untopicked episodes:

```crystal
episodes = EpisodeEmbedding.unembedded_episode_ids(100)

# If no new episodes to embed, backfill topics for existing embeddings
if episodes.empty?
  episodes = EpisodeEmbedding.untopicked_episode_ids(100)
  if episodes.empty?
    env.response.content_type = "application/json"
    next({ok: true, dispatched: 0}.to_json)
  end
end
```

Replace the existing empty-check block (lines 33-36):

```crystal
if episodes.empty?
  env.response.content_type = "application/json"
  next({ok: true, dispatched: 0}.to_json)
end
```

With the expanded version above.

- [ ] **Step 5: Commit**

```bash
git add src/models/episode_embedding.cr src/web/routes/embeddings.cr
git commit -m "feat: accept and store topics from embed worker callback"
```

---

### Task 4: Backend — Add Topic Overlap to Recommendation Query

**Files:**
- Modify: `src/models/episode.cr:171-222`
- Modify: `src/web/json_helpers.cr:49-68`

- [ ] **Step 1: Update ScoredEpisode record**

In `src/models/episode.cr`, replace the `ScoredEpisode` record (line 171) with:

```crystal
record ScoredEpisode, episode : Episode, vector_score : Float64, collab_score : Float64, score : Float64, matching_topics : Array(String), total_matching : Int32
```

- [ ] **Step 2: Update the recommendation SQL query**

In `src/models/episode.cr`, replace the `recommended_for_episode` method (lines 173-222) with:

```crystal
def self.recommended_for_episode(episode_id : Int64, limit : Int32 = 5) : Array(ScoredEpisode)
  results = [] of ScoredEpisode
  AppDB.pool.query_each(
    <<-SQL,
      WITH vector_recs AS (
        SELECT e.id, 1 - (ee.embedding <=> target.embedding) AS sim_score
        FROM episode_embeddings ee
        JOIN episodes e ON e.id = ee.episode_id
        CROSS JOIN episode_embeddings target
        WHERE target.episode_id = $1
          AND ee.episode_id != $1
        ORDER BY ee.embedding <=> target.embedding
        LIMIT 20
      ),
      collab_recs AS (
        SELECT ue.episode_id AS id, COUNT(*)::float AS collab_score
        FROM user_episodes ue
        WHERE ue.liked = TRUE
          AND ue.user_id IN (
            SELECT user_id FROM user_episodes
            WHERE episode_id = $1 AND liked = TRUE
          )
          AND ue.episode_id != $1
        GROUP BY ue.episode_id
      ),
      combined AS (
        SELECT
          COALESCE(v.id, c.id) AS id,
          COALESCE(v.sim_score, 0) AS vector_score,
          COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) AS collab_score,
          COALESCE(v.sim_score, 0) * 0.7
            + COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) * 0.3
            AS score
        FROM vector_recs v
        FULL OUTER JOIN collab_recs c ON v.id = c.id
      )
      SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url,
             cb.vector_score, cb.collab_score, cb.score,
             COALESCE((src_ee.topics & rec_ee.topics)[:3], '{}') AS matching_topics,
             COALESCE(array_length(src_ee.topics & rec_ee.topics, 1), 0)::int AS total_matching
      FROM episodes e
      JOIN combined cb ON e.id = cb.id
      LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id
      LEFT JOIN episode_embeddings src_ee ON src_ee.episode_id = $1
      ORDER BY cb.score DESC
      LIMIT $2
    SQL
    episode_id, limit
  ) do |rs|
    ep = from_rs(rs)
    vector_score = rs.read(Float64)
    collab_score = rs.read(Float64)
    score = rs.read(Float64)
    matching_topics_raw = rs.read(Array(String))
    total_matching = rs.read(Int32)
    results << ScoredEpisode.new(ep, vector_score, collab_score, score, matching_topics_raw, total_matching)
  end
  results
end
```

Key changes from the existing query:
- Added `LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id` for the recommended episode's topics
- Added `LEFT JOIN episode_embeddings src_ee ON src_ee.episode_id = $1` for the source episode's topics (LEFT JOIN instead of CROSS JOIN so recs from collab-only still appear even if source has no embedding)
- Added `matching_topics` and `total_matching` to SELECT using Postgres `&` array intersection operator
- `[:3]` slices to first 3 matching topics

- [ ] **Step 3: Update RecJson to include topics**

In `src/web/json_helpers.cr`, replace the `RecJson` struct (lines 49-68) with:

```crystal
# Rec item (flat struct for recommendations in player response)
struct RecJson
  include JSON::Serializable
  property id              : Int64
  property title           : String
  property feed_id         : Int64
  property feed_title      : String
  property vector_score    : Float64
  property collab_score    : Float64
  property score           : Float64
  property matching_topics : Array(String)
  property total_matching  : Int32

  def initialize(scored : Episode::ScoredEpisode, feed_title : String)
    @id              = scored.episode.id
    @title           = scored.episode.title
    @feed_id         = scored.episode.feed_id
    @feed_title      = feed_title
    @vector_score    = scored.vector_score
    @collab_score    = scored.collab_score
    @score           = scored.score
    @matching_topics = scored.matching_topics
    @total_matching  = scored.total_matching
  end
end
```

- [ ] **Step 4: Build to verify compilation**

```bash
nix-shell -p crystal shards pkg-config openssl --run 'crystal build src/buzz_bot.cr --no-codegen'
```

Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add src/models/episode.cr src/web/json_helpers.cr
git commit -m "feat: add topic overlap to recommendation query and response"
```

---

### Task 5: Frontend — Display Matching Topics

**Files:**
- Modify: `src/cljs/buzz_bot/views/player.cljs:135-160`

- [ ] **Step 1: Update the recs-section score display**

In `src/cljs/buzz_bot/views/player.cljs`, replace the `recs-section` component (lines 135-160) with:

```clojure
(defn- recs-section [recs]
  (let [show-scores? (r/atom false)]
    (fn [recs]
      [:div.recs-section
       [:div.recs-header
        {:style {:display "flex" :justify-content "space-between" :align-items "center"}}
        [:h3.recs-title "Listeners also liked"]
        [:span.recs-scores-toggle
         {:on-click #(swap! show-scores? not)
          :style {:cursor "pointer" :font-size "0.75rem" :opacity 0.5}}
         (if @show-scores? "Hide scores" "Show scores")]]
       [:ul.recs-list
        (for [rec recs]
          ^{:key (:id rec)}
          [:li.rec-item
           {:on-click #(rf/dispatch [::events/navigate :player {:episode-id (:id rec)}])}
           [:div.rec-info
            [:span.rec-feed  (:feed_title rec)]
            [:span.rec-title (:title rec)]
            (when @show-scores?
              (let [topics (seq (:matching_topics rec))
                    total  (or (:total_matching rec) 0)]
                [:span.rec-scores
                 {:style {:font-size "0.65rem" :opacity 0.5 :font-family "monospace"}}
                 (if topics
                   (str (str/join ", " (:matching_topics rec))
                        (when (> total 3) (str " +" (- total 3) " more"))
                        " | collab: " (.toFixed (or (:collab_score rec) 0) 2)
                        " | combined: " (.toFixed (or (:score rec) 0) 2))
                   (str "vector: " (.toFixed (or (:vector_score rec) 0) 2)
                        " | collab: " (.toFixed (or (:collab_score rec) 0) 2)
                        " | combined: " (.toFixed (or (:score rec) 0) 2)))]))]
           [:span.rec-play "▶"]])]])))
```

Key changes:
- Checks if `matching_topics` is non-empty
- If topics exist: shows `AI, machine learning, GPT +2 more | collab: 0.45 | combined: 0.69`
- If no topics: falls back to the existing `vector: 0.82 | collab: 0.45 | combined: 0.69`

- [ ] **Step 2: Compile ClojureScript**

```bash
npx shadow-cljs release app
```

Expected: Build success, no warnings.

- [ ] **Step 3: Stage compiled JS**

```bash
git add -f public/js/main.js
```

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/views/player.cljs
git commit -m "feat: show matching topics in recommendation explanations"
```

---

### Task 6: Build and Deploy

- [ ] **Step 1: Build the embed worker Docker image**

```bash
docker build --build-arg VERSION=$(cat embed-worker/VERSION) \
  -t embed-worker:$(cat embed-worker/VERSION) \
  embed-worker/
```

- [ ] **Step 2: Push embed worker to Docker Hub (or your registry)**

Tag and push with the version from the VERSION file.

- [ ] **Step 3: Update RunPod endpoint to use new image version**

In the RunPod dashboard, update the serverless endpoint to use the new `embed-worker:1.1` image.

- [ ] **Step 4: Build and deploy the Crystal app**

```bash
bash k8s/deploy.sh
```

- [ ] **Step 5: Trigger a backfill run**

```bash
kubectl -n buzz-bot create job --from=cronjob/embed-trigger embed-backfill-topics
```

This triggers the embed CronJob immediately. Since all episodes already have embeddings, it falls through to the `untopicked_episode_ids` path and re-embeds them with topics.

- [ ] **Step 6: Verify topics are being stored**

```bash
DB_URL=$(grep ^DATABASE_URL .env | cut -d= -f2- | sed 's/&auth_methods=[^&]*//')
nix-shell -p postgresql --run "psql '$DB_URL' -c \"SELECT episode_id, topics FROM episode_embeddings WHERE topics != '{}' LIMIT 5\""
```

Expected: Rows showing episode IDs with topic arrays.

- [ ] **Step 7: Verify the player API returns topics**

Open the app, navigate to an episode with recommendations, toggle "Show scores" — matching topics should appear instead of the vector score number.

- [ ] **Step 8: Commit any remaining changes**

```bash
git add -A
git commit -m "chore: deploy explain-topics feature"
```
