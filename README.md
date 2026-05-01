# Buzz-Bot

**[Podcast player for the AI epoch.](https://youtu.be/7-CBlhAPGYs)**

<p float="left">
  <a href="https://youtu.be/7-CBlhAPGYs" target="_blank" rel="noopener noreferrer">
    <img width="280" src="./docs/pics/Image.png" style="float: left; margin-right: 20px; border-radius: 10px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);"/>
  </a>

  Listen to any podcast, then tap one button and hear it in your language — same voices, different words.

  Buzz-Bot runs inside Telegram as a Mini App and uses a cloud GPU pipeline (RunPod Serverless) to transcribe, translate, and re-synthesize every speaker's voice.

  To view AI pipeline for podcast dubbing workflow check this [repository](https://github.com/watchcat/dub-pipeline)
</p>

<br clear="left"/>

---

## Features

| Feature | Description |
|---------|-------------|
| RSS subscriptions | Add any podcast by RSS URL; bulk-import via OPML |
| Podcast search | Search Apple Podcasts directory and subscribe in one tap |
| Episode inbox | Unified feed of unheard episodes across all subscriptions, with "hide listened" and compact grouping filters |
| Episode player | Native audio playback inside Telegram with resume-from-position, variable speed (1x/1.5x/2x), skip, and a persistent mini-player |
| Autoplay | Automatically advance to the next episode when one finishes |
| Progress tracking | Listening position saved every 5 seconds; offline saves queued and replayed on reconnect |
| Offline caching | Episode audio downloaded in background; seamless switch to local copy on network loss |
| Bookmarks | Bookmark episodes with a single tap; search saved episodes |
| Collaborative filtering | Surface episodes liked by users with similar taste |
| Share & send | Share any episode via Telegram's share sheet, or send the audio file directly to your own chat |
| AI dubbing | Hear any podcast in your language with the original speaker's voice cloned — [details](docs/DUBBING.md) |
| Karaoke subtitles | Live subtitle panel with karaoke-style highlighting; fullscreen transcript; tap any line to seek |

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Language | [Crystal](https://crystal-lang.org/) >= 1.9 |
| Web server | [Kemal](https://kemalcr.com/) |
| Telegram bot | [Tourmaline](https://github.com/protoncr/tourmaline) |
| Database | PostgreSQL ([Neon](https://neon.tech)) via crystal-pg |
| Frontend | ClojureScript, [re-frame](https://github.com/day8/re-frame), [Reagent](https://reagent-project.github.io/) |
| Frontend build | [shadow-cljs](https://github.com/thheller/shadow-cljs) |
| Service Worker | Offline audio cache (Range-aware) + offline write queue |
| Job dispatch | [RunPod Serverless](https://www.runpod.io/serverless-gpu) API v2 |
| AI pipeline | Demucs, WhisperX, pyannote, Gemini Flash, VoxCPM2 — [details](docs/DUBBING.md) |
| Audio storage | [Cloudflare R2](https://developers.cloudflare.com/r2/) |
| Deployment | Docker, k3s on Hetzner — [details](docs/DEPLOYMENT.md) |
| Ingress / TLS | Traefik v3, cert-manager + Let's Encrypt |

---

## Quick Start

### Prerequisites

- Crystal >= 1.9 + `shards`
- Node.js >= 18 + npm
- Docker
- PostgreSQL (Neon free tier works)
- Telegram bot token from [@BotFather](https://t.me/BotFather)
- Public HTTPS URL for webhooks

### 1. Clone and install dependencies

```sh
git clone https://github.com/yourname/buzz-bot.git
cd buzz-bot
shards install
npm install
```

### 2. Configure environment

```sh
cp k8s/secret.example.yaml k8s/secret.yaml
# Fill in all values — see docs/DEPLOYMENT.md for variable reference
```

### 3. Run migrations

```sh
for f in migrations/*.sql; do psql "$DATABASE_URL" -f "$f"; done
```

### 4. Build frontend

```sh
# Development (live reload)
npx shadow-cljs watch app

# Production
npx shadow-cljs release app
```

### 5. Run locally

```sh
crystal run src/buzz_bot.cr
```

Use Cloudflare Tunnel to expose localhost over HTTPS for Telegram webhooks:

```sh
# Terminal 1 — ClojureScript watch build
npx shadow-cljs watch app

# Terminal 2 — tunnel + Crystal server
./devrun.sh           # auto-detects named tunnel or quick tunnel
./devrun.sh --quick   # temporary URL, no account needed
```

---

## Documentation

- [AI Dubbing Pipeline](docs/DUBBING.md) — how dubbing works, supported languages, progress tracking
- [Deployment Guide](docs/DEPLOYMENT.md) — k3s setup, environment variables, monitoring
- [API Reference](docs/API.md) — routes, database schema, feature flags

---

## License

MIT
