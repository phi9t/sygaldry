#!/bin/bash
set -euo pipefail

# Source Spack environment
if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
    source "/opt/spack_src/share/spack/setup-env.sh"
fi

# Activate Spack environment if available
if [[ -f "spack.yaml" ]] || [[ -f "spack.lock" ]]; then
    spack env activate . 2>/dev/null || true
fi

# Find Python - prefer Spack Python
PYTHON_BIN=$(command -v python3 2>/dev/null || echo "python3")

# Don't rebuild these packages - use Spack versions
export UV_NO_BUILD_ISOLATION_PACKAGE="torch,jax,jaxlib,numpy,scipy"

if [[ $# -lt 1 ]]; then
    echo "Usage: uv-install.sh <package> [package ...]" >&2
    echo ""
    echo "Creates a venv and installs packages using uv."
    echo "Respects Spack-installed torch, jax, numpy, scipy."
    exit 2
fi

export PATH="/usr/local:/usr/local/bin:${PATH}"

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv not found in PATH" >&2
    exit 1
fi

uv venv --python "${PYTHON_BIN}"
source .venv/bin/activate
uv pip install "$@"

echo "Installed packages in .venv"
echo "Activate with: source .venv/bin/activate"
