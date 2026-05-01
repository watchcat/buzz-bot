# API Reference

All Mini App routes authenticate via `X-Init-Data` (Telegram `initData` HMAC-SHA256).

## Routes

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/webhook` | Telegram update receiver |
| `GET` | `/app` | SPA HTML shell |
| `GET` | `/inbox` | Unheard episodes across all subscriptions |
| `GET` | `/feeds` | List subscribed feeds |
| `POST` | `/feeds` | Subscribe by RSS URL |
| `POST` | `/feeds/opml` | Bulk-import from OPML |
| `DELETE` | `/feeds/:id` | Unsubscribe |
| `GET` | `/episodes?feed_id=X` | Episode list (`limit`, `offset`, `order`) |
| `GET` | `/episodes/:id/player` | Player data — episode, feed, recs, next, preferred dub language |
| `PUT` | `/episodes/:id/progress` | Save playback position |
| `PUT` | `/episodes/:id/signal` | Toggle bookmark |
| `POST` | `/episodes/:id/send` | Send audio to Telegram chat (`dubbed=true&language=ru` for dubbed) |
| `GET` | `/episodes/:id/audio_proxy` | Auth-gated streaming proxy |
| `POST` | `/episodes/:id/dub` | Queue a dub job `{language: "ru"}` |
| `GET` | `/episodes/:id/dub/:lang` | Poll dub status |
| `GET` | `/episodes/:id/dub/:lang/stream` | SSE stream for real-time progress |
| `GET` | `/episodes/:id/subtitles` | Subtitle cues (`?language=ru&audio_lang=ru`) |
| `PUT` | `/user/dub_language` | Save preferred dub language |
| `POST` | `/internal/dub_result` | Callback from worker on job completion |
| `POST` | `/internal/dub_progress` | Callback from worker for step updates |
| `GET` | `/img-proxy?url=` | HTTPS image proxy |
| `GET` | `/flags` | Feature flag state (admin-only) |
| `GET` | `/bookmarks` | Bookmarked episodes |
| `GET` | `/bookmarks/search?q=X` | Search bookmarks |
| `GET` | `/search?q=X` | Search Apple Podcasts directory |
| `POST` | `/search/subscribe` | Subscribe to a search result |
| `GET` | `/recommendations` | Collaboratively filtered recommendations |

---

## Database Schema

```
users ──< user_feeds >── feeds ──< episodes ──< user_episodes >── users
                                       │
                                       ├──< dubbed_episodes
                                       └──< dub_segments ──< dub_segment_translations
```

| Table | Purpose |
|-------|---------|
| `users` | One row per Telegram user |
| `feeds` | Shared podcast feed registry, deduplicated by URL |
| `user_feeds` | M:N — which users subscribe to which feeds |
| `episodes` | Episodes deduplicated by RSS `<guid>` per feed |
| `user_episodes` | Per-user playback position and bookmark signal |
| `dubbed_episodes` | One row per (episode, language) — status, R2 URL, speaker samples JSONB |
| `dub_segments` | Transcript segments with original timestamps, speaker ID, word-level alignment |
| `dub_segment_translations` | One row per (segment, language) — translated text, synthesized audio key, `synth_start_sec`, `synth_duration` |

`dubbed_episodes.step` tracks pipeline progress (`queued` through `complete` / `failed`). A PostgreSQL trigger fires `pg_notify('dub_status', ...)` on every step update, fanning out to all SSE subscribers.

`dub_segment_translations.synth_start_sec` is the actual position of each segment in the dubbed audio file (not the ideal/original timestamp). The subtitle API joins these to serve karaoke cues with correct timing for dubbed playback.

---

## Feature Flags

Runtime toggleable switches stored in PostgreSQL; toggled via the bot `/flag` command (admin only).

| Flag | Default | Description |
|------|---------|-------------|
| `offline_caching` | true | Download and cache episode audio for offline playback |
| `stall_recovery` | true | Auto-recover from network stalls and audio errors |
| `img_proxy` | true | Route external artwork through `/img-proxy` |

```sh
/flag list                    # Show all flags & current values
/flag offline_caching off     # Disable a flag
/flag stall_recovery on       # Enable a flag
```

---

## How Recommendations Work

Item-based collaborative filtering in pure SQL:

1. Find all episodes the current user has bookmarked
2. Find other users who bookmarked at least one of those episodes
3. Collect episodes those users bookmarked that the current user hasn't seen
4. Rank by how many similar users bookmarked each candidate

No ML library required — single PostgreSQL round-trip.
