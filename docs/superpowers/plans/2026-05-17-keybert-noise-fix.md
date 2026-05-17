# KeyBERT Source Noise Fix (#90) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `embed-worker` KeyBERT from emitting date/number/timestamp fragments and multilingual filler into `episode_embeddings.topics`, at the source.

**Architecture:** Pure topic-hygiene logic moves into a dependency-free `embed-worker/topic_clean.py` (timestamp/date input cleaning + an `is_noise_topic` keyphrase guard) plus a static `embed-worker/stopwords.py` (en+ru+nl). `handler.py::extract_topics` is rewritten to clean input → run KeyBERT with a multilingual-stopword `CountVectorizer` (over-fetch) → drop noise keyphrases → de-dupe → top 10. The embedding-vector path is untouched. A version bump + RunPod redeploy + a one-off `source` flip drives the full re-extract backfill through the existing cron path.

**Tech Stack:** Python 3.11, KeyBERT 0.8.5, scikit-learn `CountVectorizer`, sentence-transformers/BGE-M3, RunPod serverless, pytest.

**Spec:** `docs/superpowers/specs/2026-05-17-keybert-noise-fix-design.md`

**Structural note (intentional deviation from spec wording):** the spec placed `clean_topic_input`/`is_noise_topic` "in handler.py". This plan puts them in a new pure module `embed-worker/topic_clean.py` (imports only `re`) so they are unit-testable without installing torch/runpod/keybert. Behavior and the `extract_topics` interface are unchanged.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `embed-worker/stopwords.py` | Static `STOPWORDS: frozenset[str]` (en+ru+nl function words). Data only, no imports. | 1 |
| `embed-worker/test_stopwords.py` | pytest: representative function words present; topic words absent. | 1 |
| `embed-worker/topic_clean.py` | Pure `is_noise_topic` + `clean_topic_input`. Imports only `re`. | 2, 3 |
| `embed-worker/test_topic_clean.py` | pytest: noise guard (mirrors cluster-worker table) + input cleaning. | 2, 3 |
| `embed-worker/handler.py` | Rewrite `extract_topics` to wire cleaning + multilingual `CountVectorizer` + guard. | 4 |
| `embed-worker/Dockerfile` | Add `COPY stopwords.py .` + `COPY topic_clean.py .` so the new modules ship in the RunPod image (else runtime `ModuleNotFoundError`). | 4 |
| `embed-worker/requirements.txt` | Add explicit `scikit-learn==1.5.1` (was transitive via keybert). | 4 |
| `embed-worker/VERSION` | `2.0` → `2.1` (gates the RunPod redeploy). | 5 |

`is_noise_topic` is intentionally duplicated from `cluster-worker/cluster_job.py`; the **assertion table is shared verbatim** so drift fails a test.

---

## Task 1: Multilingual stop-word data module

**Files:**
- Create: `embed-worker/stopwords.py`
- Test: `embed-worker/test_stopwords.py`

- [ ] **Step 1: Write the failing test**

Create `embed-worker/test_stopwords.py`:

```python
from stopwords import STOPWORDS


def test_is_frozenset_of_lowercase_str():
    assert isinstance(STOPWORDS, frozenset)
    assert STOPWORDS
    assert all(isinstance(w, str) and w == w.lower() for w in STOPWORDS)


def test_contains_representative_function_words():
    # English, Russian, Dutch function words must be present
    for w in ["the", "and", "is", "это", "было", "не",
              "de", "het", "een", "moet", "ik"]:
        assert w in STOPWORDS, f"missing stopword: {w!r}"


def test_excludes_real_topic_words():
    # Words that are legitimate standalone topics must NOT be stopped
    for w in ["war", "экономика", "oorlog", "ukraine", "covid",
              "украина", "rusland", "история"]:
        assert w not in STOPWORDS, f"topic word wrongly in STOPWORDS: {w!r}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd embed-worker && python -m pytest test_stopwords.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'stopwords'`

