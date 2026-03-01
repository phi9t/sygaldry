# Zephyr Post-Spack-Build Verification (PyTorch Latest Staging)

Date: 2026-02-21

## Scope

This document captures the post-Spack-build verification workflow executed for:

- Staging manifest: `pkg/zephyr/staging/pytorch_latest/spack_src.yaml`
- Staging entrypoint: `pkg/zephyr/staging/pytorch_latest/build.sh`
- Stage tool: `tools/zephyr_stage_spack.sh`

Goals:

1. Run staging with repo-native mechanism.
2. Confirm core stack is concretized and built: PyTorch, JAX, LLVM, Triton.
3. Enforce/verify `py-torch` concretizes with `+nccl +distributed`.
4. Run non-trivial GPU workloads in Zephyr container for PyTorch/JAX/Triton.

## Steps Taken

1. Ran staging build using Zephyr container launcher and builder role:

```bash
SYGALDRY_PROJECT_ID=zephyr-pytorch-latest-staging \
SYGALDRY_BUILD_ROLE=builder \
./container/launch_container.sh bash -lc '
  whoami; id
  cd /workspace/pkg/zephyr/staging/pytorch_latest
  ./build.sh
'
```

2. Collected staging artifacts:

- Run root:
  `/mnt/data_infra/zephyr_container_infra/projects/zephyr-pytorch-latest-staging/outputs/spack_stage/20260221-033810-191`
- Final status:
  `.../logs/final_status.json`
- Concretization report:
  `.../logs/concretize_report.json`
- Install log:
  `.../logs/install.log`
- Post-build verify logs:
  `.../logs/verify_pkg_zephyr.log`
  `.../logs/verify_gpu.log`

3. Verified staged lock roots include expected core packages and variants.

4. Ran post-build GPU workload checks in new Zephyr container with staged env activated:

```bash
SYGALDRY_PROJECT_ID=zephyr-pytorch-latest-staging \
./container/launch_container.sh bash -lc '
  set -eu -o pipefail
  source /opt/spack_src/share/spack/setup-env.sh
  STAGE_ENV=/workspace/outputs/spack_stage/20260221-033810-191/analyze_stage/run-j5hp990y
  eval "$(spack env activate --sh -d "${STAGE_ENV}")"
  python3 <workload_script.py>
'
```

## Code Written

Added post-concretization verification in `tools/zephyr_stage_spack.sh` to fail fast when `py-torch` is not concretized with `+nccl` and `+distributed`.

Location: `tools/zephyr_stage_spack.sh` (step id: `pytorch_variants`).

```python
stage_env = Path(os.environ["STAGE_ENV"])
lock_path = stage_env / "spack.lock"
lock = json.loads(lock_path.read_text(encoding="utf-8"))
roots = lock.get("roots", [])
torch_roots = [root for root in roots if str(root.get("spec", "")).startswith("py-torch@")]

bad = []
for root in torch_roots:
    spec = str(root.get("spec", ""))
    if "+nccl" not in spec or "+distributed" not in spec:
        bad.append(spec)

if bad:
    sys.exit(1)
```

Expected behavior of this code:

- If lock has no `py-torch` root: fail.
- If any `py-torch` root lacks `+nccl` or `+distributed`: fail.
- Otherwise print concretized torch spec and continue to install.

## Expected vs Observed Outcomes

### 1) Staging Build

- Expected:
  - Run as container user defined by launch scripts.
  - Use staging mechanism in repo and complete install.
- Observed:
  - Ran as `kvothe` (`uid=1000 gid=1000`) in container.
  - Used `pkg/zephyr/staging/pytorch_latest/build.sh` -> `tools/zephyr_stage_spack.sh`.
  - Completed successfully (`"status": "ok"` in `final_status.json`).

### 2) PyTorch Concretization Variant Gate

- Expected:
  - `py-torch` concretized with `+cuda +nccl +distributed`.
- Observed:
  - Gate output:
    `PYTORCH_CONCRETIZED=py-torch@2.9.0+cuda+distributed+nccl cuda_arch=61,75,80,86,89,90`
  - Guard passed (`FORBIDDEN_MISSING=0` for configured forbidden names).

### 3) Core Package Presence in Staged Lock

- Expected:
  - Roots include `py-torch`, `py-jax`, `py-jaxlib+cuda`, `py-triton`, `llvm`.
- Observed:
  - `py-torch@2.9.0+cuda+distributed+nccl cuda_arch=61,75,80,86,89,90`
  - `py-jax@0.7.0`
  - `py-jaxlib@0.7.0+cuda cuda_arch=61,75,80,86,89,90`
  - `py-triton@3.4.0`
  - `llvm@20.1.8+clang+lldb`

### 4) Post-Build GPU Verification Scripts

- Expected:
  - PyTorch and JAX import and see CUDA GPUs.
- Observed (`verify_pkg_zephyr.log`, `verify_gpu.log`):
  - PyTorch CUDA available: `True`
  - Device count: `2`
  - GPU: `NVIDIA GeForce GTX 1070 Ti`
  - JAX devices: `[CudaDevice(id=0), CudaDevice(id=1)]`
  - Verification completed successfully.

### 5) Non-Trivial GPU Workloads

- Expected:
  - PyTorch/JAX/Triton execute meaningful GPU tensor workloads without CPU fallback.
- Observed:
  - PyTorch (batched FP16 GEMM + backward):
    - `torch_loss 2048.827392578125`
    - `torch_elapsed_sec 0.681`
    - `torch_max_mem_mb 840.13`
    - `torch_distributed_nccl True`
  - JAX (JIT matmul + nonlinear loop):
    - `jax_result_mean -0.0002944469451904297`
    - `jax_elapsed_sec 0.704`
    - `jax_device cuda:0`
  - Triton (custom kernel, 20 launches):
    - `triton_elapsed_sec 16.905`
    - `triton_max_error 0.0`
    - `gpu_name NVIDIA GeForce GTX 1070 Ti`

## Notes / Pitfalls Encountered

- `spack env activate` must target the staged directory (`-d <stage_env>`), otherwise a default env may be created/activated.
- Triton JIT kernel definitions from stdin can fail source introspection (`inspect`); use a real `.py` file for Triton workload checks.

