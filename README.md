# Whispr Calls Service

Signalling and call-metadata service for the Whispr messenger. Phoenix/Elixir
application providing REST endpoints, WebSocket signalling and background
workers for the calls subsystem.

## Stack

- Elixir 1.17 / Erlang/OTP 27
- Phoenix 1.8 (no HTML, no assets, JSON API only)
- PostgreSQL via Ecto
- Redis (pub/sub, session state)
- Oban (background jobs)
- JWT (JWKS verification of `auth-service` tokens)

## Development

```bash
mix setup            # fetch deps, create DB, run migrations
mix test             # run the test suite
mix format           # format source
mix credo            # lint
mix phx.server       # start the HTTP endpoint
```

## Configuration

Runtime configuration is read from environment variables in
`config/runtime.exs`. The most important ones:

| Variable        | Description                                 |
|-----------------|---------------------------------------------|
| `DATABASE_URL`  | Ecto connection string                      |
| `SECRET_KEY_BASE` | Phoenix secret                            |
| `PORT`          | HTTP port (default `4000`)                  |
| `JWT_JWKS_URL`  | JWKS endpoint of the auth-service           |
| `PHX_HOST`      | Public hostname of the service              |
