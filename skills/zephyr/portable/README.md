# Portable Launcher

This folder provides a thin wrapper for repositories that already have a vendored MLSys runtime kit.

## Setup

```bash
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILL_DIR="$CODEX_HOME/skills/zephyr"
TARGET_REPO=/path/to/my-repo

"$SKILL_DIR/scripts/zephyr_mlsys_vendor.sh" install \
  --target-repo "$TARGET_REPO" \
  --snapshot-ref ghcr.io/my-org/zephyr:spack@sha256:<64-hex-digest>

cp "$SKILL_DIR/portable/launch-mlsys.sh" "$TARGET_REPO/launch-mlsys.sh"
chmod +x "$TARGET_REPO/launch-mlsys.sh"
```

## Usage

```bash
cd "$TARGET_REPO"
./launch-mlsys.sh hf-transformers
./launch-mlsys.sh vllm --no-validate
MLSYS_DISABLE_GPU=1 ./launch-mlsys.sh hf-datasets --no-validate
```

## Notes

- Runtime files live under `.codex-zephyr-mlsys/` in the target repo.
- Override image at runtime with `SYGALDRY_SNAPSHOT_REF=<digest-ref>`.