- [ ] **Step 3: Write minimal implementation**

Create `embed-worker/stopwords.py`:

```python
"""Static multilingual stop-word set for KeyBERT topic extraction.

Conservative: function words / pronouns / prepositions / conjunctions /
auxiliaries only — never words that could be a standalone topic. Vendored
(no NLTK dependency). Tunable later; goal is removing dominant filler, not
perfection. Used by handler.extract_topics via CountVectorizer(stop_words=...).
"""

# NOTE: only tokens >=2 chars — sklearn's default token_pattern (\b\w\w+\b)
# never tokenizes single-char words, so listing them is a dead no-op AND
# triggers a "stop_words inconsistent" UserWarning. Keep this invariant.
_EN = """
the an and or but if of at by for with about against between into through
during before after to from up down in out on off over under is are was were
be been being have has had do does did this that these those it its as so than
then too very can will just not no you he she we they my your our their me
him her us them what which who how when where why all any both each more most
other some such only own same here there
""".split()

_RU = """
во не что он на со как то все она так его но да ты же вы за бы по
только её мне было вот от меня ещё нет из ему теперь был до вас уже или ни
быть него опять уж вам ведь там потом себя ничего ей они тут где есть надо ней
для мы тебя их чем была сам чтоб без чего раз тоже себе под будет тогда кто
этот того потому этого какой ним здесь этом один мой тем чтобы неё сейчас были
куда зачем всех можно при два об другой после над больше тот через эти нас про
всего них эту моя свою этой перед том такой им более всю между это
""".split()

_NL = """
de het een en van te dat die in is op aan met als voor had er maar om hem dan
zou of wat mijn men dit zo door over ze zich bij ook tot je mij uit der daar
haar naar heb hoe heeft hebben deze want nog zal me zij nu geen omdat iets
worden toch al waren veel meer doen toen moet ben zonder kan hun dus alles
onder ja eens hier wie werd altijd wordt kunnen ons zelf tegen na wil kon niets
uw iemand andere ik
""".split()

STOPWORDS: frozenset[str] = frozenset(_EN + _RU + _NL)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd embed-worker && python -m pytest test_stopwords.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add embed-worker/stopwords.py embed-worker/test_stopwords.py
git commit -m "feat: multilingual (en+ru+nl) stop-word set for embed-worker"
```

---

## Task 2: `is_noise_topic` guard (mirrors cluster-worker)

**Files:**
- Create: `embed-worker/topic_clean.py`
- Test: `embed-worker/test_topic_clean.py`

- [ ] **Step 1: Write the failing test**

Create `embed-worker/test_topic_clean.py` (the two assertion lists are
**verbatim** from `cluster-worker/test_cluster_job.py` — keep them identical):

```python
from topic_clean import is_noise_topic


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

Run: `cd embed-worker && python -m pytest test_topic_clean.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'topic_clean'`

- [ ] **Step 3: Write minimal implementation**

Create `embed-worker/topic_clean.py` (the `is_noise_topic` body is
byte-for-byte identical to `cluster-worker/cluster_job.py`):

```python
"""Pure topic-hygiene helpers for embed-worker KeyBERT extraction.

Dependency-free (only `re`) so it is unit-testable without torch/keybert.
`is_noise_topic` is intentionally identical to cluster-worker's copy and the
Task 9 SQL regex — the shared test assertion table guards against drift.
"""
import re

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd embed-worker && python -m pytest test_topic_clean.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add embed-worker/topic_clean.py embed-worker/test_topic_clean.py
git commit -m "feat: is_noise_topic guard for embed-worker (mirrors cluster-worker)"
```

---

## Task 3: `clean_topic_input` timestamp/date preprocessor

**Files:**
- Modify: `embed-worker/topic_clean.py`
- Modify: `embed-worker/test_topic_clean.py`

- [ ] **Step 1: Write the failing test**

First change the Task-2 top import line of `embed-worker/test_topic_clean.py`
from `from topic_clean import is_noise_topic` to:

```python
from topic_clean import is_noise_topic, clean_topic_input
```

Then append the 5 new test functions to the END of the file (no separate
mid-file import — it is consolidated at the top per Task 3 code review):

```python
def test_strips_leading_chapter_timestamps_keeps_labels():
    src = "00:00 — Introduction\n1:23:45 — Future of gaming\n12:30 - Blizzard"
    assert clean_topic_input(src) == "Introduction\nFuture of gaming\nBlizzard"


