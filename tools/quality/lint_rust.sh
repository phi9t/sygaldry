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
    echo "[quality][rust-lint] $*" >&2
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
if ! command -v rustc >/dev/null 2>&1; then
    fail_or_skip "rustc not found"
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
RUSTC_CMD=(rustc)
if [[ -n "${RUST_TOOLCHAIN}" ]]; then
    if command -v rustup >/dev/null 2>&1; then
        CARGO_CMD=(rustup run "${RUST_TOOLCHAIN}" cargo)
        RUSTC_CMD=(rustup run "${RUST_TOOLCHAIN}" rustc)
    elif [[ "${STRICT}" == "1" ]]; then
        log "ERROR: rust-toolchain is pinned to ${RUST_TOOLCHAIN} but rustup is unavailable"
        exit 1
    fi
fi

RUSTC_VERSION="$("${RUSTC_CMD[@]}" --version | awk '{print $2}')"
readonly RUSTC_VERSION
CLIPPY_VERSION_LINE="$("${CARGO_CMD[@]}" clippy --version 2>/dev/null || true)"
if [[ -n "${CLIPPY_VERSION_LINE}" ]]; then
    CLIPPY_VERSION="$(awk '{print $2}' <<<"${CLIPPY_VERSION_LINE}")"
    RUSTC_MINOR="$(awk -F. '{print $2}' <<<"${RUSTC_VERSION}")"
    CLIPPY_MINOR="$(sed -E 's/^0\.1\.([0-9]+).*$/\1/' <<<"${CLIPPY_VERSION}")"
    if [[ -n "${RUSTC_MINOR}" ]] && [[ -n "${CLIPPY_MINOR}" ]] && [[ "${RUSTC_MINOR}" != "${CLIPPY_MINOR}" ]]; then
        fail_or_skip "clippy (${CLIPPY_VERSION}) is incompatible with rustc (${RUSTC_VERSION}); install matching components with rustup"
    fi
fi

CHANGED_RUST_FILES=()
while IFS= read -r changed; do
    if [[ "${changed}" == crates/zephyr/* ]] && [[ "${changed}" == *.rs ]]; then
        CHANGED_RUST_FILES+=("${changed}")
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

if [[ ${#CHANGED_RUST_FILES[@]} -eq 0 ]]; then
    log "SKIP: no changed Rust files under crates/zephyr"
    exit 0
fi

log "Running rustfmt check"
"${CARGO_CMD[@]}" fmt --manifest-path "${MANIFEST_PATH}" --all --check -- "${CHANGED_RUST_FILES[@]}"

log "Running clippy"
"${CARGO_CMD[@]}" clippy --manifest-path "${MANIFEST_PATH}" --all-targets --all-features -- -D warnings -D clippy::unwrap_used

log "PASS"
