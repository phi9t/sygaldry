#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

exec python3 "${SCRIPT_DIR}/zephyr_concretize_analyze.py" "$@"