def test_blanks_inline_time_and_date_strings():
    out = clean_topic_input("recorded 10:15:30 on 17.05.2026 about gaming")
    assert "10:15:30" not in out and "17.05.2026" not in out
    assert "recorded" in out and "gaming" in out


def test_preserves_number_bearing_real_topics():
    src = "9 мая is Victory Day\nnotes on covid 19 and gpt 4"
    out = clean_topic_input(src)
    assert "9 мая" in out and "covid 19" in out and "gpt 4" in out


def test_safe_on_empty_and_none():
    assert clean_topic_input("") == ""
    assert clean_topic_input(None) == ""
    assert clean_topic_input("   ") == ""


def test_non_timestamp_numeric_lines_survive():
    # "1." is not MM:SS — must NOT be treated as a timestamp prefix
    assert clean_topic_input("1. First real topic") == "1. First real topic"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd embed-worker && python -m pytest test_topic_clean.py -v`
Expected: FAIL — `ImportError: cannot import name 'clean_topic_input'`

- [ ] **Step 3: Write minimal implementation**

Append to `embed-worker/topic_clean.py`:

```python
# Leading chapter-timestamp prefix: "00:00 — ", "1:23:45 - ", "12:30) "
_TS_PREFIX = re.compile(r"^\s*\d{1,2}:\d{2}(?::\d{2})?\s*[—–\-:.)\]]*\s*")
# Standalone time token anywhere: "10:15", "1:23:45"
_TIME_TOKEN = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\b")
# Explicit date string: 17.05.2026 / 2026-05-17 / 05/17/2026.
# NOTE: also strips 3-part version numbers (1.2.3, 17.4.1) — accepted
# best-effort trade-off; the adjacent topic word survives and is_noise_topic
# is the downstream backstop (spec: dominant timestamp case only).
_DATE = re.compile(r"\b\d{1,4}[./-]\d{1,2}[./-]\d{1,4}\b")
# Collapse runs of spaces/tabs left by the substitutions above.
_WS = re.compile(r"[ \t]{2,}")


def clean_topic_input(text: str | None) -> str:
    """Strip timestamps/dates from the KeyBERT-only input text.

    Removes leading chapter-timestamp prefixes per line (keeping the chapter
    label), and blanks inline time tokens / explicit date strings. Leaves all
    words and number-bearing words intact ('covid 19', '9 мая', 'gpt 4').
    Total function: empty/None/whitespace -> "".
    """
    if not text or not text.strip():
        return ""
    out_lines = []
    for line in text.split("\n"):
        line = _TS_PREFIX.sub("", line, count=1)
        line = _TIME_TOKEN.sub(" ", line)
        line = _DATE.sub(" ", line)
        line = _WS.sub(" ", line).strip()
        if line:
            out_lines.append(line)
    return "\n".join(out_lines)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd embed-worker && python -m pytest test_topic_clean.py -v`
Expected: PASS (7 passed — 2 from Task 2 + 5 new)

- [ ] **Step 5: Commit**

```bash
git add embed-worker/topic_clean.py embed-worker/test_topic_clean.py
git commit -m "feat: clean_topic_input timestamp/date preprocessor"
```

---

## Task 4: Rewrite `extract_topics` + requirements

**Files:**
- Modify: `embed-worker/handler.py`
- Modify: `embed-worker/requirements.txt`
- Modify: `embed-worker/test_topic_clean.py` (add a guarded integration test)

- [ ] **Step 1: Pin scikit-learn explicitly**

`extract_topics` now imports `CountVectorizer` directly (was only transitive
via keybert). Append to `embed-worker/requirements.txt`:

```
scikit-learn==1.5.1
```

(Full file becomes: `runpod==1.6.2`, `sentence-transformers==3.0.1`,
`torch>=2.6.0`, `requests==2.32.3`, `keybert==0.8.5`, `scikit-learn==1.5.1`.)

- [ ] **Step 1b: Ship the new modules in the image (CRITICAL)**

`handler.py` will now `import` `topic_clean` and `stopwords`. The Dockerfile
only copies `handler.py`/`VERSION`, so without this the RunPod worker crashes
with `ModuleNotFoundError` on every job. In `embed-worker/Dockerfile`, change:

```dockerfile
COPY handler.py .
COPY VERSION .
```
to:
```dockerfile
COPY stopwords.py .
COPY topic_clean.py .
COPY handler.py .
COPY VERSION .
```
(Nothing else in the Dockerfile changes.)

- [ ] **Step 2: Write the failing guarded integration test**

Append to `embed-worker/test_topic_clean.py`:

```python
import os
import pytest


