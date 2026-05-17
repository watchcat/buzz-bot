# KeyBERT source noise fix (#90) — design

Date: 2026-05-17
Status: approved (pre-implementation)
Repo: buzz-bot (embed-worker)
Tracking: follow-up #90 from the topic-clustering work

## Problem

`embed-worker/handler.py::extract_topics` runs KeyBERT over the text buzz-bot
sends (`embeddings.cr:50-66`): the episode title plus every timestamped
show-notes line **with its leading timestamp intact** (`00:00 — Introduction`,
`1:23:45 — Future of gaming`), plus whatever dates/numbers appear in titles and
notes. KeyBERT's CountVectorizer turns those digits into keyword n-grams
(`00 00`, `03 2026`, `26 2026`, `2026 14`, `493`). It also uses the default
`stop_words='english'`, which does nothing for the Russian/Dutch content, so
filler/segment-name junk (`moet ik`, `это было`, `итоги вторника`, `утро`) is
extracted too.

Downstream `is_noise_topic` (cluster-worker) and the read-path SQL regex
(Task 9) *hide* the pure-numeric class, but: (a) they're conservative and miss
the word-junk, (b) noise consumes KeyBERT's `top_n` budget, reducing real-topic
recall, and (c) `topic_clusters` / the tag cloud are built on dirty source data.
This fixes the noise **at the source**.

## Goals

- `episode_embeddings.topics` contains no date/number/timestamp fragments and no
  multilingual filler/segment-name junk — clean at the point of extraction.
- Real number-bearing topics survive (`covid 19`, `g7`, `gpt 4`, `9 мая`,
  `1917`) — surgical, recall-preserving.
- Existing corpus (~17,138 episodes) re-extracted so stored topics become
  genuinely clean, not just hidden.
- Zero risk to verified BGE-M3 vectors, the Crystal read path, or DB schema.

## Non-goals

- No Crystal/DB/schema changes. No change to the embedding-vector input text.
- Not removing the downstream `is_noise_topic`/SQL guards — they remain as
  belt-and-suspenders (now non-load-bearing).
- No new clustering parameters; the nightly cluster job is unchanged (it just
  re-runs on cleaner data).

## Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Backfill scope | **Full re-extract** of all ~17k episodes |
| Numeric aggressiveness | **Surgical** — strip timestamp/date *input*, reject entirely-numeric *keyphrases*; keep number-bearing real topics |
| Backfill mechanism | **Reuse the existing full re-embed dispatch** (recompute vector+topics; accept ~2× RunPod cost; no new worker code path) |
| Extra scope | **Also** fix multilingual word-junk via en+ru+nl stop-words |
| Architecture | **Approach A** — all topic hygiene co-located in `embed-worker/handler.py` |

## Design corrections surfaced during brainstorming (binding)

1. **No `min_df`.** KeyBERT fits its CountVectorizer on a *single document*, so
   `min_df > 1` discards every term. `min_df` is a footgun here and is **not
   used**. Word-junk is controlled by stop-words + the noise guard only.
2. **Candidate-level, not token-level, numeric handling.** A token pattern that
   drops all-digit tokens would prevent the `19` in `covid 19` from forming the
   n-gram. The default token pattern is kept; only *entirely*-numeric
   **keyphrases** are rejected via `is_noise_topic`. Input cleaning removes the
   bulk upstream so over-fetch + filter still yields a full set of clean topics.

## Architecture

All changes are in `embed-worker/` (the RunPod serverless image). The
embedding-vector path is untouched.

### Components (each independently testable)

- `embed-worker/stopwords.py` — `STOPWORDS: frozenset[str]`, a vendored static
  union of English + Russian + Dutch stop-words. No NLTK/heavy dependency.
  One module, one responsibility (the data), trivially testable for membership.

- `clean_topic_input(text: str) -> str` (in `handler.py`) — line-wise input
  hygiene for the KeyBERT-only text. Per line:
  - strip a leading chapter-timestamp prefix:
    `^\s*\d{1,2}:\d{2}(:\d{2})?\s*[—–\-:.)\]]*\s*`
  - within the remaining text, blank out standalone time tokens
    `\b\d{1,2}:\d{2}(:\d{2})?\b` and explicit date strings
    `\b\d{1,4}[./-]\d{1,2}[./-]\d{1,4}\b`
  - leave all words and number-bearing words intact (`covid 19`, `9 мая`,
    `gpt 4` survive). Robust to empty/None and non-timestamp lines.

- `is_noise_topic(phrase: str) -> bool` (in `handler.py`) — **byte-for-byte the
  same rule** as cluster-worker's `is_noise_topic` and the Task 9 SQL regex:
  - `_NUM_ONLY = re.compile(r"[\d\s:.\-/]+")` → `fullmatch` ⇒ noise
  - `_YEAR_WORD = re.compile(r"20\d{2}(\s+(год|году|year|jaar))?", re.I)` →
    `fullmatch` ⇒ noise
  - empty/whitespace ⇒ noise. Used as a *keyphrase* post-filter.

- `extract_topics(text: str, top_n: int = 10) -> list[str]` (rewritten):
  1. `cleaned = clean_topic_input(text)`; return `[]` if blank.
  2. KeyBERT `extract_keywords(cleaned, keyphrase_ngram_range=(1,2),
     top_n=15, use_mmr=True, diversity=0.3,
     vectorizer=CountVectorizer(stop_words=sorted(STOPWORDS)))`
     — over-fetch 15 to absorb post-filter losses; default token pattern.
  3. Drop phrases where `is_noise_topic(phrase)`.
  4. De-dupe (case-insensitive, preserve order), return first `top_n` (10).

  Note: `CountVectorizer` is constructed per call (KeyBERT requires a fresh
  vectorizer per document); `STOPWORDS` is module-level and reused.

