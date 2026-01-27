# Zephyr Validation

Validation for the unified `skills/zephyr` skill, including hermetic vendoring and GPU workload burn-in.

## Prerequisites

- Docker daemon running.
- NVIDIA Docker runtime enabled.
- At least 2 visible GPUs for distributed checks.
- Digest-pinned snapshot reference.

Pinned snapshot used for current validation:

```text
ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c
```

## Static Gates

```bash
python3 skills/hermetic-skill-audit.py skills/zephyr
python3 skills/local-skills-sync/scripts/sync_local_skills.py --check
shellcheck -s bash -S warning skills/zephyr/scripts/*.sh skills/zephyr/portable/*.sh
python3 -m py_compile skills/zephyr/scripts/*.py
bash skills/zephyr/scripts/validate_hermetic_infra.sh skills/zephyr
bash skills/zephyr/scripts/validate_hermetic_mlsys.sh skills/zephyr
```

## Hermetic Runtime Burn-In (Canonical)

```bash
skills/zephyr/scripts/validate_hermetic_runtime_suite.sh \
  --snapshot-ref ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c \
  --mode burnin \
  --burnin-iterations 5
```

Expected:

- vendoring succeeds in a new temporary repo
- vendored runtime passes image/spack verification
- PyTorch NCCL mini-training passes
- JAX multi-GPU mini-training passes
- LLVM pass pipeline executes and verifies transformed IR
- CUDA kernel check passes against CPU reference
- repeated iterations pass with isolated project IDs
- report JSON and logs are emitted under the suite output directory

## MLSys Runtime Smoke In Separate Repo

```bash
TMP_REPO="$(mktemp -d)"
SNAPSHOT_REF="ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c"

skills/zephyr/scripts/zephyr_mlsys_vendor.sh install \
  --target-repo "${TMP_REPO}" \
  --snapshot-ref "${SNAPSHOT_REF}" \
  --force

"${TMP_REPO}/.codex-zephyr-mlsys/bin/launch-mlsys.sh" hf-transformers --no-validate
"${TMP_REPO}/.codex-zephyr-mlsys/bin/launch-mlsys.sh" vllm --no-validate
```

Expected:

- runtime kit launches from the isolated repo
- overlay build succeeds with pinned image
- no dependency on source checkout paths

## Packaging Gate

```bash
skills/zephyr/scripts/package_infra.sh \
  --out-dir /tmp/zephyr-dist \
  --version 2026.02.25 \
  --smoke-mode skip \
  --force
```

Expected:

- deterministic artifact, manifest, and provenance emitted
- packaged skill validates and vendors correctly when extracted
