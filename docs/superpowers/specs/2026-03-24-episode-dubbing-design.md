# Episode Dubbing Feature — Design Spec

**Date:** 2026-03-24
**Status:** Approved

---

## Overview

On-demand podcast episode dubbing for premium users. The user taps a "Dub Episode" button on the player page, selects a target language, and receives a Telegram notification when the dubbed audio is ready. The dubbed audio is playable inside the Mini App and sendable to Telegram chat. Dubbed audio is cached for 30 days on Cloudflare R2 and **shared across all users** — one dub per `(episode, language)` pair.

---

## Pipeline

A three-step async pipeline runs in a Crystal fiber (same fire-and-forget pattern as `AudioSender`). Replicate jobs are asynchronous — the fiber polls `GET https://api.replicate.com/v1/predictions/{id}` with exponential backoff until `succeeded` or `failed`, with a **20-minute timeout per Replicate step** (two steps = max 40 min total, safely under the startup-reset threshold).

```
POST /episodes/:id/dub
  → validate: premium user, language in allowlist, duration_sec ≤ 3600 (NULL = allow)
  → upsert dubbed_episodes row (status: pending), return 202 + row id
  → if already done/processing/pending: return existing status, no new fiber
  → spawn DubJob fiber, set status: processing

DubJob fiber:
  1. Extract first 30s of episode audio → temp file (voice reference for XTTS-v2)
  2. POST Replicate whisper-large-v3 with full episode audio_url
       → poll until succeeded (max 20 min) → transcript text
  3. POST DeepL /v2/translate with transcript + target language
       → translated text
  4. POST Replicate lucataco/xtts-v2 with translated text + 30s voice clip + language
       → poll until succeeded (max 20 min) → dubbed MP3 URL (Replicate CDN)
  5. Download MP3 from Replicate CDN → upload to Cloudflare R2
       key: dubbed/{episode_id}/{language}.mp3
  6. Update dubbed_episodes: status=done, r2_url=..., expires_at=now+29d
  7. Send Telegram notification: "Your dubbed episode is ready ▶"

On any step failure or timeout:
  → update dubbed_episodes: status=failed, error=<message>
  → fiber exits cleanly (no Telegram notification)
```

**Process restart recovery:** on startup, all rows in `processing` **or `pending`** are unconditionally reset to `failed` — a restart kills all in-flight fibers and no fiber will re-pick up a stale `pending` row automatically. Users can re-trigger from the UI.

**Clock skew between R2 and DB:** `expires_at` is set to `now + 29 days`; the R2 bucket lifecycle policy is set to **31 days**. This ensures the DB always expires the record logically (returning `expired` to clients) at least one day before R2 physically deletes the object, preventing a window where the DB shows `done` but the file is gone.

---

## Data Model

### New table: `dubbed_episodes`

```sql
CREATE TABLE dubbed_episodes (
  id           BIGSERIAL PRIMARY KEY,
  episode_id   BIGINT NOT NULL REFERENCES episodes(id),
  language     VARCHAR(10) NOT NULL,          -- ISO 639-1, e.g. "ru", "es"
  status       VARCHAR(20) NOT NULL DEFAULT 'pending',
  r2_url       TEXT,                          -- set when done; NULL otherwise
  error        TEXT,                          -- set when failed; NULL otherwise
  expires_at   TIMESTAMPTZ,                   -- set when done: now + 29 days
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (episode_id, language)
);

CREATE INDEX dubbed_episodes_episode_id_idx ON dubbed_episodes(episode_id);
```

**No `user_id` column** — dubs are shared across all users.

**Statuses:** `pending` → `processing` → `done` | `failed`

`expired` is **not stored** — derived at query time: `status = 'done' AND expires_at < NOW()`.

### Status transitions

```
pending    → processing  (DubJob fiber starts)
processing → done        (pipeline succeeds)
processing → failed      (any step fails, times out, or process restarts)
failed     → pending     (user re-triggers; upsert resets row)
done+expired → pending   (user re-triggers after 29 days; upsert resets row)
```

Re-trigger upsert:
```sql
INSERT INTO dubbed_episodes (episode_id, language, status)
VALUES ($1, $2, 'pending')
ON CONFLICT (episode_id, language) DO UPDATE
  SET status = 'pending', r2_url = NULL, error = NULL, created_at = NOW()
```

### Migration: `users` table

```sql
ALTER TABLE users ADD COLUMN preferred_dub_language VARCHAR(10);
```

Null means no preference.

