# syntax=docker/dockerfile:1.4

# ── Shared deps stage ─────────────────────────────────────────────────────
FROM crystallang/crystal:1.19-alpine AS deps

WORKDIR /app

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

COPY src/ ./src/
COPY public/ ./public/

# ── Parallel build stages (BuildKit runs these concurrently) ──────────────
FROM deps AS build-main
RUN crystal build src/buzz_bot.cr \
    --release \
    --static \
    --no-debug \
    -o /app/buzz-bot

FROM deps AS build-transcriber
RUN crystal build --release --static --no-debug \
    src/services/dub_transcriber.cr -o /app/dub-transcriber

FROM deps AS build-translator
RUN crystal build --release --static --no-debug \
    src/services/dub_translator.cr -o /app/dub-translator

FROM deps AS build-synthesizer
RUN crystal build --release --static --no-debug \
    src/services/dub_synthesizer.cr -o /app/dub-synthesizer

# ── Runtime stage ─────────────────────────────────────────────────────────
FROM alpine:3.19

RUN apk add --no-cache \
    libssl3 \
    libcrypto3 \
    ca-certificates \
    tzdata

WORKDIR /app

COPY --from=build-main        /app/buzz-bot        ./buzz-bot
COPY --from=build-transcriber /app/dub-transcriber ./dub-transcriber
COPY --from=build-translator  /app/dub-translator  ./dub-translator
COPY --from=build-synthesizer /app/dub-synthesizer ./dub-synthesizer
COPY --from=build-main        /app/public          ./public

EXPOSE 3000

CMD ["./buzz-bot"]