### Data flow

buzz-bot `embeddings.cr` (unchanged) → RunPod `handler` →
`embed_episode` (raw `episode["text"]`, **unchanged**) +
`extract_topics` (new pipeline) → callback `/internal/embeddings_result`
(unchanged) → `episode_embeddings.topics` clean at source. The nightly cluster
job and read-path regex are unchanged and now operate on clean data.

## Backfill

The hourly embed cron selects `unembedded → untopicked(topics='{}') →
stale(source='description')`. All ~17k done episodes are embedded, topicked,
and `source='title'`, so none are selected. The one-off trigger:

```sql
UPDATE episode_embeddings SET source = 'description';
```

This routes every row through the **existing** `stale_source_episode_ids`
path (`WHERE source='description'`), which the hourly cron drains ~100/run,
re-embedding each with the new worker (handler resets `source='title'` on
upsert). Properties: graceful (each row's vector/topics stay live until its turn
— no empty tag cloud), self-draining (~17k / 100 per hour ≈ 7 days, same
cadence as the original BGE-M3 migration), zero new code. After the drain
completes, manually trigger the nightly cluster CronJob once to rebuild
`topic_clusters` from clean data.

## Deploy ordering (mandatory — `project-embedding-stack` memory)

Image-tag updates do not override per-endpoint env vars and RunPod does not
flash warm workers. Sequence:

1. Implement + tests pass locally.
2. Bump `embed-worker/VERSION` `2.0 → 2.1`.
3. `embed-worker/build.sh` (builds + pushes `watchcat/embed-worker:2.1`).
4. Update the RunPod embed endpoint image to `2.1`; **verify the endpoint's
   `MODEL_NAME` env is still `BAAI/bge-m3`** (or unset); **scale workers to 0**
   to force a cold reload of the new image.
5. Spot-check: trigger one normal embed run, confirm topics are clean (no
   numeric/date/junk) for the processed episodes.
6. Only then run the backfill `UPDATE … SET source='description'`.
7. Monitor the drain (topic noise drops over days). When complete, run the
   cluster CronJob manually to rebuild `topic_clusters`.

## Error handling

- `clean_topic_input`: total function — empty/None/garbage in ⇒ `""` or
  best-effort cleaned text out; never raises.
- `extract_topics`: blank cleaned text ⇒ `[]` (preserves current contract).
  Fewer than 10 survivors after filtering ⇒ return what survives (no error).
- `handler` loop already catches per-episode exceptions and continues
  (unchanged) — a bad episode never blocks the batch.
- Stop-word list must not contain words that are legitimate standalone topics;
  the curated list is conservative (function words only) and unit-tested.

## Testing

pytest in `embed-worker/` (mirrors the cluster-worker pattern; `requirements`
stays runtime-only, tests run in a dev venv):

- `clean_topic_input`: leading `MM:SS`/`H:MM:SS` prefixes stripped while the
  chapter label is preserved; inline time/date strings blanked; `covid 19`,
  `9 мая`, `gpt 4` text preserved; empty/None safe.
- `is_noise_topic`: the **same** noise/keep assertion table used in
  `cluster-worker/test_cluster_job.py` (kept in sync — drift between the two is
  a test failure by construction).
- `STOPWORDS`: contains representative en/ru/nl function words
  (`the`, `и`/`это`, `de`/`het`); does **not** contain plausible topic words
  (`war`, `экономика`, `oorlog`).
- `extract_topics`: a guarded model-backed test over a synthetic
  title+chapter-list fixture — asserts no `is_noise_topic` phrase in the
  output, real chapter labels present, `len ≤ 10`. (Model is heavy; run in the
  venv like prior tasks; primary validation is the post-backfill DB
  observation.)

## Accepted trade-offs

- `is_noise_topic` now exists in **3** places (embed-worker, cluster-worker,
  Task 9 SQL). Intentional: #90 makes the embed-worker the *root* fix; the other
  two become non-load-bearing safety nets. The shared assertion table keeps the
  two Python copies in sync; SQL equivalence was already verified in Task 9.
- ~2× RunPod GPU cost for the one-time full re-embed backfill (vectors
  recomputed redundantly) — accepted for zero new code and graceful drain.
- Vendored static stop-word list can miss long-tail filler; acceptable — the
  goal is removing the dominant junk, not perfection. Tunable later.

## Success criteria

- After worker deploy: newly embedded episodes have zero pure-numeric/date
  topics and no obvious en/ru/nl filler in `topics`.
- After backfill drain + cluster rebuild: tag cloud shows no `03`-class tags
  *without relying on the read-path regex*, and word-junk
  (`moet ik`, `итоги вторника`, `утро`) is gone or sharply reduced.
- Real number-bearing topics still present where relevant.
- Downstream guards still in place but now redundant (verify they match nothing
  on a sample of fresh data).

## Implementation order

1. `stopwords.py` + `clean_topic_input` + `is_noise_topic` (TDD, pure units).
2. Rewrite `extract_topics` to use them; guarded model test.
3. Bump `VERSION`; (build/deploy/backfill are operator steps, sequenced above —
   executed by the user, as with prior deploys).
