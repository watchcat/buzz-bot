#!/usr/bin/env bash
# devrun.sh — start Cloudflare Tunnel + buzz-bot with one command
#
# Usage:
#   ./devrun.sh            # auto-detect mode from ~/.cloudflared/config.yml
#   ./devrun.sh --quick    # force quick tunnel (no account, temporary URL)
#   ./devrun.sh --named    # force named tunnel (requires ~/.cloudflared/config.yml)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

TUNNEL_PID=""
APP_PID=""
TUNNEL_LOG=""

# ---------------------------------------------------------------------------
# Cleanup: kill both processes on exit / Ctrl+C
# ---------------------------------------------------------------------------
cleanup() {
  echo ""
  echo -e "${YELLOW}Shutting down...${NC}"
  [[ -n "$APP_PID"    ]] && kill "$APP_PID"    2>/dev/null || true
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  [[ -n "$TUNNEL_LOG" && -f "$TUNNEL_LOG" ]] && rm -f "$TUNNEL_LOG"
  exit 0
}
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in cloudflared crystal; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: '${cmd}' not found in PATH.${NC}"
    case "$cmd" in
      cloudflared)
        echo "  macOS:  brew install cloudflared"
        echo "  Linux:  https://github.com/cloudflare/cloudflared/releases/latest"
        ;;
      crystal)
        echo "  https://crystal-lang.org/install/"
        ;;
    esac
    exit 1
  fi
done

if [[ ! -f .env ]]; then
  echo -e "${RED}Error: .env not found.${NC}"
  echo "  cp .env.example .env  # then fill in BOT_TOKEN and DATABASE_URL"
  exit 1
fi

# ---------------------------------------------------------------------------
# Determine tunnel mode
# ---------------------------------------------------------------------------
MODE="quick"

if [[ -f ~/.cloudflared/config.yml ]] && grep -q "^tunnel:" ~/.cloudflared/config.yml; then
  MODE="named"
fi

# CLI flag overrides auto-detection
case "${1:-}" in
  --quick) MODE="quick" ;;
  --named) MODE="named" ;;
  "")      ;;
  *)
    echo -e "${RED}Unknown argument: $1${NC}"
    echo "Usage: $0 [--quick|--named]"
    exit 1
    ;;
esac

echo -e "${BOLD}==> buzz-bot devrun (mode: ${MODE})${NC}"

TUNNEL_LOG=$(mktemp /tmp/cloudflared-XXXXXX.log)

# ---------------------------------------------------------------------------
# Start tunnel
# ---------------------------------------------------------------------------
if [[ "$MODE" == "quick" ]]; then
  echo -e "${BLUE}Starting quick tunnel...${NC}"
  cloudflared tunnel --url "http://localhost:${PORT:-3000}" >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!

  # Wait up to 30s for the trycloudflare.com URL to appear in the log
  echo -n "    Waiting for tunnel URL"
  TUNNEL_URL=""
  for _ in $(seq 1 30); do
    TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
    [[ -n "$TUNNEL_URL" ]] && break
    echo -n "."
    sleep 1
  done
  echo ""

  if [[ -z "$TUNNEL_URL" ]]; then
    echo -e "${RED}Failed to get tunnel URL after 30s. cloudflared output:${NC}"
    cat "$TUNNEL_LOG"
    cleanup
  fi

  echo -e "${GREEN}    Tunnel: ${TUNNEL_URL}${NC}"

  # Patch .env in-place — portable across macOS (BSD sed) and Linux (GNU sed)
  perl -i -pe "s|^WEBHOOK_URL=.*|WEBHOOK_URL=${TUNNEL_URL}/webhook|" .env
  perl -i -pe "s|^BASE_URL=.*|BASE_URL=${TUNNEL_URL}|" .env
  echo -e "${BLUE}    Updated .env: WEBHOOK_URL=${TUNNEL_URL}/webhook${NC}"

else
  echo -e "${BLUE}Starting named tunnel...${NC}"
  # cloudflared reads tunnel name/ID from ~/.cloudflared/config.yml automatically
  cloudflared tunnel run >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!

  # Give it a moment to connect before the app tries to register the webhook
  sleep 3

  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo -e "${RED}cloudflared exited unexpectedly. Output:${NC}"
    cat "$TUNNEL_LOG"
    exit 1
  fi

  TUNNEL_URL=$(grep -oP 'https://[^\s"]+' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
  if [[ -n "$TUNNEL_URL" ]]; then
    echo -e "${GREEN}    Tunnel: ${TUNNEL_URL}${NC}"
  else
    echo -e "${GREEN}    Tunnel running (URL from ~/.cloudflared/config.yml)${NC}"
  fi
fi

# ---------------------------------------------------------------------------
# Start the Crystal app
# ---------------------------------------------------------------------------
echo -e "${BLUE}Starting buzz-bot...${NC}"
crystal run src/buzz_bot.cr &
APP_PID=$!

echo ""
echo -e "${GREEN}${BOLD}Everything is running. Press Ctrl+C to stop both.${NC}"
echo ""

# Keep the script alive; exit when the app process exits
wait "$APP_PID"
