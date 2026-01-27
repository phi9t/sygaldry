#!/usr/bin/env bash
set -euo pipefail

if command -v temporal >/dev/null 2>&1; then
  echo "Starting Temporal dev server via Temporal CLI..."
  exec temporal server start-dev --ui-port 8233
fi

if command -v docker >/dev/null 2>&1; then
  echo "Temporal CLI not found. Starting via docker compose..."
  if docker compose version >/dev/null 2>&1; then
    exec docker compose up
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    exec docker-compose up
  fi
fi

echo "No temporal CLI or docker found. Install Temporal CLI or Docker, then retry."
exit 1
