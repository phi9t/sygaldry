#!/bin/bash
# Docker ENTRYPOINT for baked MLSys images.
#
# Activates the repo venv (if present) then exec's the user command.
# This script is COPYed into the image at /opt/mlsys-entrypoint.sh.
set -e

VENV="${MLSYS_VENV_PATH:-/opt/repo-venv}"

if [ -d "${VENV}" ] && [ -f "${VENV}/bin/activate" ]; then
    # shellcheck disable=SC1091
    . "${VENV}/bin/activate"
fi

# Source Spack view paths if available (for LD_LIBRARY_PATH, etc.)
SPACK_VIEW="/opt/spack_store/view"
if [ -d "${SPACK_VIEW}" ]; then
    export PATH="${SPACK_VIEW}/bin:${PATH}"
    export LD_LIBRARY_PATH="${SPACK_VIEW}/lib:${SPACK_VIEW}/lib64:${LD_LIBRARY_PATH:-}"
fi

# CUDA paths
if [ -d "/usr/local/cuda" ]; then
    export CUDA_HOME="/usr/local/cuda"
    export PATH="${CUDA_HOME}/bin:${PATH}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
fi

exec "$@"
