# Buzz-Bot

A Telegram bot and Mini App for podcast listening. Subscribe to RSS feeds, track your listening progress, and discover new episodes through collaborative filtering recommendations.

## Features

- **RSS subscriptions** — add any podcast by URL; bulk-import via OPML
- **Episode player** — native audio playback inside Telegram with resume-from-position
- **Progress tracking** — listening position saved automatically every 5 seconds
- **Like / Dislike signals** — rate episodes to train recommendations
- **Collaborative filtering** — surface episodes liked by users with similar taste
- **Telegram-native UI** — adapts to the user's Telegram theme (dark/light, accent colours)

## Tech Stack

| Layer | Technology |
|---|---|
| Language | [Crystal](https://crystal-lang.org/) >= 1.6 |
| Web server | [Kemal](https://kemalcr.com/) |
| Telegram bot | [Tourmaline](https://github.com/protoncr/tourmaline) |
| Database driver | [crystal-pg](https://github.com/will/crystal-pg) + [crystal-db](https://github.com/crystal-lang/crystal-db) |
| Database | PostgreSQL (tested with [Neon](https://neon.tech)) |
| Frontend | HTMX + Telegram WebApp JS SDK |
| Deployment | Docker (multi-stage build) |

---

## Installation

### Prerequisites

- Crystal >= 1.6 and `shards` (for local development)
- Docker and Docker Compose (for production)
- A PostgreSQL database (Neon free tier works)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- A public HTTPS URL pointing to your server (required for webhooks)

### 1. Clone and install dependencies

```sh
git clone https://github.com/yourname/buzz-bot.git
cd buzz-bot
shards install
```

### 2. Configure environment

```sh
cp .env.example .env
```

Edit `.env`:

```env
BOT_TOKEN=your-telegram-bot-token
WEBHOOK_URL=https://yourdomain.com/webhook
DATABASE_URL=postgres://user:pass@neon-host/dbname?sslmode=require
PORT=3000
BASE_URL=https://yourdomain.com
```

| Variable | Description |
|---|---|
| `BOT_TOKEN` | Token from [@BotFather](https://t.me/BotFather) |
| `WEBHOOK_URL` | Full public URL to the `/webhook` endpoint |
| `DATABASE_URL` | PostgreSQL connection string |
| `PORT` | Port Kemal listens on (default: `3000`) |
| `BASE_URL` | Public base URL — used for the Mini App button in `/start` |

### 3. Run the database migrations

If you have `psql` available:

```sh
psql "$DATABASE_URL" -f migrations/001_initial.sql
psql "$DATABASE_URL" -f migrations/002_feed_refresh.sql
```

Or use the included Crystal migration runner (no `psql` required — uses the same DB driver as the app):

```sh
crystal run migrate.cr
```

### 4a. Run locally

Both the Telegram webhook and the Mini App require a public HTTPS URL — Telegram's servers push updates to `/webhook`, and Telegram's WebView refuses to load `http://` Mini App links. Use Cloudflare Tunnel to expose your local server for both — see [Local Development with Cloudflare Tunnel](#local-development-with-cloudflare-tunnel) below.

```sh
crystal run src/buzz_bot.cr
```

On startup the bot automatically calls `setWebhook` to register `WEBHOOK_URL` with Telegram.

### 4b. Run with Docker (recommended for production)

```sh
docker compose up -d
```

The image is built in two stages: a Crystal/Alpine builder compiles a fully static binary, which is then copied into a minimal Alpine runtime image.

---

## Local Development with Cloudflare Tunnel

Running the Mini App locally requires a public HTTPS URL for **two reasons**:

1. **Telegram webhooks** — Telegram's servers push updates to your `/webhook` endpoint; it must be reachable from the internet over HTTPS.
2. **Mini App serving** — Telegram's WebView refuses to load `http://` URLs. When a user taps "Open Buzz-Bot", Telegram fetches `BASE_URL/app` directly. That URL must also be public HTTPS — the same tunnel handles it.

[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) (`cloudflared`) creates a secure tunnel from Cloudflare's edge to your local machine — no port forwarding, no self-signed certificates.

```
Telegram servers  ──► https://your-tunnel.com/webhook   (bot updates)
Telegram WebView  ──► https://your-tunnel.com/app        (Mini App UI)
                               │ Cloudflare Tunnel
                               ▼
                     localhost:3000   (Kemal, all routes)
```

Both `WEBHOOK_URL` and `BASE_URL` in `.env` must point to the **same tunnel URL** — the single Kemal server handles all routes.

### Install cloudflared

```sh
# macOS
brew install cloudflared

# Linux (amd64)
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
```

### Option A — Quick tunnel (no account, temporary URL)

```sh
cloudflared tunnel --url http://localhost:3000
```

Cloudflare prints a random URL such as `https://random-words.trycloudflare.com`. Update **both** values in `.env` to this URL:

```env
WEBHOOK_URL=https://random-words.trycloudflare.com/webhook
BASE_URL=https://random-words.trycloudflare.com
```

`WEBHOOK_URL` is where Telegram pushes bot updates; `BASE_URL` is what the bot sends to users as the Mini App link (the WebView opens `BASE_URL/app`). Both go through the same tunnel.

> **Note:** The URL changes every time you restart `cloudflared`. Because the app re-registers the webhook on every startup, just restart the app after restarting the tunnel and it will pick up the new URL automatically.

### Option B — Named tunnel (free Cloudflare account, stable URL)

Requires a domain managed by Cloudflare.

**One-time setup:**

```sh
cloudflared tunnel login                          # opens browser, saves cert
cloudflared tunnel create buzz-bot                # creates tunnel, prints <tunnel-id>
cloudflared tunnel route dns buzz-bot app.yourdomain.com
```

**Configure the tunnel:**

```sh
cp cloudflared.yml.example ~/.cloudflared/config.yml
```

Edit `~/.cloudflared/config.yml` — fill in your `<tunnel-id>`, credentials path, and hostname:

```yaml
tunnel: <tunnel-id>
credentials-file: /home/<your-user>/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: app.yourdomain.com
    service: http://localhost:3000   # all routes: /webhook, /app, /feeds, …
  - service: http_status:404
```

A single hostname routes everything — `/webhook` for Telegram's push updates and `/app` (plus all API routes) for the Mini App WebView. Update `.env`:

```env
WEBHOOK_URL=https://app.yourdomain.com/webhook
BASE_URL=https://app.yourdomain.com
```

**Development workflow:**

```sh
# Terminal 1 — start tunnel
cloudflared tunnel run buzz-bot

# Terminal 2 — start app
crystal run src/buzz_bot.cr
```

The app registers the webhook automatically on startup, so no manual `setWebhook` call is needed.

### One-command launcher: devrun.sh

`devrun.sh` starts the tunnel and the app together, handling URL capture and `.env` patching automatically. Ctrl+C stops both.

```sh
chmod +x devrun.sh

./devrun.sh           # auto-detects mode: named if ~/.cloudflared/config.yml exists, quick otherwise
./devrun.sh --quick   # force quick tunnel (temporary URL, no account needed)
./devrun.sh --named   # force named tunnel (requires ~/.cloudflared/config.yml)
```

**Quick tunnel flow** — the script:
1. Starts `cloudflared tunnel --url http://localhost:3000` in the background
2. Waits up to 30 seconds for the `trycloudflare.com` URL to appear in cloudflared's output
3. Patches `WEBHOOK_URL` and `BASE_URL` in `.env` with the new URL
4. Starts `crystal run src/buzz_bot.cr`, which registers the webhook using the updated URL

**Named tunnel flow** — the script starts `cloudflared tunnel run` (reads `~/.cloudflared/config.yml` automatically), waits 3 seconds for it to connect, then starts the app. The URL in `.env` is already stable so no patching is needed.

---

## Project Structure

```
buzz-bot/
├── migrations/
│   └── 001_initial.sql        # Full schema
├── public/
│   ├── css/app.css            # Telegram-themed styles
│   └── js/app.js              # WebApp SDK init, HTMX config, audio player
├── src/
│   ├── buzz_bot.cr            # Entry point
│   ├── config.cr              # ENV accessors
│   ├── db.cr                  # DB pool singleton (AppDB)
│   ├── bot/
│   │   ├── client.cr          # Tourmaline client + webhook registration
│   │   └── handlers.cr        # /start, /help, callback handlers
│   ├── models/
│   │   ├── user.cr
│   │   ├── feed.cr
│   │   ├── episode.cr
│   │   └── user_episode.cr
│   ├── rss/
│   │   └── parser.cr          # RSS and OPML parsing
│   ├── views/                 # ECR templates (HTMX fragments)
│   └── web/
│       ├── auth.cr            # initData HMAC-SHA256 validation
│       ├── server.cr          # Kemal setup
│       └── routes/
│           ├── webhook.cr     # POST /webhook
│           ├── app.cr         # GET /app (Mini App shell)
│           ├── feeds.cr       # Feed CRUD
│           ├── episodes.cr    # Episode list, player, progress, signals
│           └── recommendations.cr
├── .env.example
├── cloudflared.yml.example    # Cloudflare Tunnel config template
├── devrun.sh                  # One-command local dev launcher
├── Dockerfile
├── docker-compose.yml
└── shard.yml
```

---

## API Routes

| Method | Path | Description |
|---|---|---|
| `POST` | `/webhook` | Telegram update receiver |
| `GET` | `/app` | Mini App HTML shell |
| `GET` | `/feeds` | List subscribed feeds (HTMX) |
| `POST` | `/feeds` | Subscribe by RSS URL |
| `POST` | `/feeds/opml` | Bulk-import from OPML file |
| `DELETE` | `/feeds/:id` | Unsubscribe |
| `GET` | `/episodes?feed_id=X` | Episode list for a feed (HTMX) |
| `GET` | `/episodes/:id/player` | Audio player fragment (HTMX) |
| `PUT` | `/episodes/:id/progress` | Save playback position |
| `PUT` | `/episodes/:id/signal` | Save like / dislike |
| `GET` | `/recommendations` | Recommended episodes (HTMX) |

All Mini App routes authenticate via the `X-Init-Data` request header (Telegram `initData` string).

---

## Database ERD

```
┌─────────────────────────┐
│          users          │
├─────────────────────────┤
│ id          BIGSERIAL PK│
│ telegram_id BIGINT  UQ  │
│ username    VARCHAR      │
│ first_name  VARCHAR      │
│ last_name   VARCHAR      │
│ created_at  TIMESTAMPTZ │
└────────────┬────────────┘
             │ 1
             │
             │ M
┌────────────▼────────────┐         ┌─────────────────────────┐
│       user_feeds        │         │          feeds           │
├─────────────────────────┤         ├─────────────────────────┤
│ user_id  BIGINT  FK(PK) │M──────1─│ id          BIGSERIAL PK│
│ feed_id  BIGINT  FK(PK) │         │ url         TEXT    UQ  │
│ created_at TIMESTAMPTZ  │         │ title       TEXT         │
└─────────────────────────┘         │ description TEXT         │
                                    │ image_url   TEXT         │
                                    │ last_fetched_at TSTZ     │
                                    │ created_at  TIMESTAMPTZ │
                                    └────────────┬────────────┘
                                                 │ 1
                                                 │
                                                 │ M
                                    ┌────────────▼────────────┐
                                    │        episodes          │
                                    ├─────────────────────────┤
                                    │ id          BIGSERIAL PK│
                                    │ feed_id     BIGINT  FK  │
                                    │ guid        TEXT    UQ  │
                                    │ title       TEXT    NN  │
                                    │ description TEXT         │
                                    │ audio_url   TEXT    NN  │
                                    │ duration_sec INT         │
                                    │ published_at TIMESTAMPTZ│
                                    │ created_at  TIMESTAMPTZ │
                                    └────────────┬────────────┘
                                                 │ 1
             ┌───────────────────────────────────┘
             │ M
┌────────────▼────────────┐
│      user_episodes      │
├─────────────────────────┤
│ id          BIGSERIAL PK│
│ user_id     BIGINT  FK  │◄──── FK → users.id
│ episode_id  BIGINT  FK  │◄──── FK → episodes.id
│ progress_seconds INT    │      UNIQUE(user_id, episode_id)
│ completed   BOOLEAN     │
│ liked       BOOLEAN NULL│      NULL = no signal
│ updated_at  TIMESTAMPTZ │      TRUE = liked
└─────────────────────────┘      FALSE = disliked
```

### Table summary

| Table | Purpose |
|---|---|
| `users` | One row per Telegram user; upserted on every `/start` |
| `feeds` | Shared podcast feed registry; deduplicated by URL |
| `user_feeds` | M:N join — which users subscribe to which feeds |
| `episodes` | Podcast episodes; deduplicated by RSS `<guid>` |
| `user_episodes` | Per-user playback state and like/dislike signal |

### Indices

```sql
CREATE INDEX ON user_feeds(user_id);
CREATE INDEX ON episodes(feed_id);
CREATE INDEX ON user_episodes(user_id);
CREATE INDEX ON user_episodes(episode_id);
CREATE INDEX ON user_episodes(liked) WHERE liked IS NOT NULL;  -- partial, for CF query
```

---

## How Recommendations Work

Recommendations use item-based collaborative filtering executed entirely in SQL:

1. Find all episodes the current user has **liked**
2. Find other users who also **liked** at least one of those episodes (similar users)
3. Collect all episodes those similar users have liked that the current user **has not seen**
4. Rank by how many similar users liked each candidate episode

No ML library required — the query runs in a single round-trip to PostgreSQL.

---

## License

MIT
