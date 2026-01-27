# Zephyr Container Adapt Skill — Release & Launch (GA)

## Release Metadata

| Field | Value |
|------|-------|
| Release | GA |
| Skill | `zephyr-container-adapt` |
| Date | 2026-02-18 |
| Primary audience | Internal engineering teams |
| Owners | Sygaldry container infra maintainers |
| Scope | Vendored `.sygaldry/zephyr` runtime for downstream repos, with standard + derived image modes |

## Executive Summary

`zephyr-container-adapt` is now GA for internal downstream repos.  
It provides a repo-vendored, hermetic container runtime that preserves the Zephyr experience:

- Same operational UX: `repoctl` + `jobctl`
- Same validation UX: `repoctl verify ...`
- Same dependency policy: Spack owns heavy ML stack; uv layers app packages on top
- New dual image model:
  - pinned standard snapshot runtime
  - repo-derived runtime image built `FROM` pinned base snapshot

This launch standardizes adoption without requiring consumer repos to rebuild Spack.

## What Is Included In GA

### Functionalities

| Capability | Interface | GA behavior |
|------|------|------|
| Vendor runtime into target repo | `tools/zephyr_vendor_infra.sh install` | Creates `.sygaldry/zephyr` kit, writes `infra.yaml`, enforces pinning policy |
| Update vendored runtime | `tools/zephyr_vendor_infra.sh update` | Refreshes kit and config; supports mode/image updates |
| Validate vendored runtime | `tools/zephyr_vendor_infra.sh check` | Validates required files and mode-specific pinning constraints |
| Runtime shell/command | `.sygaldry/zephyr/bin/repoctl shell|run` | Uses mode-resolved runtime image |
| Background jobs | `.sygaldry/zephyr/bin/jobctl ...` | Same job lifecycle (`run/status/tail/stop/health`) |
| Standard image mode | `image_mode=standard` | Always use digest-pinned `image_ref` |
| Auto image mode | `image_mode=auto` | Use `runtime_image` if local image exists; fallback to `image_ref` |
| Derived image mode | `image_mode=derived` | Require local `runtime_image`; actionable failure if missing |
| Build derived image | `repoctl image build` | Builds runtime image from `base_image_ref` via `Dockerfile.zephyr` |
| Verify derived image contract | `repoctl verify image` | Checks derived label contract and can run spack verification |
| Spack runtime verification | `repoctl verify spack` | Same framework/GPU checks as Zephyr verify entrypoint |
| uv layering verification | `repoctl verify uv-layering` | Validates Spack+uv ownership/provenance contract |

## Compatibility & Prerequisites

### Host prerequisites

- Docker daemon available
- NVIDIA runtime available (`docker info | grep -i nvidia`)
- Access to pinned snapshot image reference + digest

### Policy constraints

- Consumer repos must not run Spack rebuild/install
- `image_ref` must be digest-pinned
- `base_image_ref` must be digest-pinned for `auto|derived`
- `runtime_image` is allowed to be a local tag

### Backward compatibility

- Existing vendored repos can be updated in place with `tools/zephyr_vendor_infra.sh update`
- Missing older fields in `infra.yaml` are defaulted where possible during `check`/load

## User Manual

### 1) Install into a new repo

Run from `sygaldry`:

```bash
tools/zephyr_vendor_infra.sh install \
  --target-repo /path/to/target-repo \
  --snapshot-image ghcr.io/phi9t/sygaldry/zephyr:spack-YYYYMMDD \
  --snapshot-digest <64-hex-digest> \
  --image-mode auto \
  --runtime-image myrepo/zephyr:dev
```

Creates:

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

### 2) Configure image mode

`infra.yaml` keys:

- `image_ref` (digest-pinned standard runtime)
- `base_image_ref` (digest-pinned base for derived builds)
- `runtime_image` (local/tagged derived runtime image)
- `image_mode` (`standard|auto|derived`)

Recommended defaults:

- `image_mode: auto` for gradual derived-image adoption
- `runtime_image: <repo>/zephyr:dev`

### 3) Run baseline validation in target repo

```bash
.sygaldry/zephyr/bin/repoctl config show
.sygaldry/zephyr/bin/repoctl verify image --skip-spack
.sygaldry/zephyr/bin/repoctl verify spack
.sygaldry/zephyr/bin/repoctl verify uv-layering --no-gpu
```

### 4) Build and use a derived runtime image

```bash
# Build runtime image FROM base_image_ref
.sygaldry/zephyr/bin/repoctl image build --repo .

# Verify label contract (+spack checks by default)
.sygaldry/zephyr/bin/repoctl verify image --repo .
```

If you want strict derived mode:

```bash
tools/zephyr_vendor_infra.sh update \
  --target-repo /path/to/target-repo \
  --image-mode derived \
  --runtime-image myrepo/zephyr:dev \
  --base-image-ref ghcr.io/phi9t/sygaldry/zephyr:spack-YYYYMMDD@sha256:<digest>
```

### 5) Day-2 operations

```bash
# Interactive shell
.sygaldry/zephyr/bin/repoctl shell

# One-off command
.sygaldry/zephyr/bin/repoctl run -- python -c 'print("ok")'

# Background job
.sygaldry/zephyr/bin/jobctl run --job train -- "python train.py"
.sygaldry/zephyr/bin/jobctl status --job train
.sygaldry/zephyr/bin/jobctl tail --job train --lines 40
```

### 6) Update/upgrade

```bash
# Refresh kit + preserve existing settings
tools/zephyr_vendor_infra.sh update --target-repo /path/to/target-repo

# Roll snapshot forward
tools/zephyr_vendor_infra.sh update \
  --target-repo /path/to/target-repo \
  --snapshot-image ghcr.io/phi9t/sygaldry/zephyr:spack-YYYYMMDD \
  --snapshot-digest <64-hex-digest>

# Validate config/integrity
tools/zephyr_vendor_infra.sh check --target-repo /path/to/target-repo
```

## Verification & Validation

### Pre-release checks (maintainer side)

Run before publishing vendor updates:

```bash
bash -n tools/zephyr_vendor_infra.sh \
  portable/zephyr-container-infra/lib/infra_config.sh \
  portable/zephyr-container-infra/bin/repoctl \
  portable/zephyr-container-infra/bin/jobctl \
  portable/zephyr-container-infra/build_repo_image.sh
```

### Target-repo validation matrix

| Scenario | Command(s) | Expected result |
|------|------|------|
| Kit integrity | `tools/zephyr_vendor_infra.sh check --target-repo <repo>` | Passes; required files and mode fields valid |
| Config resolution | `repoctl config show` | Prints `image_mode` and `effective_image` |
| Auto fallback | `repoctl verify image --skip-spack` with missing runtime image | Reports standard fallback, exits success |
| Derived enforce | `image_mode=derived`, runtime image missing, `repoctl verify image --skip-spack` | Fails with build instruction |
| Derived build path | `repoctl image build --repo .` then `repoctl verify image --skip-spack` | Passes label contract |
| Spack runtime | `repoctl verify spack` | Framework/GPU checks pass |
| uv layering | `repoctl verify uv-layering --no-gpu` | Layering/provenance checks pass |
| Job lifecycle | `jobctl run/status/tail` | Job metadata/log flow works |

### Launch acceptance criteria

Release is accepted when:

1. Vendor `install/update/check` flows pass in representative repos.
2. Both `standard` and `auto` modes validate successfully.
3. `derived` mode failure path is clear and actionable when runtime image is absent.
4. Derived mode success path (build + verify) is confirmed at least once.
5. Spack and uv-layering verification pass after vendoring.

## Rollout, Support, and Rollback

### Rollout (GA)

1. Publish this doc and announce GA to internal engineering channels.
2. Update target repos via vendor tool.
3. Run validation matrix in each adopted repo.

### Support ownership

- First-line support: Sygaldry container infra maintainers
- Escalation trigger: repeated validation failures across repos (pinning/mode mismatch, derived label mismatch, Docker/NVIDIA host issues)

### Rollback runbook

If derived mode introduces failures:

1. Set `image_mode` back to `standard`.
2. Pin known-good `image_ref` digest.
3. Re-run:
   - `tools/zephyr_vendor_infra.sh check --target-repo <repo>`
   - `repoctl verify image --skip-spack`
   - `repoctl verify spack`

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Unpinned image refs | Reproducibility drift | Hard-fail in `check` and config loader |
| Derived image missing in derived mode | Runtime failure | Actionable `repoctl verify image` failure and build command |
| Derived image built from wrong base | ABI/runtime mismatch risk | Required `sygaldry.base_image_ref` label contract check |
| Host Docker/NVIDIA inconsistency | Validation/run failures | Explicit prerequisite checks + no-GPU validation mode where applicable |

## References (Canonical Sources)

- Skill behavior: `skills/zephyr-container-adapt/SKILL.md`
- Vendoring manual: `docs/ZEPHYR_VENDORING_GUIDE.md`
- Portable kit guide: `portable/zephyr-container-infra/README.md`
- Vendor CLI: `tools/zephyr_vendor_infra.sh`
- Runtime CLI: `portable/zephyr-container-infra/bin/repoctl`
- Config resolution: `portable/zephyr-container-infra/lib/infra_config.sh`
