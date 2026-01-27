# Release Notes - 2026-02

Release date: 2026-02-18
Release type: Internal GA

## Summary

This release prepares the repository for internal adoption with a clean documentation surface, validated Zephyr vendoring workflows, and verified Temporal orchestration stability.

## Highlights

### Engineering Excellence Standard

- Added canonical software quality policy at `docs/ENGINEERING_EXCELLENCE_STANDARD.md`.
- Added review/refactor rubric at `docs/REVIEW_REFACTOR_RUBRIC.md`.
- Added strict, tiered quality gates:
  - `./validate_all.sh --quality-lint`
  - `./validate_all.sh --quality-test`
  - `./validate_all.sh --quality-coverage`
  - `./validate_all.sh --quality-all --quality-strict`
- Added language-specific quality runners under `tools/quality/`.
- Added coverage ratchet gate and baseline contract at `docs/quality/COVERAGE_BASELINE.yaml`.

### Zephyr Container Infrastructure

- Generalized vendorable kit at `.sygaldry/zephyr` for downstream repos.
- Preserved launcher and verifier experience via `repoctl` and `jobctl`.
- Standardized Spack + uv layering policy:
  - Spack snapshot provides heavy runtime dependencies.
  - uv installs repo/app dependencies on top.
  - Consumer repos do not rebuild Spack.
- Added image mode flexibility:
  - `standard` for pinned snapshot runtime.
  - `auto` for derived-image fallback behavior.
  - `derived` for strict local runtime image usage.
- Added derived-image workflow (`repoctl image build`, `repoctl verify image`) with base-image label contract checks.

### Temporal Workflow Engine

- Stable CLI contract: `run`, `validate`, `status`.
- Supported step-type coverage documented and aligned with implementation:
  - `command`, `download`, `docker_build`, `docker_push`, `package_build`,
    `container_job`, `hf_download_dataset`, `hf_download_model`
- Durable DAG execution with retry, conditional execution, template/import composition, and output interpolation.
- Operational observability includes:
  - per-step stdout/stderr logs
  - structured JSONL logs
  - run manifest
  - event stream + visual DAG inspection

## Documentation Changes

- Canonicalized doc map in `README.md`.
- Reduced duplication in `docs/ONBOARDING.md` and `portable/zephyr-container-infra/README.md`.
- Updated `temporal/README.md` to align with current step types and runtime behavior.
- Added release artifacts:
  - `docs/RELEASE_CHECKLIST.md`
  - `docs/RELEASE_READINESS_REVIEW_2026-02.md`

## Operational Cleanup

- Removed obsolete Docker Compose `version` key in `temporal/docker-compose.yml` to eliminate warning noise.
- Updated `AGENTS.md` skill listing guidance to point at `skills/LOCAL_SKILLS.md` as source of truth.

## Verification Snapshot

Validated during release prep:

- `cd temporal && go vet ./...`
- `cd temporal && go test ./...`
- `cd temporal && ./scripts/test-e2e.sh`
- `./validate_all.sh --quick` (fails on pre-existing Python lint debt in `multimodal_research/`)

Known environment caveat:

- `shellcheck` may be missing on some hosts; run full `./validate_all.sh` in CI or in an environment with `shellcheck` available.

## Known Risks

- GPU-dependent verification can vary by host NVIDIA runtime state.
- Derived image mode requires local runtime image presence; fallback behavior depends on `image_mode` policy.

## Rollback Guidance

If derived-image workflow causes runtime issues in a consumer repo:

1. Set `image_mode: standard` in `.sygaldry/zephyr/infra.yaml`.
2. Ensure `image_ref` is pinned to known-good digest.
3. Re-run:
   - `.sygaldry/zephyr/bin/repoctl verify image --skip-spack`
   - `.sygaldry/zephyr/bin/repoctl verify spack`
