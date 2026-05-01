# AI Dubbing

The centrepiece feature. Tap **Dub in...**, pick a language, and Buzz-Bot re-records the episode with every speaker's voice cloned into the target language. The dubbed MP3 is stored on Cloudflare R2 and playable directly in the player or sendable to Telegram chat.

## Supported Languages

English, Spanish, French, German, Italian, Portuguese, Polish, Turkish, Russian, Dutch, Czech, Chinese, Japanese, Hungarian, Korean

## How It Works

```
User taps "Dub in…" → picks language
         │
         ▼
POST /episodes/:id/dub
  Creates dubbed_episodes row (status: queued)
  POST /v2/{endpoint_id}/run  →  RunPod Serverless API
         │
         ▼  (RunPod GPU worker — dub-pipeline)
         │
  1. Separate stems — Demucs htdemucs_ft
     → vocals.wav + background.wav (cached in R2, reused across languages)
         │
  2. Transcribe — WhisperX large-v3 (CUDA)
     + pyannote speaker diarization
     → segments with speaker IDs, timestamps, word confidences
         │
  3. Extract voice samples — best 15–30 s clip per speaker
         │
  4. Split long segments at sentence boundaries / pauses
         │
  5. Translate — Gemini Flash (batch with context)
     → translated_text per segment (same-language = copy verbatim)
         │
  6. Synthesize — VoxCPM2
     voice cloning: each speaker's sample → target language TTS
     output: 48 kHz mono WAV per segment
         │
  7. Assemble — cursor-based placement
     synth audio placed at original timestamps;
     over-runs consume gaps, under-runs add 50% silence;
     actual_cursor tracks real ffmpeg position for subtitle sync;
     150% duration cap
         │
  8. Mix — ffmpeg amix
     dubbed vocals + background at configurable volume
         │
  9. Upload → R2 dubbed/{episode_id}/{lang}.mp3
         │
         ▼
POST /internal/dub_result  (callback from RunPod to buzz-bot)
  Updates dubbed_episodes: status=done, r2_url, speaker_count
  Stores segments + translations in dub_segments (for subtitle sync)
  Sends Telegram notification to user

Progress updates via POST /internal/dub_progress → pg_notify → SSE
```

## Real-time Progress

While dubbing runs, the client subscribes to `GET /episodes/:id/dub/:lang/stream` (SSE). The worker posts step updates to `/internal/dub_progress`; buzz-bot writes to PostgreSQL and triggers `pg_notify`; the SSE handler fans out to all connected clients without polling.

| Step | Label | Progress |
|---|---|---|
| `queued` | Queued | 5% |
| `separating` | Separating stems | 15% |
| `transcribing` | Transcribing | 30% |
| `translating` | Translating | 50% |
| `synthesizing` | Synthesizing voices | 70% |
| `assembling` | Assembling audio | 90% |
| `mixing` | Mixing | 95% |
| `uploading` | Uploading | 95% |
| `complete` | Done | 100% |

## Stem Reuse

Vocal separation (Demucs, ~2 min) and its outputs are stored in R2 under `dub-stems/{episode_id}/`. Re-dubbing the same episode into a second language skips this step entirely.

## Data Model

| What | Where |
|---|---|
| Vocals stem | R2 `dub-stems/{episode_id}/vocals.wav` |
| Background stem | R2 `dub-stems/{episode_id}/background.wav` |
| Speaker voice samples | R2 `dub-stems/{episode_id}/speaker_{id}.wav` |
| Dubbed MP3 | R2 `dubbed/{episode_id}/{lang}.mp3` |
