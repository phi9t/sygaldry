#!/bin/bash
#
# Sygaldry Container Entrypoint
# =============================
#
# This script is executed when the container starts. It initializes the
# development environment with Spack and GPU tools.
#
# The entrypoint:
# - Sources Spack environment setup
# - Sets up CUDA environment (if available)
# - Displays welcome message with usage instructions
# - Executes the provided command or starts interactive shell
#

# ============================================================================
# Environment Setup
# ============================================================================

# Spack environment initialization
if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
    source "/opt/spack_src/share/spack/setup-env.sh"

    # Enable Spack bash completion if available
    if [[ -f "/opt/spack_src/share/spack/spack-completion.bash" ]]; then
        source "/opt/spack_src/share/spack/spack-completion.bash"
    fi

    echo "Spack environment initialized"
else
    echo "WARNING: Spack setup script not found at /opt/spack_src"
fi

# Set up development environment
export EDITOR="${EDITOR:-nano}"
export TERM="${TERM:-xterm-256color}"

# CUDA environment (if available)
if [[ -d "/usr/local/cuda" ]]; then
    export CUDA_HOME="/usr/local/cuda"
    export PATH="${CUDA_HOME}/bin:${PATH}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
fi

# ============================================================================
# Convenience Aliases and Functions
# ============================================================================

# GPU verification aliases
alias gpu-test='python3 -c "import torch; print(f\"CUDA: {torch.cuda.is_available()}\")"'
alias jax-test='python3 -c "import jax; print(f\"Devices: {jax.devices()}\")"'
alias spack-build='cd /workspace/pkg/zephyr && ./build.sh'

# Quick HuggingFace dataset download
hf-dataset() {
    python3 -c "from datasets import load_dataset; ds=load_dataset('$1', split='${2:-train[:100]}'); print(f'{len(ds)} rows')"
}

# ============================================================================
# Welcome Message
# ============================================================================

cat << '_WELCOME_EOF_'
+-------------------------------------------------------------+
|                    Sygaldry Build Environment               |
|                                                             |
|  Quick commands:                                            |
|    spack-env-activate         - Activate Spack environment  |
|    gpu-test                   - Verify PyTorch CUDA         |
|    jax-test                   - Verify JAX GPU              |
|    spack-build                - Build Zephyr environment    |
|                                                             |
|  Environment:                                               |
|    Workspace: /workspace                                    |
|    Spack:     /opt/spack_src                                |
|    HF Cache:  /opt/hf_cache                                 |
+-------------------------------------------------------------+
_WELCOME_EOF_

# ============================================================================
# Command Execution
# ============================================================================

# If arguments provided, execute them; otherwise start interactive shell
if [[ $# -gt 0 ]]; then
    exec "$@"
else
    exec bash -i
fi
