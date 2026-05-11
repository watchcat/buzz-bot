# HY-MT Translation Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Gemini Flash with Tencent's HY-MT1.5-1.8B for translation on 11 languages, keeping Gemini as fallback for 4 others.

**Architecture:** Dual-backend dispatcher in `translate.py`. A config set routes Tier 1 languages (en, es, fr, de, it, pt, ru, zh, ja, ko, nl) to HY-MT via HuggingFace transformers; Tier 2 languages (pl, tr, cs, hu) continue using Gemini. Same batching (20 segments) and context windowing (prev 2 + next 1) for both backends.

**Tech Stack:** Python, HuggingFace transformers, sentencepiece, PyTorch (CUDA), existing Gemini SDK

**Repo:** All changes in `../dub-pipeline/` (relative to buzz-bot root)

---

### Task 1: Add dependencies and config

**Files:**
- Modify: `../dub-pipeline/requirements.txt`
- Modify: `../dub-pipeline/src/config.py`

- [ ] **Step 1: Add transformers and sentencepiece to requirements.txt**

Add these two lines to the end of `../dub-pipeline/requirements.txt`:

```
transformers>=4.40.0
sentencepiece>=0.2.0
```

- [ ] **Step 2: Add HYMT config to config.py**

Add these lines after the `GEMINI_MODEL` line (line 16) in `../dub-pipeline/src/config.py`:

```python
# HY-MT local translation model (Tier 1 languages)
HYMT_MODEL       = os.environ.get("HYMT_MODEL", "Tencent-Hunyuan/HunyuanTranslate-1.8B")
HYMT_LANGUAGES   = set(os.environ.get("HYMT_LANGUAGES", "en,es,fr,de,it,pt,ru,zh,ja,ko,nl").split(","))
```

- [ ] **Step 3: Commit**

```bash
cd ../dub-pipeline
git add requirements.txt src/config.py
git commit -m "feat: add HY-MT model config and dependencies"
```

---

### Task 2: Implement HY-MT model loader

**Files:**
- Modify: `../dub-pipeline/src/steps/translate.py`

This task adds the lazy model loader and the HY-MT batch translation function, without changing the existing Gemini code path yet.

- [ ] **Step 1: Add imports for transformers at the top of translate.py**

Add after the existing imports (after `from src import config` on line 15):

```python
import re
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
```

- [ ] **Step 2: Add the lazy model loader**

Add after the `_client = genai.Client(...)` line (line 19), before `_LANG_NAMES`:

```python
# ── HY-MT model (lazy-loaded on first use) ───────────────────────────────────

_hymt_model = None
_hymt_tokenizer = None


def _load_hymt():
    """Load HY-MT model and tokenizer once, keep in GPU memory."""
    global _hymt_model, _hymt_tokenizer
    if _hymt_model is not None:
        return _hymt_model, _hymt_tokenizer

    log.info(f"translate: loading HY-MT model {config.HYMT_MODEL}")
    _hymt_tokenizer = AutoTokenizer.from_pretrained(
        config.HYMT_MODEL, trust_remote_code=True,
    )
    _hymt_model = AutoModelForCausalLM.from_pretrained(
        config.HYMT_MODEL,
        torch_dtype=torch.float16,
        device_map="auto",
        trust_remote_code=True,
    )
    _hymt_model.eval()
    log.info("translate: HY-MT model loaded")
    return _hymt_model, _hymt_tokenizer
```

- [ ] **Step 3: Add the HY-MT prompt builder**

Add after the `_load_hymt` function:

```python
_HYMT_PROMPT_TEMPLATE = """\
Translate the following podcast transcript segments from {source_language} to {target_language}.
Maintain the speaker's tone and style. Translate only the TRANSLATE segments.

{context_block}TRANSLATE:
{translate_block}
Output format: one translation per line, prefixed with idx.
{format_block}"""


def _build_hymt_prompt(
    batch: list[dict],
    source_lang: str,
    target_lang: str,
    prev_ctx: list[dict],
    next_seg: dict | None,
) -> str:
    src_name = _LANG_NAMES.get(source_lang.lower(), source_lang)
    tgt_name = _LANG_NAMES.get(target_lang.lower(), target_lang)

    context_lines = []
    if prev_ctx:
        context_lines.append("CONTEXT (already translated):")
        for i, ctx in enumerate(prev_ctx, 1):
            context_lines.append(f"[{i}] {ctx['translated_text']}")
        context_lines.append("")
    context_block = "\n".join(context_lines) + "\n" if context_lines else ""

    translate_lines = []
    for seg in batch:
        speaker_tag = f" [{seg['speaker']}]" if seg.get("speaker") else ""
        translate_lines.append(f"[idx={seg['idx']}]{speaker_tag}: {seg['text']}")

    next_block = ""
    if next_seg:
        translate_lines.append("")
        translate_lines.append(f"NEXT (for context only):")
        translate_lines.append(next_seg["text"])

    format_lines = [f"[idx={seg['idx']}]: <target>translated text</target>" for seg in batch]

    return _HYMT_PROMPT_TEMPLATE.format(
        source_language=src_name,
        target_language=tgt_name,
        context_block=context_block,
        translate_block="\n".join(translate_lines),
        format_block="\n".join(format_lines),
    )
```

