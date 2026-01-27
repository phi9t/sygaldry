# LLM Scenario Failure Review (Hugging Face, vLLM, sglang)

## Scope and Context
- Snapshot image under test: `sygaldry/zephyr:spack-20260212-082355`
- Validation intent: verify snapshot viability for transformers/Hugging Face, vLLM, and sglang scenarios without rebuilding Spack.
- Evidence source: logs in `container/logs/snapshot-verify-20260212-082355/`.

## Outcome Summary
- Hugging Face baseline is partially viable: transformers stack installs and imports when `datasets` is excluded.
- vLLM is currently not viable under the active Spack-pinned layering constraints.
- sglang is currently not viable as a complete scenario under the active Spack-pinned layering constraints.

## Detailed Failure Modes with Evidence

## 1) Hugging Face / UV Layering Failure
### Failure Mode HF-1: `datasets==0.0.9` sdist/cache failure in T8.1
Verification stopped before later T8 checks due missing `DESCRIPTION.rst` in UV sdist cache path.

Evidence:
- `container/logs/snapshot-verify-20260212-082355/50_verify_uv_layering_with_vllm.log:10`
- `container/logs/snapshot-verify-20260212-082355/50_verify_uv_layering_with_vllm.log:11`
- `container/logs/snapshot-verify-20260212-082355/50_verify_uv_layering_with_vllm.log:12`

Excerpt:
```text
FAIL: UV venv creation
output: FileNotFoundError: [Errno 2] No such file or directory:
'/home/kvothe/.cache/uv/sdists-v9/pypi/datasets/0.0.9/.../DESCRIPTION.rst'
```

### HF Recovery Evidence: Transformers path works when `datasets` is removed
The fallback run without `datasets` completed baseline UV layering checks for transformers.

Evidence:
- `container/logs/snapshot-verify-20260212-082355/53_manual_uv_layering_no_datasets_nohf.log:50`
- `container/logs/snapshot-verify-20260212-082355/53_manual_uv_layering_no_datasets_nohf.log:51`
- `container/logs/snapshot-verify-20260212-082355/53_manual_uv_layering_no_datasets_nohf.log:52`
- `container/logs/snapshot-verify-20260212-082355/53_manual_uv_layering_no_datasets_nohf.log:53`
- `container/logs/snapshot-verify-20260212-082355/53_manual_uv_layering_no_datasets_nohf.log:54`

Excerpt:
```text
UV_BASE_INSTALL_OK
SPACK_PROVENANCE_OK
UV_PROVENANCE_OK
NO_NVIDIA_OK
TRANSFORMERS_GPU_OK
```

## 2) vLLM Failures
### Failure Mode VLLM-1: Constrained install selects legacy `vllm==0.1.3` and fails build/import
In the constrained layering flow, vLLM build fails due CUDA symbol mismatch via torch import.

Evidence:
- `container/logs/snapshot-verify-20260212-082355/53_manual_uv_layering_no_datasets_nohf.log:59`
- `container/logs/snapshot-verify-20260212-082355/53_manual_uv_layering_no_datasets_nohf.log:88`
- `container/logs/snapshot-verify-20260212-082355/53_manual_uv_layering_no_datasets_nohf.log:89`

Excerpt:
```text
× Failed to build `vllm==0.1.3`
ImportError: /usr/local/cuda/lib64/libcusparse.so.12: undefined symbol:
__nvJitLinkGetErrorLogSize_12_9, version libnvJitLink.so.12
```

### Failure Mode VLLM-2: Modern vLLM versions unsatisfiable vs pinned stack
Solver rejects `vllm>=0.8.0` because current pinned ecosystem (notably torchvision/numba compatibility envelope) cannot satisfy vLLM requirements.

Evidence:
- `container/logs/snapshot-verify-20260212-082355/57_vllm_sglang_custom_constraints2.log:49`
- `container/logs/snapshot-verify-20260212-082355/57_vllm_sglang_custom_constraints2.log:50`
- `container/logs/snapshot-verify-20260212-082355/57_vllm_sglang_custom_constraints2.log:98`
- `container/logs/snapshot-verify-20260212-082355/57_vllm_sglang_custom_constraints2.log:101`
- `container/logs/snapshot-verify-20260212-082355/57_vllm_sglang_custom_constraints2.log:103`

Excerpt:
```text
× No solution found when resolving dependencies
...
because vllm>=0.11.1 depends on numba==0.61.2 and numba==0.62.0rc2
...
we can conclude that vllm>=0.8.0 cannot be used
...
requirements are unsatisfiable
```

### Failure Mode VLLM-3: Unconstrained path attempts to override core stack
When constraints are relaxed too far, UV starts resolving pip `torch` and multiple `nvidia-*` artifacts, violating the layering policy.

Evidence:
- `container/logs/snapshot-verify-20260212-082355/55_vllm_sglang_unconstrained_no_activate.log:10`
- `container/logs/snapshot-verify-20260212-082355/55_vllm_sglang_unconstrained_no_activate.log:13`
- `container/logs/snapshot-verify-20260212-082355/55_vllm_sglang_unconstrained_no_activate.log:18`

Excerpt:
```text
Downloading nvidia-nvshmem-cu12 ...
Downloading nvidia-cusparselt-cu12 ...
Downloading torch (873.3MiB)
```

## 3) sglang Failures
### Failure Mode SGL-1: `sglang` installed but venv cannot import torch
Direct UV venv path without `.pth` Spack wiring yielded `ModuleNotFoundError: No module named 'torch'`.

