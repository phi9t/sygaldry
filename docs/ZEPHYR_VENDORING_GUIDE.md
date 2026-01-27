# Zephyr Container Infra Vendoring Guide

This guide explains how to vendor the hermetic Zephyr runtime into another repo.

## Model

- Heavy stack comes from a prebuilt Spack snapshot image.
- Application stack is installed with uv on top.
- Consumer repos never rebuild Spack.
- Launcher and verifier UX remains the same (`repoctl`/`jobctl`) in all modes.

## Preconditions

- Docker daemon running
- NVIDIA runtime available (`docker info | grep -i nvidia`)
- Snapshot image and digest known

## Install (new repo)

Run from this `sygaldry` repo:

```bash
tools/zephyr_vendor_infra.sh install \
  --target-repo /path/to/target-repo \
  --snapshot-image ghcr.io/phi9t/sygaldry/zephyr:spack-YYYYMMDD \
  --snapshot-digest <64-hex-digest>
```

Result in target repo:

```text
.sygaldry/zephyr/
├── bin/repoctl
├── bin/jobctl
├── Dockerfile.zephyr
├── build_repo_image.sh
├── container/
├── lib/
├── VERSION
└── infra.yaml
```

## Verify in target repo

```bash
.sygaldry/zephyr/bin/repoctl config show
.sygaldry/zephyr/bin/repoctl verify spack
.sygaldry/zephyr/bin/repoctl verify uv-layering --no-gpu
```

## Standard vs Derived image modes

`infra.yaml` includes:

- `image_ref` - digest-pinned standard runtime image
- `base_image_ref` - digest-pinned base for derived image builds
- `runtime_image` - local/tagged derived runtime image
- `image_mode` - `standard|auto|derived`

Behavior:

- `standard`: always use `image_ref`
- `auto`: use `runtime_image` if present locally; otherwise fallback to `image_ref`
- `derived`: require `runtime_image`

## Build and verify a repo-derived image

```bash
# Build local derived image FROM base_image_ref
.sygaldry/zephyr/bin/repoctl image build --repo .

# Verify derived-image label contract + run verify-spack
.sygaldry/zephyr/bin/repoctl verify image --repo .
```

## Runtime usage in target repo

```bash
# Interactive shell
.sygaldry/zephyr/bin/repoctl shell

# Run one command in run-job mode
.sygaldry/zephyr/bin/repoctl run -- python -c 'print(\"ok\")'

# Background job mode
.sygaldry/zephyr/bin/jobctl run --job smoke -- "python -c 'print(123)'"
.sygaldry/zephyr/bin/jobctl status --job smoke
```

## Update vendored kit

```bash
tools/zephyr_vendor_infra.sh update --target-repo /path/to/target-repo
```

To roll forward snapshot pin:

```bash
tools/zephyr_vendor_infra.sh update \
  --target-repo /path/to/target-repo \
  --snapshot-image ghcr.io/phi9t/sygaldry/zephyr:spack-YYYYMMDD \
  --snapshot-digest <64-hex-digest>
```

To set explicit image mode/runtime tag:

```bash
tools/zephyr_vendor_infra.sh update \
  --target-repo /path/to/target-repo \
  --image-mode auto \
  --runtime-image myrepo/zephyr:dev
```

## Validate kit integrity

```bash
tools/zephyr_vendor_infra.sh check --target-repo /path/to/target-repo
```

`check` fails if `infra.yaml` is missing or the image is not digest-pinned.