- [ ] **Step 4: Add the HY-MT batch translation function**

Add after `_build_hymt_prompt`:

```python
_HYMT_TARGET_RE = re.compile(r"\[idx=(\d+)\]:\s*<target>(.*?)</target>")


def _translate_hymt_batch(
    segments: list[dict],
    source_lang: str,
    target_lang: str,
    prev_ctx: list[dict],
    next_seg: dict | None,
) -> dict[int, str]:
    """Translate one batch using the local HY-MT model. Returns {idx: translated_text}."""
    model, tokenizer = _load_hymt()
    prompt = _build_hymt_prompt(segments, source_lang, target_lang, prev_ctx, next_seg)

    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=2048,
            temperature=0.2,
            do_sample=True,
            top_p=0.9,
        )

    # Decode only the generated tokens (skip the prompt)
    generated = outputs[0][inputs["input_ids"].shape[1]:]
    response = tokenizer.decode(generated, skip_special_tokens=True).strip()

    out: dict[int, str] = {}
    for match in _HYMT_TARGET_RE.finditer(response):
        idx = int(match.group(1))
        text = match.group(2).strip()
        if text:
            out[idx] = text

    if not out:
        # Fallback: if no <target> tags found, try to parse as plain text lines
        # This handles cases where the model doesn't follow the exact format
        log.warning("translate: HY-MT response had no <target> tags, attempting line parse")
        lines = response.strip().splitlines()
        idx_re = re.compile(r"\[idx=(\d+)\]:\s*(.*)")
        for line in lines:
            m = idx_re.match(line.strip())
            if m:
                idx = int(m.group(1))
                text = m.group(2).strip()
                if text:
                    out[idx] = text

    return out
```

- [ ] **Step 5: Commit**

```bash
cd ../dub-pipeline
git add src/steps/translate.py
git commit -m "feat: add HY-MT model loader and batch translation function"
```

---

### Task 3: Wire up the dual-backend dispatcher

**Files:**
- Modify: `../dub-pipeline/src/steps/translate.py`

This task modifies the existing `translate()` function to route Tier 1 languages to HY-MT and keeps Tier 2 on Gemini.

- [ ] **Step 1: Replace the translate() function**

Replace the existing `translate()` function (lines 142-230) with this version that dispatches to the appropriate backend:

