# RFC Index

**Last updated:** 2026-03-23
**Total RFCs:** 7 open (64 created, 57 closed as complete or N/A)

---

## Open RFCs

| # | Title | Status | Priority | Effort | Blocked By |
|---|-------|--------|----------|--------|------------|
| RFC-057 | Add `--dry-run` Flag to `zephyr shell` | Draft — v1 | Medium | M | |
| RFC-059 | Remove Deprecated NVIDIA Diagnostic Shims | Draft — v1 | Low | XS | |
| RFC-060 | Remove Deprecated Autobuild/Autoretry Shell Scripts | Draft — v1 | Low | S | |
| RFC-061 | Remove Unused k8s_job Step Type | Draft — v1 | Low | S | |
| RFC-062 | Remove launch_container.sh Shim and Legacy Fallback | Draft — v1 | Low | M | RFC-059 |
| RFC-063 | Stale Lease Auto-Recovery in Zephyr Launcher | Draft — v1 | Medium | S | |
| RFC-064 | Add `version` Field to Temporal YAML Plan Schema | Draft — v1 | Low | S | |

---

## Suggested Implementation Order

1. **RFC-063** — Medium priority: stale lease auto-recovery; prevents user lockout after container crashes.
3. **RFC-057** — Medium priority, larger effort: `zephyr shell --dry-run` for debugging.
4. **RFC-059** — Low priority, XS: remove `inspect_nvidia_setup.sh` and `fix_nvidia_setup.sh` shims.
5. **RFC-060** — Low priority: delete `tools/zephyr_autobuild.sh`, `zephyr_autoretry.sh`, `zephyr_autoretry_tmux.sh`.
6. **RFC-061** — Low priority: remove unused `k8s_job` step type from Temporal activities.
7. **RFC-062** — Low priority, depends on RFC-059: delete `launch_container.sh` shim and Go fallback.
8. **RFC-064** — Low priority: add `version: 1` field to plan YAML schema.

---

## All RFCs

All 57 prior RFCs are closed. See Closed RFCs below.

---

## Closed RFCs

| # | Title | Resolution |
|---|-------|------------|
| RFC-001 | Sygaldry Architectural Review | Closed — documentary review only |
| RFC-005 | Dead Code Purge | Done — `orchestration.go`, `cmd/run`, `workflows.Orchestrate` removed |
| RFC-009 | Issue Discovery: --sources Flag | Done — `--sources` flag fully implemented |
| RFC-011 | Codebase Simplification Audit | Catalog only |
| RFC-018 | Temporal Validation Multi-Error | Done — `validatePlan` uses `errors.Join` |
| RFC-021 | Temporal Activity Heartbeats | Done — heartbeat goroutine in `runCommand` + `DownloadFile` |
| RFC-025 | Python Version Default Mismatch | Done — default changed 3.12→3.13 |
| RFC-026 | Env Var Documentation Gaps | Done — `ZEPHYR_*` vars documented in CLAUDE.md |
| RFC-027 | Extract should_build_decision from cfg(test) | Merged into RFC-017 |
| RFC-030 | Git Ops Staged Files Safety | Done — sensitive-file filter in git_ops.sh |
| RFC-034 | Temporal Search Attributes | N/A |
| RFC-036 | Worker Graceful Shutdown | Done — `WorkerStopTimeout: 30s` |
| RFC-038 | Multi-Engine Heartbeat Sleep | Done — `activity.RecordHeartbeat` on inter-round sleep |
| RFC-007 | Structured Logging in Activity Code | Done — `log` → `log/slog` |
| RFC-008 | Remove LauncherPath from ContainerJobSpec | Done |
| RFC-024 | Stop Hardcoding HF Cache Dir | Done — honors `CacheDir`, `HF_HOME`, `/opt/hf_cache` |
| RFC-037 | Replace Hardcoded /tmp Paths in rfc_impl.go | Done — uses configurable `TempDir` |
| RFC-029 | SAIL discover_issues Should Cover Rust Tests | Done — `rust_coverage` source added |
| RFC-039 | Remove Commented Dead Code from Dockerfile | Done |
| RFC-040 | build_shared_caches Tuple → Struct | Done — `SharedCaches` struct in `config.rs` |
| RFC-028 | ContainerJob Should Use zephyr Binary | Done |
| RFC-020 | Retire launch_container.sh | Done — thin shim only |
| RFC-017 | image.rs Production Visibility Cleanup | Done |
| RFC-041 | Cache detect_user_spec to Avoid docker info | Done — `ZEPHYR_ROOTLESS` override |
| RFC-035 | Add Remaining Test Coverage for orchestrate merge* | Done |
| RFC-022 | Workflow Versioning (GetVersion) | Done |
| RFC-015 | validate_all.sh Modernization | Done |
| RFC-032 | Reduce --ipc=host and --net=host Exposure | Done — bridge + shareable defaults |
| RFC-033 | Add Resource Limits to docker run | Done — `--memory`, `--cpus`, `--pids-limit` |
| RFC-010 | Rust Host Module Testing | Done |
| RFC-014 | Rust Config and Paths Cleanup | Done |
| RFC-023 | Query and Signal Handlers for Pipeline | Done |
| RFC-019 | Rust Dead Code Cleanup | Done |
| RFC-003 | Temporal Production Readiness | Done — YAML config + `/healthz` |
| RFC-031 | Add Explicit Dev-Only Unrestricted sudo Opt-In | Done — `ZEPHYR_DEV_SUDO=1` |
| RFC-004 | SAIL Supervisor Decomposition | Done |
| RFC-006 | Rust Entrypoint Consolidation | Done |
| RFC-002 | Rust as Container Infrastructure Foundation | Done |
| RFC-012 | Orchestrate Command Decomposition | Done — `internal/plan/` package |
| RFC-013 | Dockerfile Cache Layer Optimization | Done |
| RFC-016 | K3s YAML Path Externalization | Done |
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
| RFC-058 | Remove Stale SC2034 Workaround from discover_issues.py | Done — SAIL (commit 923b1a1) |
