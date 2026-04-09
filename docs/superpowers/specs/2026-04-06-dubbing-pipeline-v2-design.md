# Dubbing Pipeline v2 — Design Spec

**Date:** 2026-04-06
**Status:** Draft
**Replaces:** `2026-03-24-episode-dubbing-design.md` + `2026-03-26-dubbing-microservices.md`

---

## Motivation

The v1 pipeline has three fundamental limitations:

1. **No source separation** — voice cloning samples contain background music, reducing clone quality.
2. **No speaker diarization** — multi-host podcasts get cloned from a single averaged voice.
3. **No timing** — the output TTS audio is generated as one blob, with no alignment to the original timeline. Long episodes overflow XTTS-v2's context window; pauses and pacing are lost.

The v2 redesign produces a professionally structured dub: clean voiced stems for each speaker, per-segment synthesis timed to match the original, and an optional background mix.

---

## Pipeline Overview

```
Audio URL
   │
   ▼
1. Separate (Demucs)
   │  vocals.wav  ──────────────────────────────────────────────────► 7. Mix
   │  background.wav ──────────────────────────────────────────────► 7. Mix
   ▼
2. Transcribe (WhisperX)
   │  segments: [{start, end, speaker_id, text}, ...]
   ▼
3. Extract speaker samples
   │  per speaker: best 15–30 s clip from vocals stem
   ▼
4. Translate (DeepL batch)
   │  segments: [{..., translated_text}, ...]
   ▼
5. Synthesize (XTTS-v2 per segment)
   │  per segment: synthesized audio clip (speaker voice clone)
   ▼
6. Assemble
   │  place clips on timeline; compress overlaps; fill gaps with silence
   │  dubbed_vocals.wav
   ▼
7. Mix
      dubbed_vocals.wav + background.wav (at reduced volume)
      → final_dub.mp3  → R2
```

All ML steps (1–7) run on the **Mac Mini** (Apple M4, 32 GB RAM) in a Python pipeline service. Crystal buzz-bot only enqueues jobs and receives the final callback.

---

## Components

### A. Crystal side (buzz-bot)

No new services. The existing 3-service choreography (`dub-transcriber`, `dub-translator`, `dub-synthesizer`) is **replaced** by:

- A single Redis RPUSH to `dub:jobs` with a structured job payload.
- A single HTTP callback endpoint `/internal/dub_result` that receives the finished result.
- PostgreSQL NOTIFY on `dub_status` for SSE fan-out (unchanged interface).

The `dub-translator` service is retired. Translation moves into the Python pipeline, which calls DeepL directly per-segment.

The `dub-transcriber` service is retired. The transcription + diarization moves into the Python pipeline (WhisperX).

The `dub-synthesizer` service is retired. Synthesis, assembly, and mixing all move into the Python pipeline.

### B. Python dub-pipeline service (Mac Mini)

New service: `dub-pipeline/`. Runs as a local process (not containerised). Single BRPOP loop; processes one job at a time (GPU memory constraint).

**Dependencies:**

| Library | Purpose |
|---|---|
| `demucs` | Source separation (vocals + background) |
| `whisperx` | Transcription with word-level alignment + speaker diarization |
| `pyannote.audio` | Speaker diarization backend for WhisperX |
| `TTS` (Coqui) | Local XTTS-v2 inference (no Replicate) |
| `pydub` / `ffmpeg` | Audio assembly and mixing |
| `redis` | Job queue |
| `boto3` | R2 upload (S3-compatible) |
| `deepl` | Translation (same API key as Crystal) |

**HuggingFace token required** for `pyannote.audio` diarization models (one-time accept of model license).

---

## Detailed Step Specification

### Step 1 — Separate (Demucs)

- Model: `htdemucs_ft` (fine-tuned, highest quality 4-stem model)
- Input: episode audio URL (downloaded to temp file)
- Output: `vocals.wav` (16 kHz mono), `background.wav` (full mix minus vocals, 44.1 kHz stereo)
- `background.wav` = `other + drums + bass` stems mixed
- Both stems uploaded to R2 under `dub-stems/{episode_id}/vocals.wav` and `.../background.wav`
- Stems are **episode-level** (language-independent) — reused for all languages

**Reuse logic:** if `dub_stems` row already exists for the episode, skip Demucs entirely.

### Step 2 — Transcribe (WhisperX)

- Model: `large-v3` (already downloaded)
- Input: `vocals.wav` (clean voice, no music — better WER)
- Output: word-aligned segments with speaker IDs
- Diarization: `pyannote/speaker-diarization-3.1` — returns `SPEAKER_00`, `SPEAKER_01`, etc.
- Segment format:
  ```json
  {
    "idx": 0,
    "start": 12.4,
    "end": 18.7,
    "speaker": "SPEAKER_00",
    "text": "Welcome to the show.",
    "words": [{"word": "Welcome", "start": 12.4, "end": 12.8, "score": 0.98}, ...]
  }
  ```
- Segments stored in `dub_segments` table (episode-level, reused across languages)
- Original language detected by WhisperX and stored on `episodes.original_language`

