#!/usr/bin/env bash
# Launch the autoretry loop in a named tmux session for human + agent visibility.

set -euo pipefail

SESSION="${TMUX_SESSION:-zephyr-autoretry}"
PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-validate}"
LOG_FILE="/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}/logs/autoretry-tmux.log"

mkdir -p "$(dirname "${LOG_FILE}")"

if tmux has-session -t "${SESSION}" 2>/dev/null; then
  echo "tmux session '${SESSION}' already exists. Attach with: tmux attach -t ${SESSION}"
  exit 0
fi

tmux new-session -d -s "${SESSION}" "cd /mnt/data_infra/workspace/sygaldry && ./tools/zephyr_autoretry.sh | tee -a '${LOG_FILE}'"
echo "Started tmux session '${SESSION}'. Attach with: tmux attach -t ${SESSION}"
echo "Log: ${LOG_FILE}"
