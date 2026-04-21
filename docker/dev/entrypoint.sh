#!/bin/bash
set -e

cd /app

echo "[entrypoint] waiting for Postgres at ${DATABASE_HOST}:${DATABASE_PORT}..."
until pg_isready -h "${DATABASE_HOST}" -p "${DATABASE_PORT}" -U "${DATABASE_USER}" >/dev/null 2>&1; do
  sleep 1
done
echo "[entrypoint] Postgres is ready"

echo "[entrypoint] ensuring Ecto DB exists + running migrations"
MIX_ENV=dev mix ecto.create --quiet || true
MIX_ENV=dev mix ecto.migrate

exec env MIX_ENV=dev mix phx.server