```python
def translate(segments: list[dict], source_lang: str, target_lang: str) -> list[dict]:
    """
    Translate all segments from source_lang to target_lang.
    Tier 1 languages use local HY-MT model; Tier 2 uses Gemini Flash.
    Same-language jobs copy text verbatim.
    """
    if source_lang.lower() == target_lang.lower():
        log.info(f"translate: source == target ({source_lang}), copying text verbatim")
        return [{**seg, "translated_text": seg["text"]} for seg in segments]

    use_hymt = target_lang.lower() in config.HYMT_LANGUAGES
    src_name = _LANG_NAMES.get(source_lang.lower(), source_lang)
    tgt_name = _LANG_NAMES.get(target_lang.lower(), target_lang)
    backend = "HY-MT" if use_hymt else "Gemini"
    log.info(f"translate: {len(segments)} segments, {src_name} → {tgt_name} via {backend}")

    if not use_hymt:
        # Gemini path — existing logic, unchanged
        return _translate_gemini(segments, source_lang, target_lang)

    # HY-MT path
    input_segs = [
        {
            "idx":     seg.get("idx", i),
            "text":    seg.get("text", "").strip(),
            "speaker": seg.get("speaker", ""),
        }
        for i, seg in enumerate(segments)
    ]

    translations: dict[int, str] = {}
    recent_translated: list[dict] = []

    for batch_start in range(0, len(input_segs), _BATCH_SIZE):
        batch = input_segs[batch_start : batch_start + _BATCH_SIZE]
        prev_ctx = recent_translated[-2:]
        next_idx = batch_start + len(batch)
        next_seg = input_segs[next_idx] if next_idx < len(input_segs) else None

        log.info(
            f"translate: HY-MT batch {batch_start // _BATCH_SIZE + 1}, "
            f"segs {batch_start}–{batch_start + len(batch) - 1}"
        )
        batch_result = _translate_hymt_batch(batch, source_lang, target_lang, prev_ctx, next_seg)

        # Drop spurious idx values outside this batch
        batch_idx_set = {s["idx"] for s in batch}
        spurious = [idx for idx in batch_result if idx not in batch_idx_set]
        if spurious:
            log.warning(f"translate: dropping spurious idx values: {spurious}")
            for idx in spurious:
                del batch_result[idx]

        # Retry missing segments individually
        incomplete = [s for s in batch if not batch_result.get(s["idx"])]
        if incomplete:
            log.warning(
                f"translate: {len(incomplete)}/{len(batch)} segments missing "
                f"— retrying individually"
            )
            for seg in incomplete:
                retry_result = _translate_hymt_batch([seg], source_lang, target_lang, prev_ctx, next_seg=None)
                if retry_result.get(seg["idx"]):
                    batch_result[seg["idx"]] = retry_result[seg["idx"]]
                else:
                    log.error(f"translate: seg {seg['idx']} still empty after retry — using source text")
                    batch_result[seg["idx"]] = seg["text"]

        translations.update(batch_result)
        for seg in batch:
            recent_translated.append({
                "text":            seg["text"],
                "translated_text": batch_result.get(seg["idx"], ""),
            })

    out = []
    for i, seg in enumerate(segments):
        idx = seg.get("idx", i)
        translated = translations.get(idx) or ""
        out.append({**seg, "translated_text": translated})

    log.info("translate: done")
    if out:
        log.info(
            f"translate: sample — '{out[0].get('text','')[:60]}' "
            f"→ '{out[0].get('translated_text','')[:60]}'"
        )
    return out
```

- [ ] **Step 2: Rename old translate() to _translate_gemini()**

The old `translate()` function body (the Gemini-specific logic after the same-language check) needs to be preserved as `_translate_gemini()`. Take lines 152-230 from the *original* `translate()` (everything after the same-language early return) and wrap them in a new function:

```python
def _translate_gemini(segments: list[dict], source_lang: str, target_lang: str) -> list[dict]:
    """Gemini Flash translation path — used for Tier 2 languages."""
    src_name = _LANG_NAMES.get(source_lang.lower(), source_lang)
    tgt_name = _LANG_NAMES.get(target_lang.lower(), target_lang)

    system_prompt = (
        _SYSTEM_PROMPT_TEMPLATE
        .replace("{source_language}", src_name)
        .replace("{target_language}", tgt_name)
        .replace("{batch_size}", str(_BATCH_SIZE))
    )

    input_segs = [
        {
            "idx":     seg.get("idx", i),
            "text":    seg.get("text", "").strip(),
            "speaker": seg.get("speaker", ""),
        }
        for i, seg in enumerate(segments)
    ]

    translations: dict[int, str] = {}
    recent_translated: list[dict] = []

    for batch_start in range(0, len(input_segs), _BATCH_SIZE):
        batch = input_segs[batch_start : batch_start + _BATCH_SIZE]
        prev_ctx  = recent_translated[-2:]
        next_idx  = batch_start + len(batch)
        next_seg  = input_segs[next_idx] if next_idx < len(input_segs) else None

        log.info(
            f"translate: Gemini batch {batch_start // _BATCH_SIZE + 1}, "
            f"segs {batch_start}–{batch_start + len(batch) - 1}"
        )
        batch_result = _translate_batch(batch, system_prompt, prev_ctx, next_seg)

        batch_idx_set = {s["idx"] for s in batch}
        spurious = [idx for idx in batch_result if idx not in batch_idx_set]
        if spurious:
            log.warning(f"translate: dropping spurious idx values from Gemini response: {spurious}")
            for idx in spurious:
                del batch_result[idx]

        incomplete = [s for s in batch if not batch_result.get(s["idx"])]
        if incomplete:
            log.warning(
                f"translate: {len(incomplete)}/{len(batch)} segments missing or empty "
                f"— retrying individually"
            )
            for seg in incomplete:
                retry_result = _translate_batch([seg], system_prompt, prev_ctx, next_seg=None)
                if retry_result.get(seg["idx"]):
                    batch_result[seg["idx"]] = retry_result[seg["idx"]]
                else:
                    log.error(f"translate: seg {seg['idx']} still empty after retry — using source text")
                    batch_result[seg["idx"]] = seg["text"]

        translations.update(batch_result)
        for seg in batch:
            recent_translated.append({
                "text":            seg["text"],
                "translated_text": batch_result.get(seg["idx"], ""),
            })

    out = []
    for i, seg in enumerate(segments):
        idx = seg.get("idx", i)
        translated = translations.get(idx) or ""
        out.append({**seg, "translated_text": translated})

    log.info("translate: done")
    if out:
        log.info(
            f"translate: sample — '{out[0].get('text','')[:60]}' "
            f"→ '{out[0].get('translated_text','')[:60]}'"
        )
    return out
```