**Reuse logic:** if `dub_segments` rows already exist for the episode, skip WhisperX.

### Step 3 — Extract Speaker Samples

- For each unique `speaker_id`, find the longest contiguous segment(s) totalling 15–30 s
- Clips extracted from `vocals.wav` (clean, no background) using ffmpeg
- Uploaded to R2: `dub-stems/{episode_id}/speaker_{id}.wav`
- Stored in `dubbed_episodes.speaker_samples` JSONB: `{"SPEAKER_00": "r2_key", ...}`

**Quality heuristic:** prefer segments with high WhisperX word confidence scores to avoid hesitations and crosstalk.

### Step 4 — Translate (DeepL)

- Input: all segment `text` values for the episode
- DeepL batch call: send all texts in one request (array form)
- Context: send preceding + following segment text as `context` parameter where supported
- Output: `translated_text` per segment, stored in `dub_segment_translations`
- If source language == target language: copy `text` → `translated_text`, skip DeepL

**Segment-level translation** preserves natural sentence boundaries and avoids the "one giant blob" problem. DeepL's array API keeps cost identical to a single call.

### Step 5 — Synthesize (XTTS-v2, per segment)

- Model: Coqui XTTS-v2 running locally on Mac Mini (no Replicate)
- Per segment: generate TTS audio using speaker's voice clone
- Speaker sample used: `speaker_{id}.wav` from R2 (downloaded once per speaker per job)
- Language: target dub language
- Output: `seg_{idx}.wav` for each segment
- Segments synthesised sequentially (GPU memory); parallelism not needed on M4

**Duration note:** synthesised segment duration will differ from original. The assembler handles this.

### Step 6 — Assemble

Timeline assembly algorithm:

```
For each segment in order:
  original_gap = segment.start - prev_segment.end   # silence in original
  place_at = cursor                                  # current write head

  if synthesised_duration > original_duration:
    # Segment ran long — compress gap or overlap with next
    compression = min(original_gap, synthesised_duration - original_duration)
    place_at = cursor
    cursor += synthesised_duration - compression

  else:
    # Segment ran short — insert proportional silence
    silence = original_gap * 0.5   # preserve some pacing
    place_at = cursor
    cursor += synthesised_duration + silence

  write seg_N.wav at place_at on timeline
```

Simple rule: **never let segments overlap** and **never exceed 110% of original total duration**.

Output: `dubbed_vocals.wav` — silence-padded WAV at 24 kHz mono.

### Step 7 — Mix

```
ffmpeg -i dubbed_vocals.wav -i background.wav \
  -filter_complex "[1:a]volume=0.15[bg]; [0:a][bg]amix=inputs=2:duration=first" \
  -c:a libmp3lame -b:a 128k final_dub.mp3
```

- Background at 15% volume (configurable via `DUB_BG_VOLUME` env var, default `0.15`)
- Output duration = `dubbed_vocals.wav` duration (background truncated or padded)
- Mixed to MP3 128 kbps for streaming
- Uploaded to R2: `dubbed/{episode_id}/{language}.mp3`

---

## Data Model Changes

### New table: `dub_stems`

```sql
CREATE TABLE dub_stems (
  episode_id         BIGINT PRIMARY KEY REFERENCES episodes(id),
  vocals_r2_key      TEXT NOT NULL,
  background_r2_key  TEXT NOT NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### New table: `dub_segments`

```sql
CREATE TABLE dub_segments (
  id          BIGSERIAL PRIMARY KEY,
  episode_id  BIGINT NOT NULL REFERENCES episodes(id),
  idx         INT NOT NULL,
  speaker_id  TEXT,
  start_sec   FLOAT NOT NULL,
  end_sec     FLOAT NOT NULL,
  text        TEXT NOT NULL,
  words       JSONB,            -- word-level alignment from WhisperX
  UNIQUE (episode_id, idx)
);
```

### New table: `dub_segment_translations`

```sql
CREATE TABLE dub_segment_translations (
  segment_id     BIGINT NOT NULL REFERENCES dub_segments(id),
  language       TEXT NOT NULL,
  translated_text TEXT NOT NULL,
  synth_r2_key   TEXT,          -- R2 key for synthesised segment audio
  synth_duration FLOAT,         -- seconds, set after synthesis
  PRIMARY KEY (segment_id, language)
);
```

### Changes to `dubbed_episodes`

```sql
ALTER TABLE dubbed_episodes
  ADD COLUMN speaker_samples JSONB,  -- {"SPEAKER_00": "r2_key", ...}
  ADD COLUMN bg_volume       FLOAT NOT NULL DEFAULT 0.15;
