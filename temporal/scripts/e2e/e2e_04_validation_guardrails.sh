#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  local run_dir
  local out_file
  local err_file
  local fixture
  local expected

  e2e::check_prereqs
  run_dir="$(e2e::new_tmp_dir)"
  out_file="${run_dir}/validate.out"
  err_file="${run_dir}/validate.err"

  cleanup() {
    if [[ -n "${run_dir:-}" ]]; then
      rm -rf "${run_dir}"
    fi
  }
  trap cleanup EXIT

  while IFS='|' read -r fixture expected; do
    if [[ -z "${fixture}" ]]; then
      continue
    fi

    if (
      cd "${E2E_ROOT_DIR}"
      GOFLAGS="-mod=mod" go run ./cmd/orchestrate validate -plan "${fixture}"
    ) >"${out_file}" 2>"${err_file}"; then
      e2e::fail "expected validation failure for ${fixture}"
    fi

    e2e::assert_contains "${err_file}" "${expected}"
  done <<'CASES'
examples/e2e/invalid_unknown_field.yaml|field unknown_field not found
examples/e2e/invalid_cycle.yaml|dependency cycle detected
examples/e2e/invalid_unknown_template.yaml|references unknown template
examples/e2e/invalid_when.yaml|invalid when condition
examples/e2e/invalid_missing_payload.yaml|docker_build requires image
CASES

  e2e::log "E2E-04 passed"
}

main "$@"