- [ ] **Step 3: Commit**

```bash
cd ../dub-pipeline
git add src/steps/translate.py
git commit -m "feat: wire dual-backend dispatcher — HY-MT for Tier 1, Gemini for Tier 2"
```

---

### Task 4: Add unit tests for prompt building and response parsing

**Files:**
- Create: `../dub-pipeline/tests/test_translate.py`

- [ ] **Step 1: Create the test file**

```python
"""Unit tests for HY-MT prompt building and response parsing."""
import re
from unittest.mock import patch, MagicMock

# Patch config before importing translate
import sys
import os
os.environ.setdefault("PROGRESS_URL", "http://test")
os.environ.setdefault("R2_ENDPOINT", "http://test")
os.environ.setdefault("R2_ACCESS_KEY_ID", "test")
os.environ.setdefault("R2_SECRET_ACCESS_KEY", "test")
os.environ.setdefault("R2_BUCKET", "test")
os.environ.setdefault("R2_PUBLIC_URL", "http://test")
os.environ.setdefault("GEMINI_API_KEY", "test")
os.environ.setdefault("HF_TOKEN", "test")

from src.steps.translate import (
    _build_hymt_prompt,
    _HYMT_TARGET_RE,
)


class TestBuildHymtPrompt:
    def test_basic_prompt_structure(self):
        batch = [
            {"idx": 0, "text": "Hello world", "speaker": "SPEAKER_00"},
            {"idx": 1, "text": "How are you", "speaker": "SPEAKER_01"},
        ]
        prompt = _build_hymt_prompt(batch, "en", "ru", prev_ctx=[], next_seg=None)

        assert "English" in prompt
        assert "Russian" in prompt
        assert "[idx=0] [SPEAKER_00]: Hello world" in prompt
        assert "[idx=1] [SPEAKER_01]: How are you" in prompt
        assert "TRANSLATE:" in prompt
        assert "<target>translated text</target>" in prompt

    def test_with_context(self):
        batch = [{"idx": 5, "text": "Third segment", "speaker": ""}]
        prev_ctx = [
            {"translated_text": "First translated"},
            {"translated_text": "Second translated"},
        ]
        next_seg = {"idx": 6, "text": "Fourth segment", "speaker": ""}

        prompt = _build_hymt_prompt(batch, "en", "es", prev_ctx, next_seg)

        assert "CONTEXT (already translated):" in prompt
        assert "[1] First translated" in prompt
        assert "[2] Second translated" in prompt
        assert "NEXT (for context only):" in prompt
        assert "Fourth segment" in prompt

    def test_no_context(self):
        batch = [{"idx": 0, "text": "First segment", "speaker": ""}]
        prompt = _build_hymt_prompt(batch, "en", "fr", prev_ctx=[], next_seg=None)

        assert "CONTEXT" not in prompt
        assert "NEXT" not in prompt

    def test_no_speaker(self):
        batch = [{"idx": 0, "text": "No speaker here", "speaker": ""}]
        prompt = _build_hymt_prompt(batch, "en", "de", prev_ctx=[], next_seg=None)

        assert "[idx=0]: No speaker here" in prompt
        assert "SPEAKER" not in prompt


class TestTargetRegex:
    def test_parses_target_tags(self):
        response = (
            "[idx=0]: <target>Привет мир</target>\n"
            "[idx=1]: <target>Как дела</target>\n"
        )
        matches = {int(m.group(1)): m.group(2).strip() for m in _HYMT_TARGET_RE.finditer(response)}
        assert matches == {0: "Привет мир", 1: "Как дела"}

    def test_handles_extra_whitespace(self):
        response = "[idx=42]:  <target>  Hola mundo  </target>\n"
        matches = {int(m.group(1)): m.group(2).strip() for m in _HYMT_TARGET_RE.finditer(response)}
        assert matches == {42: "Hola mundo"}

    def test_no_match_returns_empty(self):
        response = "Some random text without target tags"
        matches = {int(m.group(1)): m.group(2).strip() for m in _HYMT_TARGET_RE.finditer(response)}
        assert matches == {}
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
cd ../dub-pipeline
python -m pytest tests/test_translate.py -v
```

