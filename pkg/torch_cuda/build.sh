#!/bin/bash
#
# PyTorch CUDA Package Build Script
# =================================
#
# This script builds the PyTorch CUDA environment by:
# 1. Converting spack_src.yaml to spack.yaml
# 2. Concretizing the environment
# 3. Installing all packages
#
# Usage:
#   ./pkg/torch_cuda/build.sh

set -euo pipefail

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [torch-cuda:${BASH_LINENO[0]}] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    log "Starting PyTorch CUDA environment build..."
    
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
    log "Converting spack_src.yaml to spack.yaml..."
    cp spack_src.yaml spack.yaml
    
    # Concretize environment
    log "Concretizing environment (this may take a while)..."
    spack --env . concretize --force
    
    # Install packages
    log "Installing packages..."
    spack --env . install
    
    log "PyTorch CUDA environment build completed successfully!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
