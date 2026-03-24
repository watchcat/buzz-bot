# Episode Dubbing Feature — Design Spec

**Date:** 2026-03-24
**Status:** Approved

---

## Overview

On-demand podcast episode dubbing for premium users. The user taps a "Dub Episode" button on the player page, selects a target language, and receives a Telegram notification when the dubbed audio is ready. The dubbed episode is playable inside the Mini App and sendable to Telegram chat. Dubbed audio is cached for 30 days on Cloudflare R2.

---

## Pipeline

A three-step async pipeline runs in a Crystal fiber (same fire-and-forget pattern as `AudioSender`):

```
POST /episodes/:id/dub
  → create dubbed_episodes row (status: pending)
  → spawn DubJob fiber
  → return 202 immediately

DubJob fiber:
  1. Download episode audio from audio_url
  2. POST Replicate whisper-large-v3  → transcript text
  3. POST DeepL /v2/translate         → translated text
  4. POST Replicate lucataco/xtts-v2  → dubbed MP3 (Replicate CDN URL)
  5. Download MP3 → upload to Cloudflare R2
  6. Update dubbed_episodes: status=done, r2_url=..., expires_at=now+30d
  7. Send Telegram message: "Your dubbed episode is ready ▶"
```

Dubbed audio is served via the existing `audio_proxy` endpoint — the player substitutes `r2_url` for `audio_url`. No new streaming infrastructure required.

---

## Data Model

### New table: `dubbed_episodes`

```sql
CREATE TABLE dubbed_episodes (
  id           BIGSERIAL PRIMARY KEY,
  episode_id   BIGINT NOT NULL REFERENCES episodes(id),
  language     VARCHAR(10) NOT NULL,
  status       VARCHAR(20) NOT NULL DEFAULT 'pending',
  r2_url       TEXT,
  error        TEXT,
  expires_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (episode_id, language)
);
```

**Statuses:** `pending` → `processing` → `done` | `failed` | `expired`

The UNIQUE constraint on `(episode_id, language)` prevents duplicate jobs. A second request for the same episode+language returns the existing row. Failed rows are upserted (reset and retried).

### Migration: `users` table

Add column:
```sql
ALTER TABLE users ADD COLUMN preferred_dub_language VARCHAR(10);
```

Null means no preference. Set when the user first selects a language; pre-selected on subsequent dub dialogs.

### 30-day lifecycle

- R2 bucket lifecycle policy deletes files after 30 days.
- A nightly sweep (or on-startup) sets `status = 'expired'` and clears `r2_url` for rows past `expires_at`, so the UI can offer re-dubbing.

---

## API Endpoints

### `POST /episodes/:id/dub`
Trigger dubbing. Premium-gated.

**Request body:** `{ "language": "ru" }`

**Responses:**
- `402` — user is not premium
- `202 { "status": "pending", "id": <dubbed_episode_id> }` — new job created
- `200 { "status": "done", "r2_url": "..." }` — already cached
- `200 { "status": "processing" }` — job already in flight

### `GET /episodes/:id/dub/:language`
Poll for job status.

**Responses:**
- `200 { "status": "pending"|"processing"|"done"|"failed"|"expired", "r2_url": "..." }`
- `404` — never requested

### `PUT /user/dub_language`
Save preferred dubbing language to user record.

**Request body:** `{ "language": "ru" }`
**Response:** `204 No Content`

---

## Frontend (CLJS Player)

### Dub button

Shown for premium users only, below the "Send to Telegram" button:

```
[ ▶ Dub Episode ]
```

Tapping opens a language picker modal. The user's `preferred_dub_language` is pre-selected.

### Supported languages (XTTS-v2)

English, Spanish, French, German, Italian, Portuguese, Polish, Turkish, Russian, Dutch, Czech, Arabic, Chinese, Japanese, Hungarian, Korean

### Player dub states

| State | UI |
|---|---|
| `nil` | "Dub Episode" button |
| `pending` / `processing` | Spinner + "Dubbing… (this may take a few minutes)" |
| `done` | "▶ Play Dubbed" + "Send Dubbed to Telegram" buttons |
| `failed` | "Dubbing failed, try again" |
| `expired` | Same as `nil` — offer re-dub |

### Polling

On entering `pending`/`processing`, start a `js/setInterval` at 5s calling `GET /dub/:language`. Clear on `done` or `failed`. Implemented as a Re-frame event `:dub-status-tick`.

### Audio playback

When `done`, the player swaps its audio source from `audio_url` to `r2_url`. The existing `audio_proxy` endpoint streams R2 URLs without modification.

"Send Dubbed to Telegram" reuses `AudioSender` pointed at `r2_url`.

---

## External Services

| Service | Purpose | Key detail |
|---|---|---|
| Replicate `openai/whisper-large-v3` | Transcription | Input: audio URL; output: text |
| DeepL `/v2/translate` | Translation | Free tier: 500k chars/month |
| Replicate `lucataco/xtts-v2` | TTS synthesis | Input: text + language + voice sample; output: MP3 URL |
| Cloudflare R2 | Storage | S3-compatible; 30-day lifecycle policy; file key: `dubbed/{episode_id}/{language}.mp3` |

---

## New Files

| File | Description |
|---|---|
| `src/dub/dub_job.cr` | Pipeline fiber: transcribe → translate → synthesize → upload → notify |
| `src/dub/replicate.cr` | Replicate API client (Whisper + XTTS-v2) |
| `src/dub/deepl.cr` | DeepL translation API client |
| `src/dub/r2_storage.cr` | Cloudflare R2 upload via S3-compatible API |
| `src/models/dubbed_episode.cr` | DubbedEpisode model (find, upsert, expire sweep) |
| `src/web/routes/dub.cr` | `POST /episodes/:id/dub`, `GET /episodes/:id/dub/:language`, `PUT /user/dub_language` |
| `migrations/007_dubbed_episodes.sql` | New table + users column |
| `src/cljs/buzz_bot/views/dub.cljs` | Language picker component + dub state UI |
| `src/cljs/buzz_bot/events/dub.cljs` | Re-frame events: `:dub-start`, `:dub-status-tick`, `:dub-done` |

---

## Modified Files

| File | Change |
|---|---|
| `src/web/server.cr` | Register `Web::Routes::Dub` |
| `src/web/routes/episodes.cr` | `audio_proxy` — accept R2 URLs (already works, no change needed) |
| `src/cljs/buzz_bot/views/player.cljs` | Add dub button + state display |
| `src/cljs/buzz_bot/subs.cljs` | Add dub-status subscription |
| `src/buzz_bot.cr` | Add `DubbedEpisode.expire_sweep` to startup |

---

## New ENV Vars Required

```
REPLICATE_API_TOKEN=...
DEEPL_API_KEY=...
R2_ACCOUNT_ID=...
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET=buzz-bot-dubbed
R2_PUBLIC_URL=https://pub-xxx.r2.dev   # or custom domain
```
