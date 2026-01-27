#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

"${SCRIPT_DIR}/e2e_02_params_outputs.sh"
"${SCRIPT_DIR}/e2e_03_templates_imports.sh"
"${SCRIPT_DIR}/e2e_04_validation_guardrails.sh"
"${SCRIPT_DIR}/e2e_07_monitoring_consistency.sh"