@pytest.mark.skipif(
    os.environ.get("RUN_MODEL_TESTS") != "1",
    reason="set RUN_MODEL_TESTS=1 to run the heavy KeyBERT/BGE-M3 test",
)
def test_extract_topics_drops_noise_keeps_real():
    from handler import extract_topics  # heavy import (torch/keybert)
    text = (
        "#493 Jeff Kaplan: World of Warcraft\n"
        "00:00 — Introduction\n"
        "03:12 — Early career at Blizzard\n"
        "1:23:45 — Future of gaming and esports\n"
        "26:30 — World of Warcraft design\n"
        "это было обсуждение про экономику\n"
    )
    topics = extract_topics(text, top_n=10)
    assert len(topics) <= 10
    from topic_clean import is_noise_topic
    assert not any(is_noise_topic(t) for t in topics), topics
    # leading timestamps must not produce numeric tags
    assert not any(t.strip() in {"00", "00 00", "03", "493", "2026"} for t in topics), topics
    blob = " ".join(topics).lower()
    assert "blizzard" in blob or "warcraft" in blob or "gaming" in blob, topics
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd embed-worker && python -m pytest test_topic_clean.py -v` (the guarded
test is skipped without `RUN_MODEL_TESTS`; the existing 7 still pass). Then to
prove the new behavior is not yet present, run with the flag in the dev venv:
`cd embed-worker && RUN_MODEL_TESTS=1 python -m pytest test_topic_clean.py -k extract_topics -v`
Expected: FAIL — current `handler.extract_topics` has no input cleaning /
multilingual stop-words, so numeric/`это было` noise appears (or import error
because `topic_clean`/`stopwords` not yet wired into handler).

- [ ] **Step 4: Rewrite `extract_topics` in `handler.py`**

In `embed-worker/handler.py`, add imports near the top (after the existing
`from keybert import KeyBERT`):

```python
from sklearn.feature_extraction.text import CountVectorizer
from topic_clean import clean_topic_input, is_noise_topic
from stopwords import STOPWORDS

