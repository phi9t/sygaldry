#!/bin/bash
#
# Spack install entrypoint
# ========================
#
# Runs `spack install` (with any provided args) after initializing Spack,
# then drops into an interactive shell.

set -euo pipefail

# Spack environment initialization
if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
    source "/opt/spack_src/share/spack/setup-env.sh"
    if [[ -f "/opt/spack_src/share/spack/spack-completion.bash" ]]; then
        source "/opt/spack_src/share/spack/spack-completion.bash"
    fi
else
    echo "ERROR: Spack setup script not found at /opt/spack_src" >&2
    exit 1
fi

# Ensure workspace is available
if [[ -d "/workspace" ]]; then
    cd /workspace
fi

spack install "$@"
exec bash -i
