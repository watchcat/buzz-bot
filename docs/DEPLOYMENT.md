# Deployment Guide

## Environment Variables

### buzz-bot (k8s secret `buzz-bot-env`)

| Variable | Description |
|----------|-------------|
| `BOT_TOKEN` | Token from [@BotFather](https://t.me/BotFather) |
| `WEBHOOK_URL` | Full public URL to `/webhook` |
| `DATABASE_URL` | PostgreSQL connection string |
| `PORT` | Port Kemal listens on (default: `3000`) |
| `BASE_URL` | Public base URL — used for the Mini App button |
| `TELEGRAM_API_SERVER` | *(optional)* Self-hosted Bot API URL (enables >50 MB file transfers) |
| `ADMIN_USER_IDS` | Comma-separated Telegram user IDs for `/flag` command |
| `RUNPOD_API_KEY` | RunPod API key for dispatching dub jobs |
| `RUNPOD_ENDPOINT_ID` | RunPod Serverless endpoint ID (dub-pipeline) |
| `DUB_CALLBACK_BASE` | Base URL RunPod posts results back to (e.g. `https://app.buzz-bot.top`) |

### dub-pipeline (RunPod environment variables)

Set these in the RunPod serverless endpoint configuration.

| Variable | Description |
|----------|-------------|
| `PROGRESS_URL` | `https://app.buzz-bot.top/internal/dub_progress` |
| `R2_ENDPOINT` | Cloudflare R2 S3-compatible endpoint |
| `R2_ACCESS_KEY_ID` | R2 API token key ID |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_BUCKET` | R2 bucket name |
| `R2_PUBLIC_URL` | Public R2 URL (e.g. `https://pub-xxx.r2.dev`) |
| `GEMINI_API_KEY` | Google Gemini API key (translation) |
| `HF_TOKEN` | HuggingFace token — required for pyannote models |
| `DEMUCS_MODEL` | `htdemucs_ft` |
| `WHISPER_MODEL` | `large-v3` |
| `BG_VOLUME_DEFAULT` | Background music volume (default: `0.15`) |

---

## Kubernetes Deployment (k3s on Hetzner)

A single `cpx22` node (2 vCPU, 4 GB RAM, ~7 EUR/mo) runs the full stack.

### 1. Install tools

```sh
# hetzner-k3s (macOS ARM64)
curl -L https://github.com/vitobotta/hetzner-k3s/releases/download/v2.4.7/hetzner-k3s-macos-arm64 \
  -o /usr/local/bin/hetzner-k3s && chmod +x /usr/local/bin/hetzner-k3s

# helm (via Nix)
nix-shell   # shell.nix includes kubernetes-helm
```

> **Nix note:** `k8s/hetzner-k3s.sh` wraps the binary with `SSL_CERT_FILE` and `ZONEINFO` — required on NixOS and Nix on macOS since the statically-compiled Crystal binary can't find system paths.

### 2. Configure cluster token

Add `HETZNER_TOKEN=<your-token>` to `.env`. Never put the real token in `cluster.yaml` — it's committed with a placeholder.

### 3. Create the cluster

```sh
nix-shell --run './k8s/cluster-apply.sh create'
export KUBECONFIG=k8s/kubeconfig
kubectl get nodes   # should show buzz-bot-master1 Ready
```

### 4. Preload images

k3s 1.32 + hetzner-k3s disables Traefik and ServiceLB; images must be pulled manually to avoid Docker Hub rate limits:

```sh
./k8s/preload-images.sh
```

This pulls all system images (pause, Traefik, cert-manager, Redis, Hetzner CCM/CSI, Telegram Bot API) and scales cluster-autoscaler to 0 (unused on single-node).

### 5. Install Traefik

```sh
nix-shell --run '
  export KUBECONFIG=k8s/kubeconfig
  helm install traefik traefik/traefik \
    --namespace kube-system \
    --set deployment.kind=DaemonSet \
    --set ports.web.port=80 --set ports.web.hostPort=80 \
    --set ports.websecure.port=443 --set ports.websecure.hostPort=443 \
    --set ingressClass.enabled=true --set ingressClass.isDefaultClass=true
'
```

### 6. Install cert-manager

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.0/cert-manager.yaml
```

### 7. Create secrets and apply manifests

```sh
cp k8s/secret.example.yaml k8s/secret.yaml   # fill in all values
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/cert-issuer.yaml         # fill in your email first
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml -f k8s/ingress.yaml
kubectl apply -f k8s/tg-api-secret.yaml -f k8s/tg-api-pvc.yaml \
              -f k8s/tg-api-deployment.yaml -f k8s/tg-api-service.yaml
kubectl apply -f k8s/redis.yaml               # Redis in whisper namespace
kubectl create secret generic redis-secret \
  --namespace whisper --from-literal=password=<strong-password>
```

### 8. Deploy buzz-bot

```sh
./k8s/deploy.sh   # builds image, transfers to node, rolls out
```

### Day-2 operations

```sh
./k8s/deploy.sh                              # redeploy after code changes
kubectl logs -n buzz-bot deploy/buzz-bot -f  # live logs
kubectl get pods -A                          # full cluster health
nix-shell -p k9s --run 'KUBECONFIG=k8s/kubeconfig k9s'  # interactive dashboard
./k8s/cluster-apply.sh delete               # tear down cluster
```

---

## Monitoring

Node health alerts are sent to your Telegram chat when thresholds are crossed: RAM >80%, disk >70%, or OOM kills in the last hour.

```sh
./k8s/install-monitoring.sh
```

Reads `BOT_TOKEN` and `ADMIN_USER_IDS` from the `buzz-bot-env` k8s secret, injects them into `k8s/node-health-alert.sh`, installs the script on the k3s node at `/usr/local/bin/node-health-alert.sh`, and registers a cron job (`/etc/cron.d/node-health`) that runs every 30 minutes.

---

## dub-pipeline (RunPod Serverless)

The AI dubbing worker runs as a RunPod Serverless endpoint (GPU cloud). buzz-bot dispatches jobs via the RunPod API; workers spin up on demand, process the job, and post results back via HTTP callbacks.

See [dub-pipeline/README.md](../../dub-pipeline/README.md) for full deployment instructions.

### Build and push

```sh
cd ../dub-pipeline
docker buildx build --platform linux/amd64 \
  -t watchcat/dub-pipeline:latest --push .
```

### Local testing

```sh
cd ../dub-pipeline
python3.11 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python test_job.py [audio_url] [language]
# Output uploaded to R2: dubbed/999999/{language}.mp3
```

---

## Self-hosted Telegram Bot API Server

Removes the 50 MB file limit (up to 2 GB). Required for sending long dubbed episodes.

```sh
cp k8s/tg-api-secret.example.yaml k8s/tg-api-secret.yaml
# Fill in TELEGRAM_API_ID and TELEGRAM_API_HASH from my.telegram.org
kubectl apply -f k8s/tg-api-secret.yaml -f k8s/tg-api-pvc.yaml \
              -f k8s/tg-api-deployment.yaml -f k8s/tg-api-service.yaml
```

Log out from api.telegram.org first: `curl "https://api.telegram.org/bot<TOKEN>/logOut"`
