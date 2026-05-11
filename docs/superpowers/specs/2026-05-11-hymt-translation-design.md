# HY-MT Translation Integration Design

## Goal

Replace Gemini Flash with Tencent's HY-MT1.5-1.8B for podcast transcript translation in the dub-pipeline, eliminating API costs by running translation locally on the already-allocated RunPod GPU.

## Motivation

The RunPod GPU pod is allocated for the full dub job (separate, transcribe, synthesize, etc.). Translation via Gemini Flash is the only step that makes an external API call, adding cost per segment. HY-MT1.5 (1.8B params, ~2GB VRAM in float16) can run alongside the existing pipeline models with negligible resource impact, making translation effectively free.

## Architecture

Dual-backend dispatcher in `translate.py`. A config set determines which languages use HY-MT vs Gemini:

```
translate(segments, source_lang, target_lang)
    |
    +-- target_lang in HYMT_LANGUAGES?
    |     \-- _translate_hymt_batch() via HuggingFace transformers
    |
    \-- else
          \-- existing _translate_batch() via Gemini (unchanged)
```

### Language tiers

**Tier 1 — HY-MT (11 languages):** en, es, fr, de, it, pt, ru, zh, ja, ko, nl

**Tier 2 — Gemini fallback (4 languages):** pl, tr, cs, hu

Moving a language between tiers = editing the `HYMT_LANGUAGES` set. No code changes needed.

### Model loading

- Loaded lazily on first HY-MT translation call via `AutoModelForCausalLM.from_pretrained()` + `AutoTokenizer.from_pretrained()`
- Float16, CUDA
- Stays in GPU memory for all batches within the job
- Freed when the pod shuts down (RunPod scale-to-zero)
- Model weights cached on RunPod Network Volume via `HF_HOME=/runpod-volume/models/hf`

### Batching with context

Same structure as current Gemini path:
- Batch size: 20 segments per call
- Context window: previous 2 translated segments + next 1 source segment
- Same-language shortcut: if source == target, copy verbatim (before either backend)

## Prompt format

HY-MT uses `<source>`/`<target>` XML tags. The batch prompt:

```
Translate the following podcast transcript segments from English to Russian.
Maintain the speaker's tone and style. Translate only the TRANSLATE segments.

CONTEXT (already translated):
[1] Already translated segment one.
[2] Already translated segment two.

TRANSLATE:
[idx=42] [SPEAKER_00]: Source text of segment 42.
[idx=43] [SPEAKER_00]: Source text of segment 43.
[idx=44] [SPEAKER_01]: Source text of segment 44.

NEXT (for context only):
Source text of the next segment.

Output format: one translation per line, prefixed with idx.
[idx=42]: <target>translated text</target>
[idx=43]: <target>translated text</target>
[idx=44]: <target>translated text</target>
```

### Parsing

Extract text between `<target>` and `</target>` tags per line using regex, keyed by idx number. Returns `dict[int, str]` — same interface as the Gemini path.

### Retry logic

Same as current Gemini approach:
- If a segment is missing from batch output, retry it individually
- If individual retry also fails, fall back to source text with a warning log

## Files changed

All changes are in the `dub-pipeline/` repository.

| File | Change |
|------|--------|
| `src/steps/translate.py` | Add `HYMT_LANGUAGES` set, `_load_hymt_model()` lazy loader, `_translate_hymt_batch()`, routing in `translate()` |
| `src/config.py` | Add `HYMT_MODEL` env var (default: `Tencent-Hunyuan/HunyuanTranslate-1.8B`) |
| `requirements.txt` | Add `transformers`, `sentencepiece` |

## What does NOT change

- **buzz-bot (Crystal):** No changes. The callback format (`translated_text` per segment) is identical regardless of backend.
- **Database schema:** Unchanged. `dub_segment_translations` stores the same data.
- **Dockerfile:** Unchanged. `transformers` installs via pip. Model weights download to HF_HOME on first use.
- **Pipeline steps 1-4, 6-9:** Separate, transcribe, extract samples, split, synthesize, assemble, mix, upload — all untouched.
- **Progress reporting:** Step name stays `translating`, same SSE flow.
- **Same-language verbatim copy:** Stays as-is, before either backend is called.
- **Batch size (20) and context window (prev 2 + next 1):** Same for both backends.
- **GEMINI_API_KEY:** Still required in RunPod env vars for Tier 2 languages.

## Quality approach

Start with pure HY-MT output (no post-processing for spoken style). Evaluate quality on real dubs. Add post-processing later only if needed. The current Gemini prompt does idiom localization, register adaptation, and TTS formatting — HY-MT will produce more literal translations. This is an accepted trade-off for zero API cost.

## Rollback

If HY-MT quality is unacceptable for a language, move it from `HYMT_LANGUAGES` to Tier 2. No code change, just config. Full rollback = empty the set (everything goes to Gemini).
