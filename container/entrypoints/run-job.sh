#!/bin/bash
set -euo pipefail

# Source Spack environment
if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
    source "/opt/spack_src/share/spack/setup-env.sh"
fi

# CUDA environment
if [[ -d "/usr/local/cuda" ]]; then
    export CUDA_HOME="/usr/local/cuda"
    export PATH="${CUDA_HOME}/bin:${PATH}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
fi

# Activate Spack environment if in a spack directory
if [[ -f "spack.yaml" ]] || [[ -f "spack.lock" ]]; then
    spack env activate . 2>/dev/null || true
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: run-job.sh <command...>" >&2
    exit 2
fi

exec "$@"
