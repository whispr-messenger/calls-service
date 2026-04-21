# =============================================================================
# Whispr Calls Service - Dockerfile
# Multi-stage build for production-ready Elixir application
# =============================================================================

# -----------------------------------------------------------------------------
# STAGE 1: Build
# -----------------------------------------------------------------------------
FROM elixir:1.19-alpine AS builder

RUN apk add --no-cache \
    build-base \
    git \
    curl \
    openssl-dev

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix deps.get --only prod && \
    mix deps.compile

COPY lib lib
COPY priv priv

RUN mix compile

RUN mix release

# -----------------------------------------------------------------------------
# STAGE 2: Runtime
# -----------------------------------------------------------------------------
FROM elixir:1.19-alpine AS runtime

RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    libgcc \
    curl \
    bash

RUN addgroup -g 1000 whispr && \
    adduser -u 1000 -G whispr -s /bin/sh -D whispr

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    PORT=4002 \
    GRPC_PORT=50052

WORKDIR /app

COPY --from=builder --chown=whispr:whispr /app/_build/prod/rel/whispr_calls ./

COPY --chown=whispr:whispr docker/prod/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

USER whispr

EXPOSE 4002 50052

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost:4002/api/v1/health || exit 1

LABEL org.opencontainers.image.title="Whispr Calls Service" \
    org.opencontainers.image.description="Calls service for Whispr Messenger" \
    org.opencontainers.image.vendor="Whispr" \
    org.opencontainers.image.version="0.1.0"

ENTRYPOINT ["/app/entrypoint.sh"]
