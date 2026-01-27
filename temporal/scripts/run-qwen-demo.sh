#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKER_LOG=${WORKER_LOG:-/tmp/temporal-worker.log}
LOG_DIR=${TEMPORAL_LOG_DIR:-"$ROOT_DIR/logs"}
LOG_MAX_BYTES=${TEMPORAL_LOG_MAX_BYTES:-10000}

cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run the local Temporal server" >&2
  exit 1
fi

echo "Starting Temporal via docker compose..."
docker compose up -d

for i in {1..60}; do
  if (echo > /dev/tcp/127.0.0.1/7233) >/dev/null 2>&1; then
    echo "Temporal is up."
    break
  fi
  sleep 2
  if [[ $i -eq 60 ]]; then
    echo "Temporal did not become ready on 7233" >&2
    exit 1
  fi
done

if pgrep -f "go run ./cmd/worker" >/dev/null 2>&1; then
  echo "Worker already running."
else
  echo "Starting worker..."
  mkdir -p "$LOG_DIR"
  nohup env TEMPORAL_LOG_DIR="$LOG_DIR" TEMPORAL_LOG_MAX_BYTES="$LOG_MAX_BYTES" go run ./cmd/worker > "$WORKER_LOG" 2>&1 &
  echo "Worker log: $WORKER_LOG"
fi

sleep 2

echo "Running Qwen3 demo pipeline..."
go run ./cmd/orchestrate -plan examples/qwen_demo.yaml