### `episodes.duration_sec`

The `duration_sec` column already exists on the `episodes` table (populated from RSS). When `duration_sec IS NULL` (RSS didn't include duration), the length guard is skipped and the job is allowed to proceed.

---

## Supported Languages (allowlist)

Intersection of XTTS-v2 and DeepL supported languages. Arabic is excluded (not in DeepL).

| Code | Language |
|---|---|
| `en` | English |
| `es` | Spanish |
| `fr` | French |
| `de` | German |
| `it` | Italian |
| `pt` | Portuguese |
| `pl` | Polish |
| `tr` | Turkish |
| `ru` | Russian |
| `nl` | Dutch |
| `cs` | Czech |
| `zh` | Chinese (Simplified) |
| `ja` | Japanese |
| `hu` | Hungarian |
| `ko` | Korean |

---

## API Endpoints

### `POST /episodes/:id/dub`

Trigger dubbing. **Premium-gated** (401 if not authenticated, 402 if not premium).

**Request body:** `{"language": "ru"}`

**Responses:**

| Code | Body | Condition |
|---|---|---|
| `401` | `"Unauthorized"` | Not authenticated |
| `402` | `{"error":"premium_required"}` | Not premium |
| `400` | `{"error":"unsupported_language"}` | `language` not in allowlist |
| `400` | `{"error":"episode_too_long"}` | `duration_sec > 3600` |
| `404` | `{"error":"not_found"}` | Episode doesn't exist |
| `202` | `{"id":42,"status":"pending"}` | New job created |
| `200` | `{"id":42,"status":"processing"}` | Job already in flight |
| `200` | `{"id":42,"status":"done","r2_url":"https://..."}` | Cached and valid |
| `202` | `{"id":42,"status":"pending"}` | Expired — upsert resets row, new job started |
| `200` | `{"id":42,"status":"failed","error":"..."}` | Last attempt failed — re-POST to retry |

`r2_url` is present **only** when `status=done`. All other statuses omit it.

### `GET /episodes/:id/dub/:language`

Poll for dub status. **Open to all authenticated users** (dubs are shared; non-premium users can check if a dub exists, though they can't trigger one).

**Validation:** `:language` must be in the allowlist (`400` otherwise).

**Responses:**

| Code | Body |
|---|---|
| `200` | `{"status":"pending"\|"processing"\|"done"\|"failed"\|"expired","r2_url":"...","error":"..."}` |
| `404` | `{"error":"not_found"}` — never requested |

`r2_url` present only when `status=done`. `error` present only when `status=failed`.

### `PUT /user/dub_language`

Save preferred dubbing language to user record. Premium-gated.

**Request body:** `{"language":"ru"}` — validated against allowlist.
**Response:** `204 No Content` | `400 {"error":"unsupported_language"}`

---

## Frontend (CLJS Player)

### Dub button

Shown for premium users only, below the "Send to Telegram" button:

```
[ ▶ Dub Episode ]
```

Tapping opens a language picker modal. The user's `preferred_dub_language` is pre-selected.

### Re-frame events

| Event | Description |
|---|---|
| `::dub-open-picker` | Opens language picker modal |
| `::dub-language-selected [lang]` | Saves preferred language (PUT /user/dub_language), closes picker, fires `::dub-request` |
| `::dub-request [episode-id lang]` | POST /episodes/:id/dub; on success sets dub state, starts polling if pending/processing |
| `::dub-status-tick [episode-id lang]` | GET /episodes/:id/dub/:language; updates dub state; clears interval on done/failed |
| `::dub-done [r2-url]` | Sets audio source to r2_url; shows Play Dubbed button |
| `::dub-failed [error]` | Shows failure message |
| `::dub-send-telegram [episode-id]` | POST /episodes/:id/send with dubbed=true flag |

### Re-frame subscriptions

| Subscription | Returns |
|---|---|
| `::dub-status [episode-id]` | `{:status :pending\|:processing\|:done\|:failed\|:expired, :r2-url "..."}` or nil |
| `::preferred-dub-language` | ISO 639-1 string or nil |
| `::dub-picker-open?` | boolean |

### Player dub states

| State | UI |
|---|---|
| `nil` | "Dub Episode" button |
| `pending` / `processing` | Spinner + "Dubbing… (a few minutes)" |
| `done` | "▶ Play Dubbed" + "Send Dubbed to Telegram" |
| `failed` | "Dubbing failed — tap to retry" (tap re-triggers `::dub-request`) |
| `expired` | Same as `nil` — "Dub Episode" button |

### Polling

On `pending`/`processing`, start `js/setInterval` at 5s firing `::dub-status-tick`. Clear on `done`, `failed`, or `expired`. When `expired` is received while polling, show the "Dub Episode" button again (same as nil state) so the user can re-trigger.

### Audio playback

When `done`, the player uses `r2_url` as its audio source. The existing `audio_proxy` endpoint streams R2 public URLs without modification.

### Send Dubbed to Telegram

Uses `POST /episodes/:id/send` (existing endpoint, premium-gated) with an additional body field:

**Request body:** `{"dubbed": true, "language": "ru"}`

**Backend behavior:** reads `r2_url` from `dubbed_episodes` for the given `(episode_id, language)`. If the row is missing or not in `done` status, returns `409 {"error":"dub_not_ready"}`. Otherwise passes `r2_url` to `AudioSender` instead of the episode's `audio_url`. R2 is public-read so Telegram's Bot API fetches the file directly via URL (no server-side re-upload).

**Response:** `200 {"sent": true}` on success, same error codes as the existing send endpoint for other failures.

---

## External Services

| Service | Purpose | Key detail |
|---|---|---|
| Replicate `openai/whisper-large-v3` | Transcription | Input: episode `audio_url`; async prediction, 20-min timeout |
| DeepL `/v2/translate` | Translation | Free tier: 500k chars/month; ISO 639-1 codes |
| Replicate `lucataco/xtts-v2` | TTS synthesis | Input: text + 30s voice clip + language; async prediction, 20-min timeout |
| Cloudflare R2 | Storage | Public-read bucket; S3-compatible; 31-day lifecycle; `expires_at` in DB = 29 days |

---

## Security

- **Language validation:** `:language` in path params and request bodies validated against hardcoded allowlist before use in DB queries, R2 keys, or API calls — prevents R2 key path traversal.
- **R2 public bucket:** acceptable — podcast audio is not private content; R2 keys are numeric IDs, not guessable titles.
- **Rate limiting:** the UNIQUE constraint caps cost per `(episode, language)` — processed at most once per 29-day window. A single user can trigger dubs across all 15 languages (15 jobs max per episode). No additional per-user rate limit in v1; this is acceptable given the premium gate and the shared-dub model.
- **Premium gate:** `user.subscribed?` (existing method, checks `sub_expires_at`).
- **Secrets:** `REPLICATE_API_TOKEN` and `DEEPL_API_KEY` must not appear in logs or error messages.

---

## New Files

| File | Description |
|---|---|
| `src/dub/dub_job.cr` | Pipeline fiber: voice extraction → transcribe → translate → synthesize → upload → notify |
| `src/dub/replicate_client.cr` | Replicate API: submit prediction + polling loop with backoff, 20-min timeout |
| `src/dub/deepl_client.cr` | DeepL translation API client |
| `src/dub/r2_storage.cr` | Cloudflare R2 upload via S3-compatible API |
| `src/models/dubbed_episode.cr` | DubbedEpisode model: upsert, find, expired? derived from expires_at |
| `src/web/routes/dub.cr` | POST /episodes/:id/dub, GET /episodes/:id/dub/:language, PUT /user/dub_language |
| `migrations/007_dubbed_episodes.sql` | New table + users column |
| `src/cljs/buzz_bot/views/dub.cljs` | Language picker modal + dub state display |
| `src/cljs/buzz_bot/events/dub.cljs` | Re-frame events listed above |
| `src/cljs/buzz_bot/subs/dub.cljs` | Re-frame subscriptions listed above |

---

## Modified Files

| File | Change |
|---|---|
| `src/web/server.cr` | Register `Web::Routes::Dub` |
| `src/web/routes/episodes.cr` | `POST /episodes/:id/send` — accept `dubbed: true, language: "ru"` in body; read `r2_url` from `dubbed_episodes`; return 409 if dub not ready |
| `src/cljs/buzz_bot/views/player.cljs` | Add dub button, language picker trigger, dub state display |
| `src/cljs/buzz_bot/subs.cljs` | Wire in dub subscriptions |
| `src/buzz_bot.cr` | On startup: reset all `processing` and `pending` rows to `failed` |

---

## New ENV Vars

```
REPLICATE_API_TOKEN=...
DEEPL_API_KEY=...
R2_ACCOUNT_ID=...
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET=buzz-bot-dubbed
R2_PUBLIC_URL=https://pub-xxx.r2.dev
```
