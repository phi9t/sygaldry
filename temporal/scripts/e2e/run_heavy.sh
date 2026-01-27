#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

"${SCRIPT_DIR}/e2e_05_retry_failure_semantics.sh"
"${SCRIPT_DIR}/e2e_06_streaming_dag.sh"
