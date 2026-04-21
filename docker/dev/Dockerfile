FROM elixir:1.19

WORKDIR /app

# Paquets système nécessaires en dev
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl \
      tini \
      inotify-tools \
      build-essential \
      postgresql-client \
      git \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files first pour le cache deps
COPY mix.exs mix.lock ./

RUN MIX_ENV=dev mix deps.get

RUN MIX_ENV=dev mix deps.compile

COPY config ./config
COPY lib ./lib
COPY priv ./priv

RUN MIX_ENV=dev mix compile

# Entrypoint dev
COPY ./docker/dev/entrypoint.sh /tmp/entrypoint.sh
RUN chmod +x /tmp/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/bin/bash", "/tmp/entrypoint.sh"]
