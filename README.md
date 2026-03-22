# Buzz-Bot

A Telegram bot and Mini App for podcast listening. Subscribe to RSS feeds, track your listening progress, and discover new episodes through collaborative filtering recommendations.

## Features

- **RSS subscriptions** — add any podcast by RSS URL; bulk-import via OPML
- **Podcast search** — search by name via the Apple Podcasts directory and subscribe in one tap
- **Episode inbox** — unified feed of unheard episodes across all subscriptions, with "hide listened" and compact grouping filters
- **Bookmarks** — bookmark episodes with a single tap; search your saved episodes
- **Episode player** — native audio playback inside Telegram with resume-from-position, variable speed (1×/1.5×/2×), and ±15/30 s skip
- **Autoplay** — automatically advance to the next episode in a feed when one finishes
- **Progress tracking** — listening position saved automatically every 5 seconds; offline saves queued and replayed on reconnect
- **Offline caching** — episode audio is progressively downloaded and cached; the player switches to the local copy after 5 minutes of buffering ahead, enabling interrupted listening
- **Collaborative filtering recommendations** — surface episodes liked by users with similar taste
- **Share & send** — share any episode via Telegram's share sheet, or send the audio file directly to your own Telegram chat (premium)
- **Telegram-native UI** — adapts to the user's Telegram theme (dark/light, accent colours); persistent mini-player stays visible while browsing

## Tech Stack

