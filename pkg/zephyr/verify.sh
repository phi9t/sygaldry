#!/bin/bash
# Lightweight verification for the Zephyr Spack environment.
# Usage: ./verify.sh [--require-gpu]

set -euo pipefail

require_gpu=false
if [[ "${1:-}" == "--require-gpu" ]]; then
    require_gpu=true
fi

log() {
    echo "[verify] $*" >&2
}

if [[ -z "${SYGALDRY_IN_CONTAINER:-}" ]]; then
    log "WARNING: SYGALDRY_IN_CONTAINER not set; ensure you are in the Zephyr container"
fi

if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
    source "/opt/spack_src/share/spack/setup-env.sh"
else
    log "ERROR: Spack setup script not found at /opt/spack_src"
    exit 1
fi

if [[ -f "spack.yaml" ]] || [[ -f "spack.lock" ]]; then
    spack env activate . 2>/dev/null || true
elif [[ -f "${SYGALDRY_ROOT:-/workspace}/pkg/zephyr/spack.yaml" ]] || [[ -f "${SYGALDRY_ROOT:-/workspace}/pkg/zephyr/spack.lock" ]]; then
    spack env activate "${SYGALDRY_ROOT:-/workspace}/pkg/zephyr" 2>/dev/null || true
fi

python3 - <<'PY'
import sys
import torch

print("torch:", torch.__version__)
print("cuda_available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("device_count:", torch.cuda.device_count())
    print("device_0:", torch.cuda.get_device_name(0))
    print("cuda_version:", torch.version.cuda)
    print("cudnn_version:", torch.backends.cudnn.version())
PY

python3 - <<'PY'
import jax
print("jax:", jax.__version__)
print("devices:", jax.devices())
PY

if [[ "${require_gpu}" == "true" ]]; then
    python3 - <<'PY'
import sys
import torch
if not torch.cuda.is_available():
    print("ERROR: GPU required but torch.cuda.is_available() is false", file=sys.stderr)
    sys.exit(1)
PY
fi

log "OK: Zephyr environment verified"