_STOPWORDS_LIST = sorted(STOPWORDS)
```

Replace the entire existing `extract_topics` function with:

```python
def extract_topics(text: str, top_n: int = 10) -> list[str]:
    """Extract diverse keyphrases via KeyBERT + MMR, source-cleaned.

    Pipeline: strip timestamps/dates -> KeyBERT with a multilingual-stopword
    CountVectorizer (over-fetch) -> drop entirely-numeric/date keyphrases ->
    de-dupe (case-insensitive) -> first `top_n`.
    """
    cleaned = clean_topic_input(text)
    if not cleaned:
        return []
    km = get_kw_model()
    # Custom vectorizer: ngram_range MUST be set here (KeyBERT ignores
    # keyphrase_ngram_range when a vectorizer is passed). No custom
    # token_pattern — keep sklearn default so 'covid 19'/'gpt 4' n-grams form;
    # entirely-numeric phrases are rejected at the keyphrase level below.
    vectorizer = CountVectorizer(ngram_range=(1, 2), stop_words=_STOPWORDS_LIST)
    keywords = km.extract_keywords(
        cleaned,
        vectorizer=vectorizer,
        top_n=15,            # over-fetch; trimmed to top_n after filtering
        use_mmr=True,
        diversity=0.3,
    )
    out: list[str] = []
    seen: set[str] = set()
    for kw, _score in keywords:
        if is_noise_topic(kw):
            continue
        key = kw.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(kw)
        if len(out) >= top_n:
            break
    return out
