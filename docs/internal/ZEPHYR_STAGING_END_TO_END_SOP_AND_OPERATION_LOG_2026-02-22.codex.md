# Zephyr Staging Build Operations Log + SOP (End-to-End)

## Summary
Produce a single authoritative document that is both:
1. A reusable SOP for future runs.
2. A complete incident-grade operational log of the recent end-to-end chain:
   - Spack staging (`pytorch_latest`)
   - MLSys sequential image builds (resource-limited mode: one env at a time)
   - GPU/runtime verification
   - Registry publication to GHCR
   - All failures, root causes, and fixes applied

Chosen scope/output:
- Scope: **End-to-end chain**
- Output style: **SOP + Incident log**

## Deliverable
Create `docs/ZEPHYR_STAGING_END_TO_END_SOP_AND_OPERATION_LOG_2026-02-22.md` with the following fixed structure.

## Document Structure (Decision-Complete)

### 1. Header and Provenance
- Title, date, author/agent, repo commit SHA at time of run.
- Primary objective statement.
- Environment snapshot:
  - Host context (`/mnt/data_infra/workspace/sygaldry`)
  - Container/user constraints (`kvothe`, GPU-only policy)
  - Registry target (`ghcr.io/phi9t/sygaldry`)

### 2. System Implementation Map
Describe implementation entrypoints and responsibilities:
- `pkg/zephyr/staging/pytorch_latest/build.sh` (staging entrypoint)
- `tools/zephyr_stage_spack.sh` (stage orchestration, status files, checks, fail codes)
- `tools/zephyr_concretize_analyze.sh` (concretization analyzer)
- `container/snapshot_mlsys.sh` (MLSys image build loop and verification trigger)
- `container/verify_mlsys.sh` (post-build metadata/provenance/GPU/auto-activation tests)
- Env definitions:
  - `container/config/envs/*.yaml`
  - `skills/zephyr-mlsys-env/envs/*.yaml`
- Build Dockerfile path and constraints (`container/mlsys_venv.dockerfile` with BuildKit cache mounts)

For each, include:
- Inputs, outputs, key guards/gates, and failure behavior.

### 3. SOP: Standard Run Procedure (Reusable)
Provide normalized step-by-step procedure with exact commands and required env vars.

Sections:
1. Preconditions checklist
2. Stage Spack run procedure
3. Post-concretization verification checklist (must include `py-torch +nccl +distributed`)
4. Build MLSys images sequentially (explicitly one env at a time)
5. Post-build GPU verification procedure
6. Registry publish procedure (GHCR default and dated tags policy)
7. Exit criteria and artifact retention requirements

Each SOP step includes:
- Command
- Expected outputs
- Artifact paths to check
- Pass/fail criteria
- Recovery action pointer

### 4. Execution Log (Chronological, Incident Grade)
Capture dated timeline with run IDs and logs:
- Spack stage run roots and status files
- MLSys run directories in `/tmp/*`
- Push log files and outcomes

For each event:
- Timestamp window
- Action performed
- Observed outcome
- Evidence path(s)

### 5. Issues and Fixes Ledger
Create a table:
- `Issue ID`
- `Symptom`
- `Root cause`
- `Fix implemented`
- `Files changed`
- `Validation evidence`
- `Residual risk`

Include at least:
- PyTorch variant concretization gate requirement
- `hf-datasets` provenance mismatch fix (`pandas` ownership adjustment)
- `vllm`/`llm-serving-all` missing `networkx`
- `megatronlm` brittle import/auto-activation check hardening
- BuildKit export stall behavior and minimal-context workaround path
- Docker context stale path issue and `.dockerignore` fix
- Docker Hub permission denial and GHCR push strategy
- Dated-tag publication via manifest-copy (`docker buildx imagetools create`)

### 6. Operational Controls for Future Runs
Define mandatory controls:
- One-env-at-a-time build policy
- Required verification gates before promotion
- Registry push fallback hierarchy
- Required logs to archive
- Fail-fast conditions and retry ceilings

### 7. SOP Checklists (Copy/Paste)
- Pre-run checklist
- During-run checklist
- Post-run signoff checklist

### 8. Appendix
- Canonical command snippets used
- Artifact path index
- Image/tag matrix (local and remote)
- Known limitations and escalation playbook

## Public APIs / Interfaces / Types
No runtime API changes.
Documentation defines operational interface contracts for:
- Required env vars and command entrypoints.
- Required artifacts and pass/fail signals.
- Promotion criteria for image tags.

## Source Material to Reference in the Document
Use these as authoritative evidence:
- Existing verification doc:
  - `docs/ZEPHYR_POST_SPACK_BUILD_VERIFICATION_PYTORCH_LATEST_2026-02-21.md`
- Script implementations:
  - `tools/zephyr_stage_spack.sh`
  - `pkg/zephyr/staging/pytorch_latest/build.sh`
  - `container/snapshot_mlsys.sh`
  - `container/verify_mlsys.sh`
- Run logs/artifacts:
  - `/tmp/mlsys-seq-finalize3-20260222-021735/summary.log`
  - `/tmp/mlsys-llm-bk-minctx-20260222-024320/verify.log`
  - `/tmp/push-images-ghcr-imagetools-20260222-050510.log`
  - plus referenced `/tmp/mlsys-*` and `/tmp/push-images*` logs used in timeline

## Validation / Acceptance Criteria
Document is complete when:
1. SOP can be executed by a new operator without making decisions.
2. Every critical fix includes root cause + changed file path + validation evidence.
3. Commands and paths are internally consistent and copy-paste runnable.
4. Includes explicit success criteria for:
   - Stage concretization/install
   - GPU verification
   - Image publish state
5. Includes rollback/recovery guidance for each known failure mode.

## Assumptions and Defaults
- Default registry is GHCR (`ghcr.io/phi9t/sygaldry`), not Docker Hub.
- GPU-only policy remains mandatory.
- Build policy remains sequential (resource constrained).
- Dated tags are aliases of verified latest tags when direct push stalls.
- This SOP is authoritative for the 2026-02 run lineage and should be versioned by date.
