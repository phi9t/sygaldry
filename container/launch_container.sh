#!/bin/bash
# DEPRECATED — compatibility shim for container/launch_container.sh
#
# This script now delegates to the `zephyr` binary. Direct callers should
# migrate to `zephyr shell`, `zephyr run`, or `bin/sygaldry`. This shim
# will be removed once all direct callers are migrated.
#
# Equivalent commands:
#   ./container/launch_container.sh                  → zephyr shell
#   ./container/launch_container.sh -- cmd args      → zephyr run -- cmd args
#   ./container/launch_container.sh --entrypoint E   → zephyr --entrypoint E shell
#   ./container/launch_container.sh --repo /path     → zephyr --repo /path shell

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

echo "DEPRECATED: container/launch_container.sh is a compatibility shim. Use 'zephyr' or 'bin/sygaldry' directly." >&2

# Find the zephyr binary (same search order as resolveContainerLauncher in Go)
find_zephyr() {
    local home="${SYGALDRY_HOME:-}"
    if [[ -n "$home" ]]; then
        for candidate in \
            "${home}/target/release/zephyr" \
            "${home}/crates/zephyr/target/release/zephyr"; do
            [[ -x "$candidate" ]] && echo "$candidate" && return 0
        done
    fi
    if command -v zephyr &>/dev/null; then command -v zephyr; return 0; fi
    for candidate in \
        "${SCRIPT_DIR}/../crates/zephyr/target/release/zephyr" \
        "${SCRIPT_DIR}/../target/release/zephyr" \
        "/opt/sygaldry/crates/zephyr/target/release/zephyr"; do
        [[ -x "$candidate" ]] && echo "$candidate" && return 0
    done
    return 1
}

if ! ZEPHYR="$(find_zephyr)"; then
    echo "launch_container.sh: zephyr binary not found. Build it with: cd crates/zephyr && cargo build --release" >&2
    exit 1
fi
readonly ZEPHYR

# Parse old-style flags into global_args; collect passthrough args after --.
global_args=()
passthrough_args=()
passthrough_started=0

while [[ $# -gt 0 ]]; do
    if [[ $passthrough_started -eq 1 ]]; then
        passthrough_args+=("$1"); shift; continue
    fi
    case "$1" in
        --entrypoint=*) global_args+=("--entrypoint" "${1#*=}"); shift ;;
        --entrypoint|-e) global_args+=("--entrypoint" "${2:?missing value for --entrypoint}"); shift 2 ;;
        --repo=*)        global_args+=("--repo" "${1#*=}"); shift ;;
        --repo)          global_args+=("--repo" "${2:?missing value for --repo}"); shift 2 ;;
        --run-id=*)      global_args+=("--run-id" "${1#*=}"); shift ;;
        --run-id)        global_args+=("--run-id" "${2:?missing value for --run-id}"); shift 2 ;;
        --lease-mode=*)  global_args+=("--lease-mode" "${1#*=}"); shift ;;
        --lease-mode)    global_args+=("--lease-mode" "${2:?missing value for --lease-mode}"); shift 2 ;;
        --cache-profile=*) global_args+=("--cache-profile" "${1#*=}"); shift ;;
        --cache-profile)   global_args+=("--cache-profile" "${2:?missing value for --cache-profile}"); shift 2 ;;
        --print-effective-config) global_args+=("--print-effective-config"); shift ;;
        --) passthrough_started=1; shift ;;
        *) passthrough_args+=("$1"); shift ;;
    esac
done

if [[ ${#passthrough_args[@]} -gt 0 ]]; then
    exec "$ZEPHYR" "${global_args[@]}" run -- "${passthrough_args[@]}"
else
    exec "$ZEPHYR" "${global_args[@]}" shell
fi
