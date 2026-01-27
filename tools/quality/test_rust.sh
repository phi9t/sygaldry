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
    echo "[quality][rust-test] $*" >&2
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

if ! command -v cargo >/dev/null 2>&1; then
    fail_or_skip "cargo not found"
fi

MANIFEST_PATH="${REPO_ROOT}/crates/zephyr/Cargo.toml"
readonly MANIFEST_PATH
if [[ ! -f "${MANIFEST_PATH}" ]]; then
    log "SKIP: ${MANIFEST_PATH} not found"
    exit 0
fi

TOOLCHAIN_FILE="${REPO_ROOT}/crates/zephyr/rust-toolchain.toml"
readonly TOOLCHAIN_FILE
RUST_TOOLCHAIN=""
if [[ -f "${TOOLCHAIN_FILE}" ]]; then
    RUST_TOOLCHAIN="$(awk -F'\"' '/^channel =/ {print $2; exit}' "${TOOLCHAIN_FILE}")"
fi

CARGO_CMD=(cargo)
if [[ -n "${RUST_TOOLCHAIN}" ]]; then
    if command -v rustup >/dev/null 2>&1; then
        CARGO_CMD=(rustup run "${RUST_TOOLCHAIN}" cargo)
    elif [[ "${STRICT}" == "1" ]]; then
        log "ERROR: rust-toolchain is pinned to ${RUST_TOOLCHAIN} but rustup is unavailable"
        exit 1
    fi
fi

log "Running cargo test"
"${CARGO_CMD[@]}" test --manifest-path "${MANIFEST_PATH}"

log "PASS"