```

### Retired columns / behaviour

- `dubbed_episodes.translation` (full-episode text) — kept for backwards compatibility but no longer populated by v2 jobs. Read by the player to show the translation text panel.
- Steps `transcription`, `translation`, `synthesis` in `dubbed_episodes.step` replaced by the new step names below.

### New step names in `dubbed_episodes.step`

| Step value | Meaning |
|---|---|
| `queued` | Job pushed to Redis, not yet picked up |
| `separating` | Demucs running |
| `transcribing` | WhisperX running |
| `translating` | DeepL calls in progress |
| `synthesizing` | XTTS-v2 running (N segments) |
| `assembling` | Timeline assembly |
| `mixing` | Final stem mix |
| `uploading` | Uploading result to R2 |
| `complete` | Done |

---

## Job Format (Redis)

### Enqueue payload (Crystal → Redis)

```json
{
  "job_id":       "hex32",
  "dub_id":       123,
  "episode_id":   456,
  "audio_url":    "https://...",
  "language":     "ru",
  "callback_url": "https://app.buzz-bot.top/internal/dub_result",
  "bg_volume":    0.15
}
```

### Callback payload (Python → Crystal)

**Success:**
```json
{
  "job_id":     "hex32",
  "dub_id":     123,
  "episode_id": 456,
  "language":   "ru",
  "success":    true,
  "r2_url":     "https://pub-xxx.r2.dev/dubbed/456/ru.mp3",
  "duration_sec": 2847.3,
  "segment_count": 142,
  "speaker_count": 2
}
```

**Failure:**
```json
{
  "job_id":   "hex32",
  "dub_id":   123,
  "success":  false,
  "step":     "separating",
  "error":    "Demucs OOM: episode too long"
}
```

---

## Reuse and Caching

| Resource | Scope | Reuse trigger |
|---|---|---|
| Stems (vocals, background) | Episode | `dub_stems` row exists |
| Transcript + segments | Episode | `dub_segments` rows exist |
| Speaker samples | Episode | `dubbed_episodes.speaker_samples` from any completed dub |
| Translated segments | Episode + Language | `dub_segment_translations` rows exist |
| Synthesised segments | Episode + Language | `dub_segment_translations.synth_r2_key` set |
| Final mix | Episode + Language | `dubbed_episodes.r2_url` + not expired |

**Example savings on second dub of same episode into a different language:**
- Steps 1–3 (Demucs + WhisperX + sample extraction) entirely skipped
- Only translation + synthesis + assembly + mix run

---

## Step Progress Reporting

The Python service posts a progress update to Crystal after each step completes:

```
POST /internal/dub_progress
{
  "dub_id": 123,
  "step": "transcribing",
  "pct": 40          // optional percentage within step
}
```

Crystal updates `dubbed_episodes.step` and fires `pg_notify('dub_status', ...)`, which the SSE hub fans out to the client. The client renders a step label + progress bar (existing UI, step names updated).

---

## Error Handling and Recovery

| Scenario | Behaviour |
|---|---|
| Demucs OOM | Mark failed; suggest shorter episode |
| WhisperX no speech | Mark failed; log |
| DeepL quota exceeded | Retry after 60 s; fail after 3 attempts |
| XTTS-v2 segment failure | Skip segment (insert silence); log warning; continue |
| Assembly duration > 150% original | Truncate to 150%; log warning |
| R2 upload failure | Retry 3× with backoff; fail job |
| Worker crash mid-job | On restart: detect `step NOT IN ('queued', 'complete')` rows with `updated_at > 5 min ago` → mark failed; user retries |

---

## Constraints and Limits

| Constraint | Value | Reason |
|---|---|---|
| Max episode duration | 90 min | Demucs + WhisperX memory |
| Max segments per episode | 500 | Assembly performance |
| Max speakers | 8 | Voice clone quality degrades beyond this |
| Max segment duration | 30 s | XTTS-v2 context limit |
| Min segment duration | 0.5 s | Below this, skip synthesis; insert original-length silence |
| bg_volume range | 0.0–0.5 | Configurable per dub |
| R2 retention | 29 days | Same as v1 |

Segments longer than 30 s are split at sentence boundaries (detected from word-level alignment) before synthesis.

---

## Removed from v1

- `dub-transcriber` Crystal service (retired)
- `dub-translator` Crystal service (retired)
- `dub-synthesizer` Crystal service (retired)
- Replicate API dependency for whisper and XTTS-v2
- `whisper-service` Crystal worker (replaced by WhisperX inside dub-pipeline)
- `REPLICATE_API_TOKEN` env var (no longer needed)

The Redis queue and job format are new; the `whisper:jobs` queue is retired.

---

## Open Questions

1. **Coqui TTS licence** — XTTS-v2 weights are CC BY 4.0; commercial use requires checking Coqui's terms. **Decision: run locally; Replicate removed as dependency.**
2. **Demucs model** — **Decision: `htdemucs_ft` (fine-tuned, higher quality).** ~10 min per hour of audio on M4 GPU.
3. **Background volume default** — 0.15 (−16 dB relative). **Decision: ship at 0.15, tune later.**
4. **Segment-level translation context** — **Decision: use DeepL `context` parameter (Pro tier confirmed).**
5. **Multi-language dub queue** — if two languages are requested for the same episode simultaneously, stems and transcription should only run once. Pipeline needs a lightweight lock (Redis SETNX on `stems:{episode_id}`).
