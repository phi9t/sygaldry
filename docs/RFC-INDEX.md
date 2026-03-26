# RFC Index

**Last updated:** 2026-03-26
**Total RFCs:** 0 open (84 created, 84 closed as complete or N/A)

---

## Open RFCs

None. All RFCs have been resolved.

---

## Closed RFCs

| # | Title | Resolution |
|---|-------|------------|
| RFC-001 | Sygaldry Architectural Review | Closed — documentary review only |
| RFC-002 | Rust as Container Infrastructure Foundation | Done |
| RFC-003 | Temporal Production Readiness | Done — YAML config + `/healthz` |
| RFC-004 | SAIL Supervisor Decomposition | Done |
| RFC-005 | Dead Code Purge | Done — `orchestration.go`, `cmd/run`, `workflows.Orchestrate` removed |
| RFC-006 | Rust Entrypoint Consolidation | Done |
| RFC-007 | Structured Logging in Activity Code | Done — `log` → `log/slog` |
| RFC-008 | Remove LauncherPath from ContainerJobSpec | Done |
| RFC-009 | Issue Discovery: --sources Flag | Done — `--sources` flag fully implemented |
| RFC-010 | Rust Host Module Testing | Done |
| RFC-011 | Codebase Simplification Audit | Catalog only |
| RFC-012 | Orchestrate Command Decomposition | Done — `internal/plan/` package |
| RFC-013 | Dockerfile Cache Layer Optimization | Done |
| RFC-014 | Rust Config and Paths Cleanup | Done |
| RFC-015 | validate_all.sh Modernization | Done |
| RFC-016 | K3s YAML Path Externalization | Done |
| RFC-017 | image.rs Production Visibility Cleanup | Done |
| RFC-018 | Temporal Validation Multi-Error | Done — `validatePlan` uses `errors.Join` |
| RFC-019 | Rust Dead Code Cleanup | Done |
| RFC-020 | Retire launch_container.sh | Done — thin shim, then fully removed in RFC-062 |
| RFC-021 | Temporal Activity Heartbeats | Done — heartbeat goroutine in `runCommand` + `DownloadFile` |
| RFC-022 | Workflow Versioning (GetVersion) | Done |
| RFC-023 | Query and Signal Handlers for Pipeline | Done |
| RFC-024 | Stop Hardcoding HF Cache Dir | Done — honors `CacheDir`, `HF_HOME`, `/opt/hf_cache` |
| RFC-025 | Python Version Default Mismatch | Done — default changed 3.12→3.13 |
| RFC-026 | Env Var Documentation Gaps | Done — `ZEPHYR_*` vars documented in CLAUDE.md |
| RFC-027 | Extract should_build_decision from cfg(test) | Merged into RFC-017 |
| RFC-028 | ContainerJob Should Use zephyr Binary | Done |
| RFC-029 | SAIL discover_issues Should Cover Rust Tests | Done — `rust_coverage` source added |
| RFC-030 | Git Ops Staged Files Safety | Done — sensitive-file filter in git_ops.sh |
| RFC-031 | Add Explicit Dev-Only Unrestricted sudo Opt-In | Done — `ZEPHYR_DEV_SUDO=1` |
| RFC-032 | Reduce --ipc=host and --net=host Exposure | Done — bridge + shareable defaults |
| RFC-033 | Add Resource Limits to docker run | Done — `--memory`, `--cpus`, `--pids-limit` |
| RFC-034 | Temporal Search Attributes | N/A |
| RFC-035 | Add Remaining Test Coverage for orchestrate merge* | Done |
| RFC-036 | Worker Graceful Shutdown | Done — `WorkerStopTimeout: 30s` |
| RFC-037 | Replace Hardcoded /tmp Paths in rfc_impl.go | Done — uses configurable `TempDir` |
| RFC-038 | Multi-Engine Heartbeat Sleep | Done — `activity.RecordHeartbeat` on inter-round sleep |
| RFC-039 | Remove Commented Dead Code from Dockerfile | Done |
| RFC-040 | build_shared_caches Tuple → Struct | Done — `SharedCaches` struct in `config.rs` |
| RFC-041 | Cache detect_user_spec to Avoid docker info | Done — `ZEPHYR_ROOTLESS` override |
| RFC-042 | Extract Duplicated envOr Helper to Internal Package | Done — SAIL |
| RFC-043 | Suppress SC2034 False Positive in sail_cron.sh | Done — SAIL |
| RFC-044 | Handle Activity Errors in RFCTaskWorkflow Review and Diff Gates | Done — SAIL |
| RFC-045 | Parse TEMPORAL_LOG_MAX_BYTES Once at Worker Startup | Done — SAIL |
| RFC-046 | Extract Duplicated mergeStringMaps Helper to Internal Package | Done — SAIL |
| RFC-047 | Replace fmt.Printf with slog in multi_engine.go | Done — SAIL |
| RFC-048 | Replace log.Fatal / log.Printf with slog in cmd/orchestrate and cmd/rfc | Done — SAIL |
| RFC-049 | Add Rust Validation Section to validate_all.sh | Done — SAIL |
| RFC-050 | Remove Global SC2034 Suppression from validate_all.sh | Done — SAIL |
| RFC-051 | Deduplicate Default Exec Engine List in rfc_impl.go | Done — SAIL |
| RFC-052 | Add Unit Tests for sail_status.py | Done — SAIL |
| RFC-053 | Align discover_issues.py Shellcheck Invocation with validate_all.sh | Done — SAIL |
| RFC-054 | Add discover_open_rfcs Source to SAIL Issue Discovery | Done — SAIL (commit d845dd8) |
| RFC-055 | Auto-Close RFC Documents When SAIL Lands a Fix | Done — SAIL (commit 0bb556d) |
| RFC-056 | Temporal Worker Startup Config Validation | Done — SAIL (commit 2dd7f37) |
| RFC-057 | Add `--dry-run` Flag to `zephyr shell` | Done — SAIL (commit f912081) |
| RFC-058 | Remove Stale SC2034 Workaround from discover_issues.py | Done — SAIL (commit 923b1a1) |
| RFC-059 | Remove Deprecated NVIDIA Diagnostic Shims | Done — SAIL (commit 34353b6) |
| RFC-060 | Remove Deprecated Autobuild/Autoretry Shell Scripts | Done — SAIL (commit 3285bbc) |
| RFC-061 | Remove Unused k8s_job Step Type | Done — SAIL (commit 4e5de83) |
| RFC-062 | Remove launch_container.sh Shim and Legacy Fallback | Done — SAIL (commit 386e93c) |
| RFC-063 | Stale Lease Auto-Recovery in Zephyr Launcher | Done — commit ea8a4b3 |
| RFC-064 | Add `version` Field to Temporal YAML Plan Schema | Done — SAIL (commit fdc51af) |
| RFC-065 | Remove steps.json Legacy Pipeline Format Artifact | Done — SAIL (commit a4abea1) |
| RFC-066 | Drop validate_all.sh launch_container.sh Dependency | Done — resolved by RFC-062 |
| RFC-067 | Update skills/zephyr Documentation to Reference zephyr Binary | Done — already clean |
| RFC-068 | Remove k3s/ Directory | Done — SAIL (commit ed74b08) |
| RFC-069 | Remove example_repo_scoped_zephyr_skill/ Directory | Done — SAIL (commit 4f5affc) |
| RFC-070 | Remove run-qwen-demo.sh Demo Script | Done — script deleted |
| RFC-071 | Deduplicate client.Dial in cmd/ Packages | Done — SAIL (commit 828110d) |
| RFC-072 | Add Unit Tests for metrics_updater.py | Done — SAIL (commit a7795e4) |
| RFC-073 | Add Unit Tests for parse_session_events.py | Done — SAIL (commit 816937c) |
| RFC-074 | Refactor staging.rs Private Functions to Use StageContext Struct | Done — SAIL (commit 931b722) |
| RFC-075 | Extract Log-Writer Infrastructure from steps.go to logging.go | Done — SAIL (commit 56e96e4) |
| RFC-076 | Add Unit Tests for update_major_challenge_state.py | Done — SAIL (commit fb561a6) |
| RFC-077 | Fix Rust Test Count Scan in rfc-review-prompt.md | Done — rfc-review-prompt.md:61 already uses `'^\s*#\[test\]'` |
| RFC-078 | Extract rfc_impl.go Helpers to rfc_impl_util.go | Done — 10 helpers extracted to rfc_impl_util.go; rfc_impl.go reduced to 666 lines |
| RFC-079 | Extract HttpServer Class from sail_supervisor.py | Done — HttpServer class extracted to sail_http_server.py; sail_supervisor.py reduced to 854 lines |
| RFC-080 | Split config.rs Enums to config_types.rs | Done — 5 types extracted to config_types.rs; pub use re-exports preserve callers |
| RFC-081 | Decompose docker_args.rs into docker_env.rs and docker_mounts.rs | Done — docker_env.rs and docker_mounts.rs created; docker_args.rs reduced to 188 production lines |
| RFC-082 | Add cargo_clippy Source to discover_issues.py | Done — discover_cargo_clippy() added; mirrors validate_all.sh toolchain resolution |
| RFC-083 | Remove Stale k3s Subcommand from bin/sygaldry | Done — k3s subcommand block and completions removed from bin/sygaldry |
| RFC-084 | Extract stepContext Helper from startActivity in pipeline.go | Done — stepContext struct extracted; 11 repetitions eliminated in startActivity |
