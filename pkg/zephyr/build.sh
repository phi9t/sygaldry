#!/bin/bash
#
# Zephyr AI/ML Environment Build Script
# =====================================
#
# This script builds the Zephyr AI/ML development environment by:
# 1. Converting spack_src.yaml to spack.yaml
# 2. Creating necessary directories
# 3. Concretizing the environment
# 4. Installing all packages
# 5. Generating the Spack view
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
    log "ERROR: $*"
    exit 1
}

main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    log "Starting Zephyr AI/ML environment build..."

    # Change to package directory
    cd "${script_dir}"

    # Verify spack_src.yaml exists
    if [[ ! -f "spack_src.yaml" ]]; then
        error "spack_src.yaml not found in package directory"
    fi

    # Source Spack if available
    if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
        log "Sourcing Spack environment..."
        source "/opt/spack_src/share/spack/setup-env.sh"
    fi

    # Verify spack command is available
    if ! command -v spack >/dev/null 2>&1; then
        error "Spack command not found. Please ensure Spack is installed and sourced."
    fi

    log "Using Spack version: $(spack --version)"

    # Convert template to environment file
    # Convert template to environment file (only if not pinned by lockfile)
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

    # Create necessary directories
    log "Creating Spack store directories..."
    mkdir -p /opt/spack_store/{install_tree,build_stage,source_cache,misc_cache}

    if [[ -f "spack.lock" ]]; then
        log "Installing from pinned spack.lock..."
        spack --env . install
    else
        # Concretize environment
        log "Concretizing environment (this may take a while)..."
        spack --env . concretize --force

        # Install packages
        log "Installing packages..."
        spack --env . install
    fi

    # Generate view
    log "Generating Spack view..."
    spack --env . env view regenerate

    # Show installation summary
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
