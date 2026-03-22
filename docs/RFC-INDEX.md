# RFC Index

**Last updated:** 2026-03-22
**Total RFCs:** 0 open (44 created, 44 closed as complete or N/A)

---

## All RFCs

All 44 RFCs are closed. See Closed RFCs below.

---

## Closed RFCs

| # | Title | Resolution |
|---|-------|------------|
| RFC-001 | Sygaldry Architectural Review | Closed — documentary review only; no actionable code changes; [COMMENT_NEEDED] placeholders are not implementable items |
| RFC-005 | Dead Code Purge | Done — `orchestration.go`, `cmd/run`, `workflows.Orchestrate` removed |
| RFC-009 | Issue Discovery: --sources Flag | Done — `--sources` flag fully implemented in `discover_issues.py` (lines 558–582) |
| RFC-011 | Codebase Simplification Audit | Catalog only — individual items tracked as separate RFCs |
| RFC-018 | Temporal Validation Multi-Error | Done — `validatePlan` collects all errors via `errors.Join` |
| RFC-021 | Temporal Activity Heartbeats | Done — heartbeat goroutine in `runCommand` + `DownloadFile`; `HeartbeatTimeout: 30s` in pipeline |
| RFC-025 | Python Version Default Mismatch | Done — `launch_container.sh` default changed 3.12→3.13 with sync comment |
| RFC-026 | Env Var Documentation Gaps | Done — `ZEPHYR_*` and deprecated `SYGALDRY_*` vars documented in CLAUDE.md |
| RFC-027 | Extract should_build_decision from cfg(test) | Merged into RFC-017 (finding 1 is identical; RFC-017 is the superseding document) |
| RFC-030 | Git Ops Staged Files Safety | Done — sensitive-file filter in `commit` and `worktree-commit` in `git_ops.sh` |
| RFC-034 | Temporal Search Attributes | N/A — no Temporal search attributes exist in the codebase |
| RFC-036 | Worker Graceful Shutdown | Done — `WorkerStopTimeout: 30s`, `DeadlockDetectionTimeout: 5s`, `slog` in worker main |
| RFC-038 | Multi-Engine Heartbeat Sleep | Done — `activity.RecordHeartbeat` on inter-round sleep in `multi_engine.go` |
| RFC-007 | Structured Logging in Activity Code | Done — `"log"` import replaced with `"log/slog"`; 4 `log.Printf` calls in `emitEvent()` replaced with `slog.Warn` |
| RFC-008 | Remove LauncherPath from ContainerJobSpec | Done — removed `LauncherPath` from pipeline spec, activity input, and orchestrate merge path; container launcher resolution now uses built-in lookup only |
| RFC-024 | Stop Hardcoding HF Cache Dir | Done — HF download activities now honor `CacheDir`, then `HF_HOME`, then `/opt/hf_cache` |
| RFC-037 | Replace Hardcoded /tmp Paths in rfc_impl.go | Done — RFC workflow temp files, worktrees, and plans now use configurable `TempDir` from CLI/workflow input |
| RFC-029 | SAIL discover_issues Should Cover Rust Tests | Done — `discover_issues.py` now supports `rust_coverage`, uses configurable Go/Rust coverage file paths, and skips gracefully when `cargo llvm-cov` is unavailable |
| RFC-039 | Remove Commented Dead Code from Dockerfile | Done — removed the stale commented `setup_user_environment.sh` block from `container/dev_container.dockerfile` |
| RFC-040 | build_shared_caches Tuple → Struct | Done — `build_shared_caches()` now returns a named `SharedCaches` struct in `crates/zephyr/src/config.rs` |
| RFC-028 | ContainerJob Should Use zephyr Binary | Done — `ContainerJob` now prefers the `zephyr` binary, strips legacy `.sh` entrypoint suffixes, and only warns when it falls back to `launch_container.sh` |
| RFC-020 | Retire launch_container.sh | Done — replaced 646-line script with a thin shim that delegates to the `zephyr` binary; falls back with a clear error if binary is not built |
| RFC-017 | image.rs Production Visibility Cleanup | Done — `should_build_decision` now runs in production, `build_image()` calls it directly, unsafe libc calls are documented, and missing image timestamps emit a warning |
| RFC-041 | Cache detect_user_spec to Avoid docker info | Done — `ZEPHYR_ROOTLESS` now provides a config-backed override so launches can skip probing `docker info` on every run |
| RFC-035 | Add Remaining Test Coverage for orchestrate merge* Functions | Done — `merge_test.go` now covers the remaining orchestrate merge helpers plus `safeFilename`, `writePlanManifest`, and `printOutput` |
| RFC-022 | Workflow Versioning (GetVersion) | Done — `Pipeline`, `RFCImpl`, and `RFCTaskWorkflow` now all register inline `workflow.GetVersion` guards for replay-safe control-flow evolution |
| RFC-015 | validate_all.sh Modernization | Done — `validate_all.sh` now warns on unknown flags and skips Go validation sections cleanly when `go` is not installed |
| RFC-032 | Reduce --ipc=host and --net=host Exposure | Done — Zephyr now defaults to `--network=bridge`, `--ipc=shareable`, and `--shm-size=16g`, with opt-ins and legacy overrides for exceptions |
| RFC-033 | Add Resource Limits to docker run | Done — Zephyr now supports bounded `--memory`, `--cpus`, `--memory-swap`, and `--pids-limit`, with `SAIL_RUN=1` defaulting memory to `64g` |
| RFC-010 | Rust Host Module Testing | Done — `docker_args.rs`, `job.rs`, `lease.rs`, and `container/entrypoint.rs` now all carry focused unit-test modules instead of the near-zero coverage described in the RFC |
| RFC-014 | Rust Config and Paths Cleanup | Done — `config.rs` now uses path helpers instead of repeated `.display().to_string()` conversions, `projects_root` is surfaced in effective config output, and `paths.rs` uses named layout-version constants |
| RFC-023 | Query and Signal Handlers for Pipeline | Done — `Pipeline` now exposes a `status` query, honors a `cancel` signal, and uses named search attributes; `RFCImpl` now exposes task-progress status; `temporal/scripts/register_search_attributes.sh` registers the new search-attribute keys |
| RFC-019 | Rust Dead Code Cleanup | Done — removed the remaining dead-code suppressions by deleting unused error variants/helpers, scoping the CUDA-version helper to tests, and dropping stale `#[allow(dead_code)]` annotations |
| RFC-003 | Temporal Production Readiness | Done — worker config now supports YAML plus env/CLI overrides, `max_concurrent_activities`, and an HTTP `/healthz` endpoint via `temporal/cmd/worker` |
| RFC-031 | Add Explicit Dev-Only Unrestricted sudo Opt-In | Done — `ZEPHYR_DEV_SUDO=1` now explicitly opts the Zephyr launcher into `--user=0:0` for local debugging without widening the image’s default sudoers policy |
| RFC-004 | SAIL Supervisor Decomposition | Done — `WorkerManager` extracted to `worker_manager.py`, `TemporalProbe` to `temporal_probe.py`; `sail_supervisor.py` reduced to state-machine + CLI; all tests pass |
| RFC-006 | Rust Entrypoint Consolidation | Done — `build_rust_mode()` in `docker_args.rs` emits `--entrypoint zephyr`; `launch()` in `launcher.rs` uses it when `ZEPHYR_USE_RUST_ENTRYPOINTS=1` or image carries `sygaldry.zephyr.version` label; Dockerfile now sets both labels |
| RFC-002 | Rust as Container Infrastructure Foundation | Done — `tools/zephyr_job` deleted; `container/entrypoints/` (9 bash scripts) deleted; `bin/sygaldry` slimmed 256→149 lines; bash `job)` fallback replaced with clear error; all 9 entrypoints verified covered by `entrypoint.rs` |
| RFC-012 | Orchestrate Command Decomposition | Done — `internal/plan/` package created with `loader.go` (115L), `validator.go` (211L), `merger.go` (347L) and matching test files; `cmd/orchestrate/main.go` reduced 1003→372 lines; all tests pass |
| RFC-013 | Dockerfile Cache Layer Optimization | Done — merged apt cleanup+install layers; pinned Spack to `ARG SPACK_SHA`; fixed build-breaking bug (removed deleted `container/entrypoints/` COPY); updated `ENTRYPOINT` to `["zephyr", "entrypoint", "default"]`; added `GIT_COMMIT`/`BUILD_DATE` labels |
| RFC-016 | K3s YAML Path Externalization | Done — `k3s/lib/paths.env` defines all path defaults; `k3s-common.sh` sources and exports them; all 3 YAML templates use `${ZEPHYR_*}` variables with zero hardcoded `/mnt/data_infra` paths; `kentai` now requires explicit `--project-id` |