| Layer | Technology |
|---|---|
| Language | [Crystal](https://crystal-lang.org/) >= 1.6 |
| Web server | [Kemal](https://kemalcr.com/) |
| Telegram bot | [Tourmaline](https://github.com/protoncr/tourmaline) |
| Database driver | [crystal-pg](https://github.com/will/crystal-pg) + [crystal-db](https://github.com/crystal-lang/crystal-db) |
| Database | PostgreSQL (tested with [Neon](https://neon.tech)) |
| Frontend | ClojureScript · [re-frame](https://github.com/day8/re-frame) · [Reagent](https://reagent-project.github.io/) |
| Frontend build | [shadow-cljs](https://github.com/thheller/shadow-cljs) |
| Service Worker | Custom SW for offline audio caching and offline write queue |
| Deployment | Docker · k3s on Hetzner (via [hetzner-k3s](https://github.com/vitobotta/hetzner-k3s)) |

---

## Installation

### Prerequisites

- Crystal >= 1.6 and `shards` (for local development)
- Node.js >= 18 and npm (to build the ClojureScript frontend)
- Docker and Docker Compose (for production)
- A PostgreSQL database (Neon free tier works)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- A public HTTPS URL pointing to your server (required for webhooks)

### 1. Clone and install dependencies

```sh
git clone https://github.com/yourname/buzz-bot.git
cd buzz-bot
shards install
npm install
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
| `TELEGRAM_API_SERVER` | *(optional)* Self-hosted Bot API server URL (e.g. `http://telegram-bot-api:8081/`). Omit to use `api.telegram.org`. Required for >50 MB file transfers. |

### 3. Run the database migrations

If you have `psql` available:

```sh
psql "$DATABASE_URL" -f migrations/001_initial.sql
psql "$DATABASE_URL" -f migrations/002_feed_refresh.sql
psql "$DATABASE_URL" -f migrations/003_guid_per_feed.sql
psql "$DATABASE_URL" -f migrations/004_subscriptions.sql
```

Or use the included Crystal migration runner (no `psql` required — uses the same DB driver as the app):

```sh
crystal run migrate.cr
```

### 4. Build the frontend

```sh
# Development — fast incremental builds with live reloading
npx shadow-cljs watch app

# Production — minified output (also run by the Dockerfile)
npx shadow-cljs release app
```

The compiled output lands in `public/js/main.js`.

### 5a. Run locally

Both the Telegram webhook and the Mini App require a public HTTPS URL — Telegram's servers push updates to `/webhook`, and Telegram's WebView refuses to load `http://` Mini App links. Use Cloudflare Tunnel to expose your local server for both — see [Local Development with Cloudflare Tunnel](#local-development-with-cloudflare-tunnel) below.

```sh
crystal run src/buzz_bot.cr
```

On startup the bot automatically calls `setWebhook` to register `WEBHOOK_URL` with Telegram.

### 5b. Run with Docker (single server)

```sh
docker compose up -d
```

The image is built in two stages: a Crystal/Alpine builder compiles a fully static binary and runs `npx shadow-cljs release app`; the output is copied into a minimal Alpine runtime image.

---

## Kubernetes Deployment (k3s on Hetzner)

A single `cpx11` node (2 vCPU, 2 GB RAM, ~€4/mo) is enough for the bot. The setup uses:

- **[hetzner-k3s](https://github.com/vitobotta/hetzner-k3s)** to provision a k3s cluster on Hetzner Cloud
- **Traefik** (built into k3s) as the ingress controller
- **cert-manager** for automatic Let's Encrypt TLS
- **aiogram/telegram-bot-api** as a self-hosted Bot API server (optional, enables >50 MB file transfers)

### 1. Install hetzner-k3s

```sh
curl -L https://github.com/vitobotta/hetzner-k3s/releases/download/v2.4.6/hetzner-k3s-linux-amd64 \
  -o ~/.local/bin/hetzner-k3s
chmod +x ~/.local/bin/hetzner-k3s
hetzner-k3s --version   # should print 2.4.6
```

> **NixOS note:** use `k8s/hetzner-k3s.sh` instead of `hetzner-k3s` directly. The wrapper sets `SSL_CERT_FILE` and `ZONEINFO` which the statically-compiled binary cannot locate on NixOS.

### 2. Create the cluster

Edit `k8s/cluster.yaml` and fill in your Hetzner API token, then:

```sh
./k8s/hetzner-k3s.sh create --config k8s/cluster.yaml
export KUBECONFIG=k8s/kubeconfig
kubectl get nodes   # should show one Ready node
```

### 3. Install cert-manager

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.0/cert-manager.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=120s
```

### 4. Create secrets

```sh
cp k8s/secret.example.yaml k8s/secret.yaml
# Edit k8s/secret.yaml — fill in BOT_TOKEN, DATABASE_URL, BASE_URL, etc.

cp k8s/cert-issuer.yaml k8s/cert-issuer.yaml
# Replace <YOUR_EMAIL> with your Let's Encrypt registration email
```

### 5. Point DNS to the node

```sh
kubectl get nodes -o wide   # note EXTERNAL-IP
# Set an A record: app.yourdomain.com → <EXTERNAL-IP>
```

### 6. Deploy

```sh
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/cert-issuer.yaml
kubectl apply -f k8s/deployment.yaml k8s/service.yaml k8s/ingress.yaml
./k8s/deploy.sh   # builds image, transfers to node, rolls out
```

### 7. Verify

```sh
kubectl get pods -n buzz-bot
kubectl logs -n buzz-bot deploy/buzz-bot -f   # should show "Webhook registered"
curl https://app.yourdomain.com/              # should return HTTP 200
```

### Day-2 operations

```sh
./k8s/deploy.sh                              # redeploy after code changes
kubectl logs -n buzz-bot deploy/buzz-bot -f  # live logs
./k8s/hetzner-k3s.sh delete --config k8s/cluster.yaml  # tear down cluster
```

---

## Self-hosted Telegram Bot API Server

By default bots are limited to 50 MB for file uploads/downloads. Running a local [Telegram Bot API server](https://github.com/tdlib/telegram-bot-api) inside the cluster removes this limit (up to 2 GB).

### Deploy

```sh
cp k8s/tg-api-secret.example.yaml k8s/tg-api-secret.yaml
# Edit — fill in TELEGRAM_API_ID and TELEGRAM_API_HASH from my.telegram.org

kubectl apply -f k8s/tg-api-secret.yaml
kubectl apply -f k8s/tg-api-pvc.yaml
kubectl apply -f k8s/tg-api-deployment.yaml
kubectl apply -f k8s/tg-api-service.yaml
```

### One-time migration from api.telegram.org

```sh
curl "https://api.telegram.org/bot<TOKEN>/logOut"
# {"ok":true,"result":true}
```

Then redeploy `buzz-bot` with `TELEGRAM_API_SERVER` set in the secret.

---

## Local Development with Cloudflare Tunnel

Running the Mini App locally requires a public HTTPS URL for two reasons:

1. **Telegram webhooks** — Telegram pushes updates to `/webhook` over HTTPS from the internet.
2. **Mini App serving** — Telegram's WebView refuses `http://` URLs.

[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) (`cloudflared`) handles both without port forwarding or self-signed certificates.

```
Telegram servers  ──► https://your-tunnel.com/webhook   (bot updates)
Telegram WebView  ──► https://your-tunnel.com/app        (Mini App)
                               │ Cloudflare Tunnel
                               ▼
                     localhost:3000   (Kemal — all routes)
```

### Quick tunnel (no account needed)

```sh
cloudflared tunnel --url http://localhost:3000
```

Update `.env` with the printed URL:

```env
WEBHOOK_URL=https://random-words.trycloudflare.com/webhook
BASE_URL=https://random-words.trycloudflare.com
```

> The URL changes on every restart. The app re-registers the webhook on startup automatically, so just restart the app after restarting the tunnel.

### One-command launcher

`devrun.sh` starts the tunnel and the app together, handling URL patching automatically:

```sh
./devrun.sh           # auto-detects: named tunnel if ~/.cloudflared/config.yml exists
./devrun.sh --quick   # force quick tunnel (temporary URL, no account needed)
./devrun.sh --named   # force named tunnel (requires ~/.cloudflared/config.yml)
```

**Recommended development workflow:**

```sh
# Terminal 1 — ClojureScript watch build (fast incremental)
npx shadow-cljs watch app

# Terminal 2 — tunnel + Crystal server
./devrun.sh
```

The shadow-cljs dev server is not required — Kemal serves `public/js/main.js` directly. Changes to ClojureScript files are picked up by the watch build and a browser refresh loads them.

---

## Project Structure

```
buzz-bot/
├── k8s/                           # Kubernetes manifests and deploy script
│   ├── cluster.yaml               # hetzner-k3s cluster config (1× cpx11, nbg1)
│   ├── deploy.sh                  # build image → transfer to node → kubectl rollout
│   ├── namespace.yaml
│   ├── secret.example.yaml        # env-var Secret template
│   ├── deployment.yaml / service.yaml / ingress.yaml / cert-issuer.yaml
│   ├── tg-api-*.yaml              # optional self-hosted Bot API server
│   └── ...
├── migrations/
│   ├── 001_initial.sql
│   ├── 002_feed_refresh.sql
│   ├── 003_guid_per_feed.sql
│   └── 004_subscriptions.sql
├── public/
│   ├── css/app.css                # Telegram-themed styles (dark/light, CSS variables)
│   ├── js/
│   │   ├── main.js                # Compiled ClojureScript SPA (shadow-cljs output)
│   │   └── telegram-web-app.js    # Vendored Telegram WebApp SDK
│   └── sw.js                      # Service Worker — offline audio cache + write queue
├── src/
│   ├── buzz_bot.cr                # Entry point — starts Kemal + registers webhook
│   ├── config.cr                  # ENV accessors
│   ├── db.cr                      # DB pool singleton (AppDB)
│   ├── feed_refresher.cr          # Background RSS refresh on feed load
│   ├── bot/
│   │   ├── audio_sender.cr        # Sends episode audio to user's Telegram chat
│   │   ├── client.cr              # Tourmaline client + webhook registration
│   │   └── handlers.cr            # /start, /help, callback handlers
│   ├── cljs/buzz_bot/             # ClojureScript SPA
│   │   ├── core.cljs              # App entry point — reads initData, dispatches :init
│   │   ├── db.cljs                # re-frame initial app-db shape
│   │   ├── events.cljs            # All re-frame event handlers
│   │   ├── fx.cljs                # Custom effects: http-fetch, audio-cmd,
│   │   │                          #   copy-to-clipboard, open-telegram-link,
│   │   │                          #   scroll-to-episode
│   │   ├── subs.cljs              # re-frame subscriptions
│   │   ├── audio.cljs             # Singleton <audio> element outside React tree
│   │   └── views/
│   │       ├── layout.cljs        # App shell (tab bar, theme init, mini-player slot)
│   │       ├── inbox.cljs         # Inbox — all unheard episodes, compact mode
│   │       ├── feeds.cljs         # Feeds list + Apple Podcasts search
│   │       ├── episodes.cljs      # Episode list for a single feed
│   │       ├── bookmarks.cljs     # Bookmarked episodes with search
│   │       ├── player.cljs        # Full-screen player — controls, share, send, recs
│   │       └── miniplayer.cljs    # Persistent mini-player (shown on all non-player views)
│   ├── models/
│   │   ├── user.cr
│   │   ├── feed.cr
│   │   ├── episode.cr
│   │   └── user_episode.cr
│   ├── rss/
│   │   └── parser.cr              # RSS and OPML XML parsing
│   ├── views/                     # ECR templates (HTML shell only — no HTMX)
│   │   ├── layout.ecr             # <html> wrapper — injects BOT_USERNAME, theme vars
│   │   └── app.ecr                # SPA mount point (<div id="app">)
│   └── web/
│       ├── auth.cr                # initData HMAC-SHA256 validation
│       ├── assets.cr              # Static file helpers
│       ├── json_helpers.cr        # JSON serialisation structs
│       ├── sanitizer.cr           # HTML sanitiser for episode descriptions
│       ├── server.cr              # Kemal config, CORS, error handlers
│       └── routes/
│           ├── webhook.cr         # POST /webhook
│           ├── app.cr             # GET /app (SPA shell)
│           ├── feeds.cr           # Feed CRUD + subscribe
│           ├── episodes.cr        # Episodes, player data, progress, signals, audio proxy
│           ├── inbox.cr           # GET /inbox
│           ├── discover.cr        # GET /bookmarks, GET /bookmarks/search
│           ├── search.cr          # GET /search, POST /search/subscribe
│           └── recommendations.cr
├── shadow-cljs.edn                # ClojureScript build config
├── package.json                   # Node deps (shadow-cljs, reagent, re-frame)
├── .env.example
├── cloudflared.yml.example        # Named tunnel config template
├── devrun.sh                      # One-command local dev launcher
├── Dockerfile
├── docker-compose.yml
└── shard.yml
```

---

## API Routes

All Mini App routes authenticate via the `X-Init-Data` request header (Telegram `initData` HMAC-SHA256).

| Method | Path | Description |
|---|---|---|
| `POST` | `/webhook` | Telegram update receiver |
| `GET` | `/app` | SPA HTML shell |
| `GET` | `/inbox` | Unheard episodes across all subscriptions |
| `GET` | `/feeds` | List subscribed feeds |
| `POST` | `/feeds` | Subscribe by RSS URL |
| `POST` | `/feeds/opml` | Bulk-import from OPML file |
| `POST` | `/feeds/:id/subscribe` | Subscribe to a feed by id (used after search) |
| `DELETE` | `/feeds/:id` | Unsubscribe |
| `GET` | `/episodes?feed_id=X` | Episode list for a feed (`limit`, `offset`, `order` params) |
| `GET` | `/episodes/:id/player` | Player data — episode, feed, recs, next episode title |
| `PUT` | `/episodes/:id/progress` | Save playback position |
| `PUT` | `/episodes/:id/signal` | Toggle bookmark |
| `POST` | `/episodes/:id/send` | Send audio file to user's Telegram chat (premium; 402 otherwise) |
| `GET` | `/episodes/:id/audio_proxy` | Auth-gated streaming proxy with redirect following |
| `GET` | `/bookmarks` | Bookmarked episodes |
| `GET` | `/bookmarks/search?q=X` | Search bookmarked episodes |
| `GET` | `/search?q=X` | Search Apple Podcasts directory |
| `POST` | `/search/subscribe` | Subscribe to a result from podcast search |
| `GET` | `/recommendations` | Collaboratively filtered episode recommendations |

---

## Frontend Architecture

The frontend is a [re-frame](https://github.com/day8/re-frame) single-page app compiled by [shadow-cljs](https://github.com/thheller/shadow-cljs). There is no full-page navigation — all views are rendered client-side by swapping Reagent components.

```
core.cljs          ← mounts app, reads initData from DOM, dispatches :init
  └── layout.cljs  ← tab bar, Telegram theme colours, mini-player slot
        └── router ← dispatches to inbox / feeds / episodes / bookmarks / player
```

**State management** follows the standard re-frame pattern:

| File | Role |
|---|---|
| `db.cljs` | Defines the initial `app-db` shape |
| `events.cljs` | Pure event handlers (`reg-event-db` / `reg-event-fx`) |
| `fx.cljs` | Side-effecting handlers: `::http-fetch`, `::audio-cmd`, `::copy-to-clipboard`, `::open-telegram-link`, `::scroll-to-episode` |
| `subs.cljs` | Derived data subscriptions |
| `audio.cljs` | Singleton `<audio>` element outside the React tree — survives view changes |

**Key behaviours:**

- **Audio continuity** — the `<audio>` element is a `defonce` at the module level. Navigating between views never interrupts playback.
- **List state restoration** — before opening the player, the episode count is snapshotted. On return the same number of episodes is fetched in one request and the playing episode is scrolled into view and highlighted.
- **Offline write queue** — progress saves that fail offline are queued in IndexedDB by the Service Worker and replayed automatically on reconnect.
- **Progressive audio caching** — the Service Worker downloads episode audio in the background and the player switches to the local cached copy once 5 minutes are buffered ahead.

---

## Database Schema

```
users ──< user_feeds >── feeds ──< episodes ──< user_episodes >── users
```

| Table | Purpose |
|---|---|
| `users` | One row per Telegram user; upserted on every `/start` |
| `feeds` | Shared podcast feed registry; deduplicated by URL |
| `user_feeds` | M:N join — which users subscribe to which feeds |
| `episodes` | Podcast episodes; deduplicated by RSS `<guid>` per feed |
| `user_episodes` | Per-user playback state and bookmark signal |

Key columns: `user_episodes.liked` — `NULL` = no signal, `TRUE` = bookmarked (used for recommendations and the bookmark button).

---

## How Recommendations Work

Item-based collaborative filtering executed entirely in SQL:

1. Find all episodes the current user has **bookmarked**
2. Find other users who bookmarked at least one of those episodes
3. Collect episodes those users bookmarked that the current user has not seen
4. Rank by how many similar users bookmarked each candidate

No ML library required — the query runs in a single PostgreSQL round-trip.

---

## License

MIT
