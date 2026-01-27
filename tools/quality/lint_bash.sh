#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
STRICT="${QUALITY_STRICT:-0}"
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

log() {
    echo "[quality][bash-lint] $*" >&2
}

fail_or_skip() {
    local message="$1"
    if [[ "${STRICT}" == "1" ]]; then
        log "ERROR: ${message}"
        exit 1
    fi
    log "SKIP: ${message}"
    exit 0
}

SH_FILES=()
while IFS= read -r file; do
    SH_FILES+=("${file}")
done < <(cd "${REPO_ROOT}" && rg --files -g '*.sh')

if [[ ${#SH_FILES[@]} -eq 0 ]]; then
    log "SKIP: no shell scripts found"
    exit 0
fi

SHELLCHECK_BIN=""
if command -v shellcheck >/dev/null 2>&1; then
    SHELLCHECK_BIN="shellcheck"
elif [[ -x /tmp/shellcheck ]]; then
    SHELLCHECK_BIN="/tmp/shellcheck"
fi
if [[ -z "${SHELLCHECK_BIN}" ]]; then
    fail_or_skip "shellcheck not found"
fi

log "Running shellcheck"
(cd "${REPO_ROOT}" && "${SHELLCHECK_BIN}" -s bash -S warning -e SC2034 "${SH_FILES[@]}")

if command -v shfmt >/dev/null 2>&1; then
    CHANGED_SH_FILES=()
    while IFS= read -r changed; do
        if [[ "${changed}" == *.sh ]]; then
            CHANGED_SH_FILES+=("${changed}")
        fi
    done < <(
        {
            if [[ -n "${QUALITY_CHANGED_BASE:-}" ]]; then
                git -C "${REPO_ROOT}" diff --name-only "${QUALITY_CHANGED_BASE}...HEAD" || true
            elif [[ -n "${GITHUB_BASE_REF:-}" ]] && git -C "${REPO_ROOT}" rev-parse --verify "origin/${GITHUB_BASE_REF}" >/dev/null 2>&1; then
                git -C "${REPO_ROOT}" diff --name-only "origin/${GITHUB_BASE_REF}...HEAD" || true
            else
                git -C "${REPO_ROOT}" diff --name-only HEAD || true
                git -C "${REPO_ROOT}" ls-files --others --exclude-standard || true
            fi
        } | sort -u
    )

    if [[ ${#CHANGED_SH_FILES[@]} -gt 0 ]]; then
        log "Running shfmt -d on changed shell files"
        (cd "${REPO_ROOT}" && shfmt -d -i 4 -ci "${CHANGED_SH_FILES[@]}")
    else
        log "SKIP: no changed shell files for shfmt"
    fi
elif [[ "${STRICT}" == "1" ]]; then
    log "ERROR: shfmt not found"
    exit 1
else
    log "WARN: shfmt not found (non-strict mode)"
fi

log "PASS"