Expected: All 7 tests PASS.

- [ ] **Step 3: Commit**

```bash
cd ../dub-pipeline
git add tests/test_translate.py
git commit -m "test: add unit tests for HY-MT prompt building and response parsing"
```

---

### Task 5: Test locally and update docs

**Files:**
- Modify: `../dub-pipeline/README.md`

- [ ] **Step 1: Run a local test job with a Tier 1 language**

```bash
cd ../dub-pipeline
python test_job.py https://pub-f72ec72a74374596b8e0b595f480860e.r2.dev/tmp/audio/41.mp3 ru
```

Watch the logs for:
- `translate: loading HY-MT model Tencent-Hunyuan/HunyuanTranslate-1.8B` — model loads
- `translate: N segments, English → Russian via HY-MT` — correct routing
- `translate: HY-MT batch 1, segs 0–19` — batching works
- `translate: sample — '...' → '...'` — translations are non-empty

If any segments fail, check the logs for retry messages. If all segments fall back to source text, the model may not be following the prompt format — check the raw response by temporarily adding `log.debug(f"HY-MT raw response: {response}")` in `_translate_hymt_batch`.

- [ ] **Step 2: Run a local test job with a Tier 2 language**

```bash
cd ../dub-pipeline
python test_job.py https://pub-f72ec72a74374596b8e0b595f480860e.r2.dev/tmp/audio/41.mp3 hu
```

Watch for: `translate: N segments, English → Hungarian via Gemini` — confirms Tier 2 routing to Gemini.

- [ ] **Step 3: Update README.md**

Add a section about translation backends to `../dub-pipeline/README.md`. Find the existing environment variables section and add:

```markdown
### Translation backends

The pipeline uses two translation backends:

| Backend | Languages | Config |
|---------|-----------|--------|
| **HY-MT 1.5** (local, GPU) | en, es, fr, de, it, pt, ru, zh, ja, ko, nl | `HYMT_MODEL`, `HYMT_LANGUAGES` |
| **Gemini Flash** (API) | pl, tr, cs, hu | `GEMINI_API_KEY`, `GEMINI_MODEL` |

To move a language between tiers, edit `HYMT_LANGUAGES` (comma-separated list) in the RunPod endpoint environment. No code change needed.

The HY-MT model downloads to `HF_HOME` on first use and is cached on the Network Volume.
```

- [ ] **Step 4: Commit**

```bash
cd ../dub-pipeline
git add README.md
git commit -m "docs: add translation backend documentation"
```

---

### Task 6: Build and push Docker image

**Files:**
- No file changes — this is a deployment step

- [ ] **Step 1: Build the Docker image**

```bash
cd ../dub-pipeline
docker buildx build --platform linux/amd64 \
  -t watchcat/dub-pipeline:latest --push .
```

- [ ] **Step 2: Update RunPod endpoint environment**

In the RunPod dashboard, add these environment variables to the dub-pipeline endpoint (optional — defaults are fine for initial rollout):

```
HYMT_MODEL=Tencent-Hunyuan/HunyuanTranslate-1.8B
HYMT_LANGUAGES=en,es,fr,de,it,pt,ru,zh,ja,ko,nl
```

- [ ] **Step 3: Trigger a test dub from buzz-bot**

In the Telegram Mini App, pick an episode and dub it to Russian (Tier 1). Watch the RunPod logs for HY-MT loading and translation. Verify the dubbed audio plays correctly and subtitles show translated text.

- [ ] **Step 4: Trigger a Tier 2 test dub**

Dub an episode to Hungarian (Tier 2). Verify it routes to Gemini and completes normally.

- [ ] **Step 5: Commit any fixes**

If any issues were found during testing, fix them and commit:

```bash
cd ../dub-pipeline
git add -A
git commit -m "fix: address issues found during HY-MT integration testing"
```