```

(Leave `get_model`, `get_kw_model`, `embed_episode`, `handler`, and the
`runpod.serverless.start` line unchanged. `embed_episode` still uses the raw
`episode["text"]` — the vector path is untouched.)

- [ ] **Step 5: Syntax check + run tests**

Run:
```bash
cd embed-worker && python -c "import ast; ast.parse(open('handler.py').read()); print('syntax OK')"
python -m pytest test_topic_clean.py test_stopwords.py -v
```
Expected: `syntax OK`; 10 passed (7 topic_clean + 3 stopwords; the guarded
model test skipped).

Then the guarded behavior test in the dev venv (venv must have
`keybert sentence-transformers torch scikit-learn`):
```bash
cd embed-worker && RUN_MODEL_TESTS=1 python -m pytest test_topic_clean.py -k extract_topics -v
```
Expected: PASS — no noise topics, real topics (blizzard/warcraft/gaming)
present. If the local box cannot host torch/BGE-M3, report DONE_WITH_CONCERNS:
the pure tests (10) MUST pass; the guarded test is then validated post-deploy
via the spot-check (Task 6 Step 5).

- [ ] **Step 6: Commit**

```bash
git add embed-worker/handler.py embed-worker/Dockerfile embed-worker/requirements.txt embed-worker/test_topic_clean.py
git commit -m "feat: source-clean KeyBERT extraction (timestamps/dates + multilingual stopwords)"
```

---

## Task 5: Version bump (gates RunPod redeploy)

**Files:**
- Modify: `embed-worker/VERSION`

- [ ] **Step 1: Bump the version**

Set `embed-worker/VERSION` contents to exactly:

```
2.1
```

- [ ] **Step 2: Verify**

Run: `cat embed-worker/VERSION`
Expected: `2.1`

- [ ] **Step 3: Commit**

```bash
git add embed-worker/VERSION
git commit -m "chore: bump embed-worker to 2.1 (source noise fix)"
```

---

## Task 6: Operator deploy + backfill sequence (USER-RUN)

**Files:** none (operational). **Do NOT auto-run** — this mutates the live
RunPod endpoint and the production DB. Hand these steps to the user; they
match the spec's mandatory deploy ordering (`project-embedding-stack` memory:
image-tag updates do not override per-endpoint env vars and warm workers do
not auto-reload).

- [ ] **Step 1: Build + push the image**

```bash
./embed-worker/build.sh
```
Expected: ends `Pushed watchcat/embed-worker:2.1`.

- [ ] **Step 2: Point the RunPod endpoint at 2.1 + de-risk the gotcha**

In the RunPod console for the embed endpoint:
- set the image to `watchcat/embed-worker:2.1`
- **verify Environment Variables: `MODEL_NAME` is `BAAI/bge-m3` or unset**
  (a stale `MODEL_NAME` silently runs the wrong model — the documented trap)
- **scale workers to 0**, then back up, to force a cold reload of 2.1
  (warm workers keep the old image otherwise)

- [ ] **Step 3: Spot-check clean extraction on one normal run**

Trigger one hourly-style embed pass (or wait for the cron), then:
```bash
KC="kubectl --kubeconfig k8s/kubeconfig -n buzz-bot"
DBURL=$($KC get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
nix-shell --packages postgresql --run "psql \"$DBURL\" -c \"
  SELECT unnest(topics) tp, count(*) FROM episode_embeddings
  WHERE updated_at > now() - interval '20 min'
  GROUP BY 1 ORDER BY 2 DESC LIMIT 30;\""
```
Expected: freshly-updated rows show no pure-numeric/date topics and no obvious
`moet ik`/`это было`-class filler. If noise persists → the new image is not
live (recheck Step 2: MODEL_NAME / worker reload) before backfilling.

- [ ] **Step 4: Trigger the full re-extract backfill (one-off)**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -c \"
  UPDATE episode_embeddings SET source = 'description';\""
```
This routes every row through the existing `stale_source_episode_ids` cron
path; the hourly embed cron drains ~100/run, re-embedding each with 2.1 and
resetting `source='title'`. ~17k / 100 per hour ≈ 7 days, self-terminating.

- [ ] **Step 5: Monitor the drain**

Periodically:
```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -c \"
  SELECT count(*) FILTER (WHERE source='description') AS remaining,
         count(*) FILTER (WHERE source='title')       AS done
  FROM episode_embeddings;\""
```
`remaining` should fall toward 0 over ~7 days. (Re-using `k8s/embed-progress.sh`
is fine for the embed-progress angle.)

- [ ] **Step 6: Rebuild clusters from clean data**

Once `remaining` is ~0, run the nightly cluster job once manually:
```bash
$KC create job --from=cronjob/cluster-trigger cluster-postclean-1
$KC logs -f job/cluster-postclean-1     # expect: clustered N topics into M clusters
$KC delete job cluster-postclean-1
```

- [ ] **Step 7: Verify success criteria**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -c \"
  SELECT label, count(*) FROM topic_clusters
  GROUP BY label HAVING count(*)>1 ORDER BY 2 DESC LIMIT 20;\" -c \"
  SELECT count(*) FROM topic_clusters
  WHERE label ~ '^[0-9 :./-]+\$';\""
```
Expected: top clusters are real topics (no `03`-class, no `moet ik`/`утро`
dominating); `0` pure-numeric labels. The downstream `is_noise_topic`/SQL
guards now match (near-)nothing on fresh data — confirm they're now
belt-and-suspenders, and leave them in place.

---

## Self-review notes (author)

- **Spec coverage:** Goals → Tasks 1–4 (clean source extraction); §Architecture
  components → Tasks 1 (`stopwords.py`), 2 (`is_noise_topic`), 3
  (`clean_topic_input`), 4 (`extract_topics` rewrite). §2 corrections honored:
  no `min_df`; default token pattern + keyphrase-level `is_noise_topic`
  (Task 4 Step 4 comment makes this explicit). §Backfill → Task 6 Step 4
  (`source='description'` flip). §Deploy ordering → Task 6 Steps 1–2 (VERSION
  via Task 5, push, endpoint image + MODEL_NAME + scale-0). §Testing → pure
  TDD Tasks 1–3 + guarded model test Task 4. §Success criteria → Task 6 Step 7.
- **Placeholders:** none — stop-word lists, regexes, and `extract_topics` are
  complete; `<...>` substitution tokens absent.
- **Type/name consistency:** `STOPWORDS` (frozenset) defined Task 1, consumed
  Task 4 as `sorted(STOPWORDS)` → `_STOPWORDS_LIST`. `is_noise_topic`/
  `clean_topic_input` signatures defined Tasks 2/3, imported in Task 4 exactly.
  `is_noise_topic` regexes byte-identical to `cluster-worker/cluster_job.py`;
  the assertion table is copied verbatim so divergence fails Task 2.
- **Structural deviation (documented):** pure logic in `topic_clean.py` not
  `handler.py` (testability) — interface/behavior unchanged.
```
