#!/bin/bash
#
# Sygaldry Spack Build Script
# ===========================
#
# This script builds the Spack environment by:
# 1. Converting spack_src.yaml to spack.yaml
# 2. Concretizing the environment
# 3. Installing all packages
#
# Usage:
#   ./tools/build.sh

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKSPACE_DIR="${SCRIPT_DIR}/.."

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [spack-build:${BASH_LINENO[0]}] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

main() {
    log "Starting Spack environment build..."
    
    # Change to tools directory
    cd "${SCRIPT_DIR}"
    
    # Verify spack_src.yaml exists
    if [[ ! -f "spack_src.yaml" ]]; then
        error "spack_src.yaml not found in tools directory"
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
    log "Converting spack_src.yaml to spack.yaml..."
    cp spack_src.yaml spack.yaml
    
    # Create necessary directories
    log "Creating Spack store directories..."
    mkdir -p /opt/spack_store/{install_tree,build_stage,source_cache,misc_cache}
    
    # Concretize environment
    log "Concretizing environment (this may take a while)..."
    spack --env . concretize --force
    
    # Install packages
    log "Installing packages..."
    spack --env . install
    
    # Generate view
    log "Generating Spack view..."
    spack --env . env view regenerate
    
    # Show installation summary
    log "Installation completed successfully!"
    log "Installed packages:"
    spack --env . find
    
    log "Spack view available at: /opt/spack_store/view"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
