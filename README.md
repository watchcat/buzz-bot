# Buzz-Bot

A Telegram bot and Mini App for podcast listening. Subscribe to RSS feeds, track your listening progress, discover new episodes through collaborative filtering recommendations, and dub any episode into another language with AI voice cloning.

## Features

- **RSS subscriptions** — add any podcast by RSS URL; bulk-import via OPML
- **Podcast search** — search by name via the Apple Podcasts directory and subscribe in one tap
- **Episode inbox** — unified feed of unheard episodes across all subscriptions, with "hide listened" and compact grouping filters
- **Bookmarks** — bookmark episodes with a single tap; search your saved episodes
- **Episode player** — native audio playback inside Telegram with resume-from-position, variable speed (1×/1.5×/2×), and ±15/30 s skip
- **Autoplay** — automatically advance to the next episode in a feed when one finishes
- **Progress tracking** — listening position saved automatically every 5 seconds; offline saves queued and replayed on reconnect
- **Offline caching** — episode audio is fully downloaded and cached in the browser; the player seamlessly switches to the local copy once available, with stall/error recovery that falls back to the cached copy on network loss
- **Image proxy** — all external podcast artwork is routed through `/img-proxy` to satisfy Telegram's restrictive `img-src` CSP
- **Feature flags** — runtime toggleable switches stored in PostgreSQL; toggled via bot `/flag` command; consumed client-side without a page reload
- **Collaborative filtering recommendations** — surface episodes liked by users with similar taste
- **Share & send** — share any episode via Telegram's share sheet, or send the audio file directly to your own Telegram chat (premium)
- **Episode dubbing** — AI-powered dubbing into 15 languages: transcribe with Whisper, translate with DeepL, synthesize with XTTS-v2 voice cloning (premium)
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
| Speech-to-text | [Whisper large-v3](https://github.com/ggerganov/whisper.cpp) running locally via whisper-service (Apple M4 GPU) |
| Translation | [DeepL API](https://www.deepl.com/pro-api) |
| Text-to-speech | [lucataco/xtts-v2](https://replicate.com/lucataco/xtts-v2) via Replicate (voice cloning) |
| Dubbed audio storage | [Cloudflare R2](https://developers.cloudflare.com/r2/) |
| Deployment | Docker · k3s on Hetzner (via [hetzner-k3s](https://github.com/vitobotta/hetzner-k3s)) |

---

## Episode Dubbing

Dubbing converts any podcast episode into another language, preserving the original speaker's voice.

### Supported Languages

English · Spanish · French · German · Italian · Portuguese · Polish · Turkish · Russian · Dutch · Czech · Chinese · Japanese · Hungarian · Korean

### How It Works

```
User taps "🎙 Dub Episode"
         │
         ▼
   Language picker (remembers preference)
         │
         ▼
POST /episodes/:id/dub  ─────────────────────────────────────┐
         │                                                    │
         │  (async, server-side fiber)                        │
         ▼                                                    │
  1. Download full episode audio → upload to R2 temp         │
         │                                                    │
         ▼                                                    │
  2. Whisper large-v3 (Replicate)                            │
     speech-to-text → transcript                             │
     (cached on episodes.transcript — reused across langs)   │
         │                                                    │
         ▼                                                    │
  3. DeepL API                                               │
     translate transcript → target language                  │
         │                                                    │
         ▼                                                    │
  4. Download first 3 MB of episode → upload to R2 temp      │
     (voice sample for speaker cloning)                      │
         │                                                    │
         ▼                                                    │
  5. XTTS-v2 (Replicate)                                     │
     TTS with voice cloning → WAV → MP3 URL                  │
         │                                                    │
         ▼                                                    │
  6. Download MP3 → upload to R2  dubbed/:id/:lang.mp3       │
         │                                                    │
         └──────────────────────────────────────────────────►│
                                                             │
         ◄────────────────────────────────────────────────── │
         │  status: done / pending / failed                  │
         ▼
  Client receives dub progress via SSE (GET /episodes/:id/dub/:lang/stream)
         │
         ▼
  "▶ Play Dubbed" + "📨 Send Dubbed to Telegram"
  + collapsible translation text
```

### Data Model

| What | Where | Why |
|---|---|---|
| Transcript (Whisper output) | `episodes.transcript` | Language-independent — reused when the same episode is dubbed into multiple languages |
| Translation (DeepL output) | `dubbed_episodes.translation` | Language-specific |
| Dubbed MP3 | Cloudflare R2 `dubbed/:episode_id/:lang.mp3` | Expires after 29 days |
| Voice sample | Cloudflare R2 `tmp/voice/:dub_id.mp3` | Temp — 7-day lifecycle rule |
| Full audio temp | Cloudflare R2 `tmp/audio/:dub_id.mp3` | Temp — 7-day lifecycle rule |

### Retry Behaviour

A failed dub is retried from scratch on the next tap. `dubbed_episodes` resets to `pending` and a new fiber is spawned. The transcript cache means only the Whisper step is skipped on retry for the same episode.

### Dub Status Flow

```
pending → processing → done
                    ↘ failed → (retry) → pending → ...
                    ↘ expired
```

`expired` means the R2 file has been deleted by the lifecycle rule (29 days after creation). The UI shows "🎙 Dub Episode (expired)" which triggers a fresh dub.

---

## Feature Flags

Runtime toggleable switches stored in PostgreSQL and cached in memory. All flags default to `true` when undefined (safe-by-default).

| Flag | Default | Description |
|---|---|---|
| `offline_caching` | `true` | Download and cache episode audio for offline playback |
| `stall_recovery` | `true` | Auto-recover from network stalls and audio errors |
| `img_proxy` | `true` | Route external podcast artwork through `/img-proxy` |

### Toggle via bot command

```
/flag list              — show all flags and current values
/flag offline_caching off
/flag stall_recovery on
```

Only Telegram user IDs listed in `ADMIN_USER_IDS` can use `/flag`. Non-admins get a "permission denied" reply.

### How it works

- `FeatureFlags.setup!` runs `CREATE TABLE IF NOT EXISTS feature_flags` on startup — no migration file needed.
- Changes written by the bot command are effective immediately (in-memory cache updated).
- The client fetches `/flags` once on startup and stores values in `[:flags]` in app-db.

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
| `REPLICATE_API_TOKEN` | [Replicate](https://replicate.com) API token — required for dubbing |
| `DEEPL_API_KEY` | [DeepL](https://www.deepl.com/pro-api) API key — required for dubbing |
| `R2_ACCOUNT_ID` | Cloudflare account ID — required for dubbing |
| `R2_ACCESS_KEY_ID` | R2 API token key ID — required for dubbing |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret — required for dubbing |
| `R2_BUCKET` | R2 bucket name — required for dubbing |
| `R2_PUBLIC_URL` | Public URL of the R2 bucket (e.g. `https://pub-xxx.r2.dev`) — required for dubbing |
| `ADMIN_USER_IDS` | Comma-separated Telegram user IDs allowed to toggle feature flags (e.g. `123456789,987654321`) |
| `WHISPER_REDIS_URL` | Redis URL used by `dub-transcriber` to enqueue transcription jobs (e.g. `redis://default:pass@redis.whisper.svc.cluster.local:6379`) |
| `WHISPER_CALLBACK_BASE` | Base URL the whisper-worker posts results back to (e.g. `https://app.buzz-bot.top`) |
| `WHISPER_QUEUE_KEY` | Redis list key for the job queue (default: `whisper:jobs`) |

### 3. Run the database migrations

If you have `psql` available:

```sh
for f in migrations/*.sql; do psql "$DATABASE_URL" -f "$f"; done
```

Or use the included Crystal migration runner (no `psql` required):

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
# Edit k8s/secret.yaml — fill in BOT_TOKEN, DATABASE_URL, BASE_URL,
# REPLICATE_API_TOKEN, DEEPL_API_KEY, R2_* vars, etc.

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

### Monitoring

**Resource usage** (requires metrics-server — see below):

```sh
KUBECONFIG=k8s/kubeconfig kubectl top nodes
KUBECONFIG=k8s/kubeconfig kubectl top pods -A --sort-by=memory
```

**Interactive cluster dashboard** (k9s):

```sh
nix-shell -p k9s --run "KUBECONFIG=k8s/kubeconfig k9s"
```

Inside k9s: `:ns` to switch namespaces, `l` for logs, `d` for describe, `u` to see CPU/memory per pod.

**metrics-server** must be installed and imported manually (the node has no internet access):

```sh
# On your Mac — pull, save, and transfer the image
echo 'FROM registry.k8s.io/metrics-server/metrics-server:v0.8.1' | \
  docker build --platform linux/amd64 -t metrics-server:v0.8.1 -
docker save metrics-server:v0.8.1 | gzip > /tmp/metrics-server.tar.gz
scp /tmp/metrics-server.tar.gz root@<NODE-IP>:/tmp/

# On the node
k3s ctr --namespace k8s.io images import /tmp/metrics-server.tar.gz
k3s ctr --namespace k8s.io images tag \
  docker.io/library/metrics-server:v0.8.1 \
  registry.k8s.io/metrics-server/metrics-server:v0.8.1

# Deploy metrics-server (k3s uses self-signed kubelet certs)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system \
  --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
       {"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]'
```

**Telegram alerts** — a cron job on the node fires every 30 minutes and sends a bot message when:

| Condition | Threshold | Message |
|---|---|---|
| RAM usage | > 80% | ⚠️ Consider upgrading |
| Disk usage | > 70% | ⚠️ Prune images or upgrade |
| OOM kills | Any in last hour | 🚨 Upgrade NOW |

The script lives at `/usr/local/bin/node-health-alert.sh` on the node, installed via `/etc/cron.d/node-health`.

**When to upgrade** (current node is cpx22: 2 vCPU, 4 GB RAM, 75 GB disk):

- RAM consistently >80% at idle — whisper dubbing jobs push memory up temporarily
- OOM kills — no swap means the kernel kills pods without warning
- CPU >80% sustained — audio proxy + dubbing pipeline compete for the 2 cores
- Disk >70% — containerd image cache grows over time; prune with `k3s ctr images rm` or upgrade to cpx32

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
│   ├── 004_subscriptions.sql
│   ├── 005_user_feed_order.sql
│   ├── 006_episode_image_url.sql
│   ├── 007_dubbed_episodes.sql    # dubbed_episodes table
│   └── 008_dub_text_fields.sql    # episodes.transcript, dubbed_episodes.translation
├── public/
│   ├── css/app.css                # Telegram-themed styles (dark/light, CSS variables)
│   ├── js/
│   │   ├── main.js                # Compiled ClojureScript SPA (shadow-cljs output)
│   │   └── telegram-web-app.js    # Vendored Telegram WebApp SDK
│   └── sw.js                      # Service Worker — offline audio cache + write queue
├── src/
│   ├── buzz_bot.cr                # Entry point — starts Kemal + registers webhook
│   ├── config.cr                  # ENV accessors (incl. admin_user_ids)
│   ├── db.cr                      # DB pool singleton (AppDB)
│   ├── feature_flags.cr           # DB-backed runtime feature flags with in-memory cache
│   ├── feed_refresher.cr          # Background RSS refresh on feed load
│   ├── bot/
│   │   ├── audio_sender.cr        # Sends episode audio to user's Telegram chat
│   │   ├── client.cr              # Tourmaline client + webhook registration
│   │   └── handlers.cr            # /start, /help, callback handlers
│   ├── cljs/buzz_bot/             # ClojureScript SPA
│   │   ├── core.cljs              # App entry point — reads initData, dispatches :init
│   │   ├── db.cljs                # re-frame initial app-db shape (incl. :flags {})
│   │   ├── events.cljs            # re-frame event handlers (player, nav, feeds, inbox, flags)
│   │   ├── events/
│   │   │   └── dub.cljs           # Dub events: request, SSE stream, send, language picker
│   │   ├── fx.cljs                # Custom effects: http-fetch, audio-cmd,
│   │   │                          #   copy-to-clipboard, open-telegram-link, poll-after
│   │   │                          #   audio-cache-store (SW caching with Range support)
│   │   ├── subs.cljs              # re-frame subscriptions (incl. ::flag parameterized sub)
│   │   ├── subs/
│   │   │   └── dub.cljs           # Dub subscriptions: status, r2-url, translation, etc.
│   │   ├── audio.cljs             # Singleton <audio> element outside React tree
│   │   │                          #   stall/error recovery, Media Session API
│   │   └── views/
│   │       ├── layout.cljs        # App shell (tab bar, theme init, mini-player slot)
│   │       ├── inbox.cljs         # Inbox — all unheard episodes, compact mode
│   │       ├── feeds.cljs         # Feeds list + Apple Podcasts search
│   │       ├── episodes.cljs      # Episode list for a single feed
│   │       ├── bookmarks.cljs     # Bookmarked episodes with search
│   │       ├── player.cljs        # Full-screen player — controls, share, send, dub panel
│   │       ├── miniplayer.cljs    # Persistent mini-player (shown on all non-player views)
│   │       ├── utils.cljs         # Shared helpers: img-proxy URL wrapper
│   │       └── dub.cljs           # Dub panel + language picker component
│   ├── dub/
│   │   ├── dub_job.cr             # Async pipeline: download → Whisper → DeepL → XTTS-v2 → R2
│   │   ├── replicate_client.cr    # Replicate API: submit prediction, poll, return output
│   │   ├── deepl_client.cr        # DeepL translation API
│   │   └── r2_storage.cr          # Cloudflare R2 PUT via AWS Signature v4
│   ├── models/
│   │   ├── user.cr
│   │   ├── feed.cr
│   │   ├── episode.cr             # includes transcript() / save_transcript()
│   │   ├── user_episode.cr
│   │   └── dubbed_episode.cr      # status machine + r2_url + translation
│   ├── rss/
│   │   └── parser.cr              # RSS and OPML XML parsing
│   ├── views/                     # ECR templates (HTML shell only)
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
│           ├── dub.cr             # POST /episodes/:id/dub, GET /episodes/:id/dub/:lang + SSE stream
│           ├── flags.cr           # GET /flags (admin-only feature flag state)
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
| `GET` | `/episodes/:id/player` | Player data — episode, feed, recs, next episode, preferred dub language |
| `PUT` | `/episodes/:id/progress` | Save playback position |
| `PUT` | `/episodes/:id/signal` | Toggle bookmark |
| `POST` | `/episodes/:id/send` | Send audio file to user's Telegram chat (premium; `dubbed=true&language=es` for dubbed) |
| `GET` | `/episodes/:id/audio` | Serve cached episode audio (auth-gated, streams from DB-cached blob) |
| `GET` | `/episodes/:id/audio_proxy` | Auth-gated streaming proxy — follows redirects, flushes headers before CDN connection |
| `POST` | `/episodes/:id/dub` | Start or retry a dub job `{language: "es"}` — returns status immediately, job runs async |
| `GET` | `/episodes/:id/dub/:lang` | Poll dub status — returns `{status, r2_url?, translation?}` |
| `GET` | `/episodes/:id/dub/:lang/stream` | SSE stream for real-time dub progress updates |
| `PUT` | `/user/dub_language` | Save the user's preferred dub language |
| `GET` | `/img-proxy?url=` | HTTPS image proxy — routes external artwork through own origin to satisfy Telegram CSP |
| `GET` | `/flags` | Current feature flag state (admin-only — non-admins get 403 and client defaults all flags to `true`) |
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
| `events/dub.cljs` | Dub-specific events: language picker, request, poll, send to Telegram |
| `fx.cljs` | Side-effecting handlers: `::http-fetch`, `::audio-cmd`, `::copy-to-clipboard`, `::open-telegram-link`, `::poll-after` |
| `subs.cljs` | Derived data subscriptions |
| `subs/dub.cljs` | Dub state subscriptions: status, r2-url, translation, error, language |
| `audio.cljs` | Singleton `<audio>` element outside the React tree — survives view changes |

**Key behaviours:**

- **Audio continuity** — the `<audio>` element is a `defonce` at the module level. Navigating between views never interrupts playback.
- **Offline write queue** — progress saves that fail offline are queued in IndexedDB by the Service Worker and replayed automatically on reconnect.
- **Full audio caching** — episode audio is downloaded completely in the background via `fx.cljs`; the Service Worker stores it and handles `Range` requests (returning HTTP 206) so seeking works on cached audio. The player switches to the local copy via `:switch-src` once available.
- **Stall/error recovery** — `audio.cljs` listens for `waiting` and `error` events; after 5 s of stalling, it reloads from the cached copy (if available) or retries the stream URL, guarded by the `stall_recovery` feature flag.
- **Dub progress via SSE** — after requesting a dub, the client opens an SSE connection to `GET /episodes/:id/dub/:lang/stream`; the server pushes `step:` and `done:` / `failed:` events via PostgreSQL `NOTIFY` so no polling loop is needed.
- **Feature flags** — fetched once on startup from `GET /flags`; stored in `[:flags]` in app-db; read via the `::flag` subscription or directly from `@re-frame.db/app-db` in non-reactive contexts (`audio.cljs`). All flags default to `true` when the endpoint is unreachable.
- **Image proxy** — all external artwork URLs are wrapped through `views/utils/img-proxy` before rendering, routing them through `/img-proxy` to satisfy Telegram's restrictive `img-src` CSP.

---

## Database Schema

```
users ──< user_feeds >── feeds ──< episodes ──< user_episodes >── users
                                       │
                                       └──< dubbed_episodes
```

| Table | Purpose |
|---|---|
| `users` | One row per Telegram user; upserted on every `/start` |
| `feeds` | Shared podcast feed registry; deduplicated by URL |
| `user_feeds` | M:N join — which users subscribe to which feeds |
| `episodes` | Podcast episodes; deduplicated by RSS `<guid>` per feed; `transcript` column caches Whisper output |
| `user_episodes` | Per-user playback state and bookmark signal |
| `dubbed_episodes` | One row per (episode, language) — status machine, R2 URL, translation text, expiry |

Key columns:
- `user_episodes.liked` — `NULL` = no signal, `TRUE` = bookmarked (used for recommendations and the bookmark button)
- `episodes.transcript` — Whisper output, shared across all dub languages for the same episode
- `dubbed_episodes.translation` — DeepL output for this specific language
- `dubbed_episodes.expires_at` — set to `NOW() + 29 days` when status becomes `done`; the UI shows "Dub Episode (expired)" once the R2 file is gone

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
