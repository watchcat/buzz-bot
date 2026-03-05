# Build stage
FROM crystallang/crystal:latest-alpine AS builder

WORKDIR /app

# Install dependencies
COPY shard.yml shard.lock* ./
RUN shards install --production

# Copy source
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
COPY src/views/ ./src/views/

EXPOSE 3000

CMD ["./buzz-bot"]
