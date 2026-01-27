#!/bin/bash
#
# Zephyr AI/ML Environment Build Script
# =====================================
#
# Builds the Zephyr AI/ML development environment:
# 1. Convert spack_src.yaml to spack.yaml (if no lockfile)
# 2. Create necessary directories
# 3. Concretize the environment (if no lockfile)
# 4. Install all packages
# 5. Generate the Spack view
#
# Usage:
#   ./pkg/zephyr/build.sh
#
# Prerequisites:
#   - Must be run inside the sygaldry container
#   - Spack must be installed at /opt/spack_src

set -euo pipefail

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [zephyr:${BASH_LINENO[0]}] $*" >&2
}

error() {
    log "ERROR: $1"
    if [[ -n "${2:-}" ]]; then
        log "HINT:  $2"
    fi
    exit 1
}

readonly FORBIDDEN_REBUILD_PATTERN='(^|[^[:alnum:]_-])(py-torch|py-jax|py-jaxlib|torch|jax|jaxlib)([^[:alnum:]_-]|$)'

contains_forbidden_rebuilds() {
    local text="$1"
    if echo "${text}" | rg -qi "${FORBIDDEN_REBUILD_PATTERN}"; then
        return 0
    fi
    return 1
}

install_locked_roots() {
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        local hash spec
        hash="${line%% *}"
        spec="${line#* }"
        log "Install root /${hash} (${spec})"
        spack --env . install "/${hash}"
    done < <(python3 - <<'PY'
import json
with open("spack.lock", "r", encoding="utf-8") as f:
    data = json.load(f)
for root in data["roots"]:
    print(f'{root["hash"]} {root["spec"]}')
PY
)
}

main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    log "Starting Zephyr AI/ML environment build..."
    if [[ -z "${SYGALDRY_IN_CONTAINER:-}" ]]; then
        log "WARNING: SYGALDRY_IN_CONTAINER not set; ensure you are running inside the container"
    fi

    cd "${script_dir}"

    if [[ ! -f "spack_src.yaml" ]]; then
        error "spack_src.yaml not found in package directory"
    fi

    if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
        log "Sourcing Spack environment..."
        # shellcheck disable=SC1091
        source "/opt/spack_src/share/spack/setup-env.sh"
    fi

    if ! command -v spack >/dev/null 2>&1; then
        error "Spack command not found." \
              "Ensure you are inside the container and Spack is sourced."
    fi

    log "Using Spack version: $(spack --version)"

    if [[ -f "spack.lock" ]]; then
        log "spack.lock found; preserving pinned concretization"
        if [[ ! -f "spack.yaml" ]]; then
            log "spack.yaml missing; creating from spack_src.yaml"
            cp spack_src.yaml spack.yaml
        fi
    else
        log "Converting spack_src.yaml to spack.yaml..."
        cp spack_src.yaml spack.yaml
    fi

    log "Creating Spack store directories..."
    mkdir -p /opt/spack_store/{install_tree,build_stage,source_cache,misc_cache}

    if [[ -f "spack.lock" ]]; then
        log "Installing pinned roots from spack.lock..."
        install_locked_roots
    else
        log "Concretizing environment (this may take a while)..."
        spack --env . concretize --force

        log "Checking concretization safety (must not include torch/jax/jaxlib builds)..."
        local dry_run_out
        dry_run_out="$(spack --env . install --dry-run 2>&1 || true)"
        if contains_forbidden_rebuilds "${dry_run_out}"; then
            error "Concretization would build/rebuild torch/jax/jaxlib. Aborting." \
                  "Check concretize_report.json for conflicts; try --allow-deprecated."
        fi

        log "Installing packages..."
        spack --env . install
    fi

    log "Generating Spack view..."
    spack --env . env view regenerate

    log "=============================================="
    log "Zephyr AI/ML environment build completed!"
    log "=============================================="
    log ""
    log "Installed packages:"
    spack --env . find

    log ""
    log "Spack view available at: /opt/spack_store/view"
    log ""
    log "To activate this environment:"
    log "  cd /workspace/pkg/zephyr && spack-env-activate"
    log ""
    log "Verification commands:"
    log "  python -c \"import torch; print(torch.cuda.is_available())\""
    log "  python -c \"import jax; print(jax.devices())\""
    log "  which gdb lldb tmux rg fd"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
