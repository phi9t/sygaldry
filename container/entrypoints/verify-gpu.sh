#!/bin/bash
set -euo pipefail

echo "=== GPU Verification ==="
echo ""

# CUDA driver
echo "NVIDIA Driver:"
nvidia-smi --query-gpu=driver_version,cuda_version --format=csv,noheader 2>/dev/null || echo "nvidia-smi not available"
echo ""

# CUDA toolkit
echo "CUDA Toolkit:"
nvcc --version 2>/dev/null | grep "release" || echo "nvcc not available"
echo ""

# Source Spack if available
if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
    source "/opt/spack_src/share/spack/setup-env.sh"
    if [[ -f "spack.yaml" ]] || [[ -f "spack.lock" ]]; then
        spack env activate . 2>/dev/null || true
    fi
fi

# PyTorch
echo "PyTorch CUDA:"
python3 -c "
import torch
print(f'  Available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  Device: {torch.cuda.get_device_name(0)}')
    print(f'  CUDA Version: {torch.version.cuda}')
    print(f'  cuDNN Version: {torch.backends.cudnn.version()}')
" 2>/dev/null || echo "  PyTorch not available"
echo ""

# JAX
echo "JAX GPU:"
python3 -c "
import jax
devices = jax.devices()
print(f'  Devices: {devices}')
gpu_devices = [d for d in devices if d.platform == 'gpu']
print(f'  GPU count: {len(gpu_devices)}')
" 2>/dev/null || echo "  JAX not available"
echo ""

echo "=== Verification Complete ==="
