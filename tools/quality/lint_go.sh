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
    echo "[quality][go-lint] $*" >&2
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

if ! command -v go >/dev/null 2>&1; then
    fail_or_skip "go not found"
fi
if ! command -v gofmt >/dev/null 2>&1; then
    fail_or_skip "gofmt not found"
fi

GO_FILES=()
while IFS= read -r file; do
    GO_FILES+=("${file}")
done < <(cd "${REPO_ROOT}" && rg --files -g '*.go')

if [[ ${#GO_FILES[@]} -eq 0 ]]; then
    log "SKIP: no Go files found"
    exit 0
fi

GOFMT_OUTPUT="$(cd "${REPO_ROOT}" && gofmt -l "${GO_FILES[@]}")"
if [[ -n "${GOFMT_OUTPUT}" ]]; then
    log "ERROR: gofmt required for:"
    printf '%s\n' "${GOFMT_OUTPUT}" >&2
    exit 1
fi

log "Running go vet"
go vet -C "${REPO_ROOT}/temporal" ./...

if command -v staticcheck >/dev/null 2>&1; then
    CHANGED_GO_PACKAGES=()
    while IFS= read -r changed; do
        if [[ "${changed}" == temporal/* ]] && [[ "${changed}" == *.go ]]; then
            package_dir="${changed#temporal/}"
            package_dir="$(dirname "${package_dir}")"
            if [[ "${package_dir}" == "." ]]; then
                CHANGED_GO_PACKAGES+=("./")
            else
                CHANGED_GO_PACKAGES+=("./${package_dir}")
            fi
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

    if [[ ${#CHANGED_GO_PACKAGES[@]} -gt 0 ]]; then
        mapfile -t UNIQUE_GO_PACKAGES < <(printf '%s\n' "${CHANGED_GO_PACKAGES[@]}" | sort -u)
        log "Running staticcheck on changed Go packages"
        (cd "${REPO_ROOT}/temporal" && staticcheck "${UNIQUE_GO_PACKAGES[@]}")
    else
        log "SKIP: no changed Go packages for staticcheck"
    fi
elif [[ "${STRICT}" == "1" ]]; then
    log "ERROR: staticcheck not found"
    exit 1
else
    log "WARN: staticcheck not found (non-strict mode)"
fi

log "PASS"
