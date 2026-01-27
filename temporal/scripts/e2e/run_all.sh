#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

"${SCRIPT_DIR}/run_smoke.sh"
"${SCRIPT_DIR}/run_medium.sh"
"${SCRIPT_DIR}/run_heavy.sh"