Evidence:
- `container/logs/snapshot-verify-20260212-082355/58_sglang_only_check.log:51`
- `container/logs/snapshot-verify-20260212-082355/58_sglang_only_check.log:53`

Excerpt:
```text
Traceback (most recent call last):
...
ModuleNotFoundError: No module named 'torch'
```

### Failure Mode SGL-2: `uv-install.sh sglang` missing transitive runtime deps
With canonical installer flow, import fails first on `pybase64`, then on `pydantic` even after adding `pybase64`.

Evidence:
- `container/logs/snapshot-verify-20260212-082355/59_sglang_uv_install_check.log:67`
- `container/logs/snapshot-verify-20260212-082355/59_sglang_uv_install_check.log:69`
- `container/logs/snapshot-verify-20260212-082355/60_sglang_with_pybase64_check.log:57`
- `container/logs/snapshot-verify-20260212-082355/60_sglang_with_pybase64_check.log:72`
- `container/logs/snapshot-verify-20260212-082355/60_sglang_with_pybase64_check.log:74`

Excerpts:
```text
ModuleNotFoundError: No module named 'pybase64'
```
```text
 + pybase64==1.4.3
...
ModuleNotFoundError: No module named 'pydantic'
```

### Failure Mode SGL-3: `sglang[all]` fully unsatisfiable in current pinned envelope
Solver rejects all tested `sglang[all]` ranges due torch/triton/torchaudio and related version coupling.

Evidence:
- `container/logs/snapshot-verify-20260212-082355/61_sglang_all_check.log:5`
- `container/logs/snapshot-verify-20260212-082355/61_sglang_all_check.log:6`
- `container/logs/snapshot-verify-20260212-082355/61_sglang_all_check.log:931`
- `container/logs/snapshot-verify-20260212-082355/61_sglang_all_check.log:933`
- `container/logs/snapshot-verify-20260212-082355/61_sglang_all_check.log:935`

Excerpt:
```text
× No solution found when resolving dependencies
...
all versions of sglang[all] cannot be used
requirements are unsatisfiable
hint: Pre-releases are available ...
```

## Root Cause Synthesis
1. The verification path couples baseline Hugging Face checks to a fragile `datasets` install path that can fail from cache/sdist corruption.
2. vLLM and sglang are outside the currently compatible solution space of the pinned Spack+UV ecosystem (torch/torchvision/torchaudio/triton/numba constraints).
3. Relaxing constraints to force vLLM/sglang viability causes policy violations by reintroducing pip torch/nvidia packages.
4. Current sglang install path shows incomplete transitive dependency closure when installed as plain `sglang`.

## Next Steps Plan

## Phase 1: Stabilize Baseline HF Validation
1. Split baseline HF checks from advanced LLM serving checks.
2. Change baseline package set to `transformers tokenizers accelerate` only.
3. Move `datasets` to optional check with isolated cache and non-blocking failure classification.
4. Always run baseline with fresh per-run UV cache dir.

Acceptance:
1. Baseline UV layering passes consistently with no cache-path file errors.
2. Provenance checks (`SPACK_PROVENANCE`, `UV_PROVENANCE`, `NO_NVIDIA`) pass.

## Phase 2: Separate vLLM/sglang Compatibility Matrix Gate
1. Create dedicated script stage for `vllm` and `sglang` resolution attempts.
2. Emit structured result for each package:
- `resolver_status` (`ok`/`unsat`/`build_fail`)
- `selected_version`
- `root_cause_summary`
3. Keep this stage non-blocking for baseline snapshot validity, but blocking for “serving-ready” release label.

Acceptance:
1. Resolver outcomes are deterministic and fully logged.
2. No silent hangs or ambiguous failures.

## Phase 3: Define Compatible Stack Contract
1. Produce explicit compatibility matrix for:
- torch
- torchvision
- torchaudio
- triton
- numba
- vllm
- sglang
2. Pick one supported tuple for this CUDA base or document “not supported” for current snapshot line.
3. Enforce tuple via scenario-specific constraints/lockfile (without overriding Spack-owned core stack).

Acceptance:
1. If supported tuple exists: vLLM and sglang scenario imports pass under policy.
2. If no tuple exists: gate reports “unsupported with current Spack lock” and exits cleanly.

## Phase 4: Tighten Policy and Transitive Dependency Validation
1. Add explicit guard that no pip `torch*` or non-Spack `nvidia-*` packages are introduced in LLM scenario venvs.
2. For sglang, validate import-time transitive dependencies (`pybase64`, `pydantic`, others) as a first-class check.
3. Fail with actionable missing-dependency list.

Acceptance:
1. Policy violations are detected before runtime.
2. sglang import failure mode surfaces complete missing dependency list in one run.

## Deliverables
1. This review file: `container/logs/snapshot-verify-20260212-082355/LLM_FAILURE_REVIEW.md`
2. Follow-up implementation PR scope:
- `container/verify_uv_layering.sh` split baseline vs LLM serving stage.
- New LLM compatibility matrix helper script.
- Updated docs in verification process + system design.

## Recommended Release Classification for Current Snapshot
1. `transformers` baseline: **validated with caveat** (exclude `datasets` from blocking path).
2. `vllm`: **not currently validated/compatible** under pinned constraints.
3. `sglang`: **not currently validated/compatible** under pinned constraints.
