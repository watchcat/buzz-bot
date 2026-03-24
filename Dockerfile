# syntax=docker/dockerfile:1.4

# Build stage
FROM crystallang/crystal:latest-alpine AS builder

WORKDIR /app

# ── Crystal dependencies ──────────────────────────────────────────────────────
COPY shard.yml shard.lock* ./
RUN shards install --production

# Patch crystal-pg to support the PostgreSQL `options` startup parameter.
# Needed for Neon's SNI fallback (?options=endpoint%3D<id>) with static binaries.
RUN <<'PYEOF' python3
# 1. Add 'options' getter to ConnInfo struct (conninfo.cr)
path = 'lib/pg/src/pq/conninfo.cr'
src = open(path).read()
src = src.replace(
    "getter auth_methods : Array(String) = %w[scram-sha-256-plus scram-sha-256 md5]",
    "getter auth_methods : Array(String) = %w[scram-sha-256-plus scram-sha-256 md5]\n\n    # PostgreSQL startup options (e.g. endpoint=ep-xxx for Neon SNI fallback)\n    getter options : String?"
)
src = src.replace(
    "      else\n        # ignore",
    "      when \"options\"\n        @options = URI.decode(value)\n      else\n        # ignore"
)
open(path, 'w').write(src)

# 2. Add 'options' to startup_args in connection.cr
path = 'lib/pg/src/pq/connection.cr'
src = open(path).read()
src = src.replace(
    "      startup startup_args",
    "      if opts = @conninfo.options\n        startup_args << \"options\" << opts\n      end\n\n      startup startup_args",
    1
)
open(path, 'w').write(src)
print('crystal-pg patched OK')
PYEOF

# Copy Crystal source + public assets (public/js/main.js already built above)
COPY src/ ./src/
COPY public/ ./public/

# Build release binary
RUN crystal build src/buzz_bot.cr \
    --release \
    --static \
    --no-debug \
    -o /app/buzz-bot

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache \
    libssl3 \
    libcrypto3 \
    ca-certificates \
    tzdata

WORKDIR /app

COPY --from=builder /app/buzz-bot ./buzz-bot
COPY --from=builder /app/public ./public

EXPOSE 3000

CMD ["./buzz-bot"]
