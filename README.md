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
| Deployment | Docker · k3s on Hetzner (via [hetzner-k3s](https://github.com/vitobotta/hetzner-k3s)) |

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
| `TELEGRAM_API_SERVER` | *(optional)* Self-hosted Bot API server URL (e.g. `http://telegram-bot-api:8081/`). Omit to use `api.telegram.org`. Required for >50 MB file transfers. |

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

### 4b. Run with Docker (single server)

```sh
docker compose up -d
```

The image is built in two stages: a Crystal/Alpine builder compiles a fully static binary, which is then copied into a minimal Alpine runtime image.

---

## Kubernetes Deployment (k3s on Hetzner)

A single `cpx11` node (2 vCPU, 2 GB RAM, ~€4/mo) is enough for the bot. The setup uses:

- **[hetzner-k3s](https://github.com/vitobotta/hetzner-k3s)** to provision a k3s cluster on Hetzner Cloud
- **Traefik** (built into k3s) as the ingress controller
- **cert-manager** for automatic Let's Encrypt TLS
- **aiogram/telegram-bot-api** as a self-hosted Bot API server (optional, enables >50 MB file transfers)

### 1. Install hetzner-k3s

The binary is statically linked and runs on NixOS without any `nix-shell` wrapper:

```sh
curl -L https://github.com/vitobotta/hetzner-k3s/releases/download/v2.4.6/hetzner-k3s-linux-amd64 \
  -o ~/.local/bin/hetzner-k3s
chmod +x ~/.local/bin/hetzner-k3s
hetzner-k3s --version   # should print 2.4.6
```

### 2. Create the cluster

Edit `k8s/cluster.yaml` and fill in your Hetzner API token (create one at [console.hetzner.cloud](https://console.hetzner.cloud) → Security → API Tokens):

```yaml
hetzner_token: <YOUR_HETZNER_API_TOKEN>
```

Then create the cluster (takes ~3 minutes):

```sh
./k8s/hetzner-k3s.sh create --config k8s/cluster.yaml
```

> **NixOS note:** use `k8s/hetzner-k3s.sh` instead of `hetzner-k3s` directly. The wrapper sets `SSL_CERT_FILE` and `ZONEINFO` which the statically-compiled Crystal binary cannot locate on its own because NixOS doesn't follow standard FHS paths.

This creates a single `cpx11` node in Nuremberg (`nbg1`), installs k3s, and writes `k8s/kubeconfig`.

```sh
export KUBECONFIG=k8s/kubeconfig
kubectl get nodes   # should show one Ready node
```

### 3. Install cert-manager

cert-manager handles Let's Encrypt certificate issuance and renewal automatically:

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.0/cert-manager.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=120s
```

### 4. Create secrets

Copy the example and fill in real values:

```sh
cp k8s/secret.example.yaml k8s/secret.yaml
```

Edit `k8s/secret.yaml`:

```yaml
stringData:
  BOT_TOKEN: "your-telegram-bot-token"
  WEBHOOK_URL: "http://buzz-bot:3000/webhook"   # internal cluster URL (plain HTTP is fine — stays inside the cluster)
  DATABASE_URL: "postgresql://user:pass@host/db?sslmode=require"
  PORT: "3000"
  BASE_URL: "https://app.yourdomain.com"
  TELEGRAM_API_SERVER: "http://telegram-bot-api:8081/"   # remove if not using local bot API server
```

Edit `k8s/cert-issuer.yaml` and replace `<YOUR_EMAIL>` with your Let's Encrypt registration email.

### 5. Point DNS to the node

Find the node's public IP:

```sh
kubectl get nodes -o wide
# NAME           STATUS   ...  EXTERNAL-IP
# buzz-bot-...   Ready    ...  65.21.x.x
```

In your DNS provider, set:

```
app.yourdomain.com  A  65.21.x.x
```

Use a short TTL (60 s) so the change propagates quickly. cert-manager needs this record to be live before it can issue a certificate — it proves domain ownership by serving a challenge token via Traefik on port 80.

### 6. Deploy the app

```sh
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/cert-issuer.yaml
kubectl apply -f k8s/deployment.yaml k8s/service.yaml k8s/ingress.yaml
```

Build and push the image, then roll it out:

```sh
# Authenticate with GitHub Container Registry once
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

./k8s/deploy.sh        # builds ghcr.io/watchcat/buzz-bot:<git-sha>, pushes, rolls out
```

cert-manager issues the TLS certificate automatically within ~30 seconds of DNS propagating.

### 7. Verify

```sh
kubectl get pods -n buzz-bot        # buzz-bot pod should be Running
kubectl logs -n buzz-bot deploy/buzz-bot -f   # should show "Webhook registered"
curl https://app.yourdomain.com/    # should return HTTP 200
```

### Day-2 operations

```sh
# Redeploy after code changes
./k8s/deploy.sh

# View live logs
kubectl logs -n buzz-bot deploy/buzz-bot -f

# Apply updated secret (e.g. after rotating BOT_TOKEN)
kubectl apply -f k8s/secret.yaml
kubectl rollout restart deployment/buzz-bot -n buzz-bot

# Delete the cluster entirely
./k8s/hetzner-k3s.sh delete --config k8s/cluster.yaml
```

---

## Self-hosted Telegram Bot API Server

By default bots are limited to 50 MB for file uploads/downloads. Running a local [Telegram Bot API server](https://github.com/tdlib/telegram-bot-api) inside the cluster removes this limit (up to 2 GB).

### How it works

```
Telegram ◄──outbound──► telegram-bot-api pod (port 8081, ClusterIP)
                                │
                  forwards updates via HTTP
                                │
                                ▼
                         buzz-bot :3000/webhook   (internal cluster DNS)
```

The bot API server is not publicly exposed — it communicates outbound to Telegram and inbound to `buzz-bot` entirely within the cluster. `WEBHOOK_URL` uses the internal service name (`http://buzz-bot:3000/webhook`) because the local bot API server allows plain HTTP in `--local` mode.

### Get API credentials

Go to [my.telegram.org](https://my.telegram.org) → *API development tools* and create an application. You need the **App api_id** and **App api_hash** — these are separate from the bot token.

### Deploy

```sh
cp k8s/tg-api-secret.example.yaml k8s/tg-api-secret.yaml
# Edit k8s/tg-api-secret.yaml — fill in TELEGRAM_API_ID and TELEGRAM_API_HASH

kubectl apply -f k8s/tg-api-secret.yaml
kubectl apply -f k8s/tg-api-pvc.yaml
kubectl apply -f k8s/tg-api-deployment.yaml
kubectl apply -f k8s/tg-api-service.yaml
```

### Migrate the bot from api.telegram.org (one-time)

The bot must log out of the official API before the local server can take over:

```sh
curl "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/logOut"
# {"ok":true,"result":true}
```

Then redeploy `buzz-bot` with the updated secret (which sets `TELEGRAM_API_SERVER` and the internal `WEBHOOK_URL`):

```sh
kubectl apply -f k8s/secret.yaml
kubectl rollout restart deployment/buzz-bot -n buzz-bot
```

The local bot API server registers the webhook with Telegram automatically on startup.

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
├── k8s/
│   ├── cluster.yaml               # hetzner-k3s cluster config (1× cpx11, nbg1)
│   ├── namespace.yaml
│   ├── secret.example.yaml        # env-var Secret template (committed)
│   ├── secret.yaml                # real credentials (gitignored)
│   ├── deployment.yaml            # buzz-bot Deployment
│   ├── service.yaml               # ClusterIP :3000
│   ├── ingress.yaml               # Traefik ingress + TLS for app.yourdomain.com
│   ├── cert-issuer.yaml           # Let's Encrypt ClusterIssuer
│   ├── tg-api-secret.example.yaml # Bot API server credentials template
│   ├── tg-api-pvc.yaml            # 10 Gi PVC for bot API file cache
│   ├── tg-api-deployment.yaml     # aiogram/telegram-bot-api (--local mode)
│   ├── tg-api-service.yaml        # ClusterIP :8081 (internal only)
│   └── deploy.sh                  # build → push → kubectl rollout
├── migrations/
│   └── 001_initial.sql            # Full schema
├── public/
│   ├── css/app.css                # Telegram-themed styles
│   └── js/app.js                  # WebApp SDK init, HTMX config, audio player
├── src/
│   ├── buzz_bot.cr                # Entry point
│   ├── config.cr                  # ENV accessors
│   ├── db.cr                      # DB pool singleton (AppDB)
│   ├── bot/
│   │   ├── client.cr              # Tourmaline client + webhook registration
│   │   └── handlers.cr            # /start, /help, callback handlers
│   ├── models/
│   │   ├── user.cr
│   │   ├── feed.cr
│   │   ├── episode.cr
│   │   └── user_episode.cr
│   ├── rss/
│   │   └── parser.cr              # RSS and OPML parsing
│   ├── views/                     # ECR templates (HTMX fragments)
│   └── web/
│       ├── auth.cr                # initData HMAC-SHA256 validation
│       ├── server.cr              # Kemal setup
│       └── routes/
│           ├── webhook.cr         # POST /webhook
│           ├── app.cr             # GET /app (Mini App shell)
│           ├── feeds.cr           # Feed CRUD
│           ├── episodes.cr        # Episode list, player, progress, signals
│           └── recommendations.cr
├── .env.example
├── cloudflared.yml.example        # Cloudflare Tunnel config template
├── devrun.sh                      # One-command local dev launcher
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
