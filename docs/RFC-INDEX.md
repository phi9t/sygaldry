# RFC Index

**Last updated:** 2026-03-18
**Total RFCs:** 32 (42 created, 10 closed as complete or N/A)

---

## All RFCs

| # | Title | Status | Priority | Effort | Area |
|---|-------|--------|----------|--------|------|
| RFC-001 | Sygaldry Architectural Review | Draft | — | — | architecture |
| RFC-002 | Rust as Container Infrastructure Foundation | Draft v3 | High | L | rust-core |
| RFC-003 | Temporal Production Readiness | Draft v3 | High | L | temporal |
| RFC-004 | SAIL Infrastructure Simplification | Draft v3 | Low | M | agentic |
| RFC-006 | Rust Entrypoint Consolidation | Draft v1 | Medium | M | rust-core |
| RFC-007 | Structured Logging in Activity Code | Draft v2 | Medium | XS | temporal |
| RFC-008 | Pipeline Step Hardening | Draft v1 | Medium | M | temporal |
| RFC-009 | Issue Discovery: --sources Flag | Draft v2 | Medium | XS | agentic |
| RFC-010 | Rust Host Module Testing | Draft v1 | Medium | M | rust-core / testing |
| RFC-012 | Orchestrate Command Decomposition | Proposed | — | — | temporal |
| RFC-013 | Dockerfile Cache Layer Optimization | Proposed | — | — | docker |
| RFC-014 | Rust Config and Paths Cleanup | Proposed | — | — | rust-core |
| RFC-015 | validate_all.sh Modernization | Proposed | — | — | shell |
| RFC-016 | K3s YAML Path Externalization | Proposed (on hold) | Low | M | temporal |
| RFC-017 | image.rs Production Visibility Cleanup | Proposed | — | — | rust-core |
| RFC-019 | Rust Dead Code Cleanup | Proposed | Immediate | XS | rust-core |
| RFC-020 | Retire launch_container.sh | Proposed | High | M | shell / rust-core |
| RFC-022 | Workflow Versioning (GetVersion) | Proposed | Medium | S | temporal |
| RFC-023 | Query and Signal Handlers for Pipeline | Proposed | Medium | M | temporal |
| RFC-024 | Stop Hardcoding HF Cache Dir | Proposed | Immediate | XS | temporal |
| RFC-027 | Extract should_build_decision from cfg(test) | Proposed | Medium | S | rust-core |
| RFC-028 | ContainerJob Should Use zephyr Binary | Proposed | High | S | temporal / rust-core |
| RFC-029 | SAIL discover_issues Should Cover Rust Tests | Proposed | Medium | S | agentic |
| RFC-031 | Scope Container User sudo Privileges | Proposed | Medium | S | docker |
| RFC-032 | Reduce --ipc=host and --net=host Exposure | Proposed | Medium | M | docker |
| RFC-033 | Add Resource Limits to docker run | Proposed | Low | S | docker |
| RFC-035 | Test Coverage for orchestrate merge* Functions | Proposed | Medium | M | testing |
| RFC-037 | Replace Hardcoded /tmp Paths in rfc_impl.go | Proposed | Immediate | XS | temporal |
| RFC-039 | Remove Commented Dead Code from Dockerfile | Proposed | Immediate | XS | docker |
| RFC-040 | build_shared_caches Tuple → Struct | Proposed | Low | XS | rust-core |
| RFC-041 | Cache detect_user_spec to Avoid docker info | Proposed | Low | S | rust-core |

---

## Suggested Implementation Order

### Immediate (XS, zero-risk)

1. **RFC-024** — Stop hardcoding HF cache dir (`/opt/hf_cache` in 2 places in `steps.go`)
2. **RFC-019** — Remove Rust `#[allow(dead_code)]` annotations (7 files in `crates/zephyr/`)
3. **RFC-037** — Replace hardcoded `/tmp` paths in `rfc_impl.go` (3 locations)
4. **RFC-039** — Remove Dockerfile commented dead block (4 lines)
5. **RFC-007** — Replace `log.*` with `slog` contextual logger in `steps.go` (~20 call sites)
6. **RFC-009** — Add `--sources` flag to `discover_issues.py`

### High priority (correctness / migration)

7. **RFC-028** — ContainerJob use zephyr binary (unlocks RFC-020)
8. **RFC-020** — Retire `launch_container.sh` (depends on RFC-028)
9. **RFC-029** — SAIL Rust test coverage

### Medium priority (production readiness)

10. **RFC-022** — Workflow versioning (`workflow.GetVersion`)
11. **RFC-023** — Query/signal handlers for running pipelines
12. **RFC-027** — `should_build_decision` out of `cfg(test)`
13. **RFC-040** — `build_shared_caches` tuple → struct
14. **RFC-035** — Test coverage for orchestrate `merge*` functions
15. **RFC-008** — Pipeline step hardening
16. **RFC-031** — Scope container sudo privileges
17. **RFC-032** — Reduce `--ipc=host` / `--net=host` exposure

### Lower priority

18. **RFC-006** — Rust entrypoint consolidation (M effort)
19. **RFC-010** — Rust host module testing
20. **RFC-012** — Orchestrate command decomposition
21. **RFC-013** — Dockerfile cache layer optimization
22. **RFC-014** — Rust config and paths cleanup
23. **RFC-015** — validate_all.sh modernization
24. **RFC-017** — image.rs production visibility cleanup
25. **RFC-033** — Add resource limits to docker run
26. **RFC-041** — Cache `detect_user_spec` to avoid `docker info`
27. **RFC-016** — K3s YAML path externalization (on hold: K3s strategic direction undecided)

---

## Closed RFCs

| # | Title | Resolution |
|---|-------|------------|
| RFC-005 | Dead Code Purge | Done — `orchestration.go`, `cmd/run`, `workflows.Orchestrate` removed |
| RFC-011 | Codebase Simplification Audit | Catalog only — individual items tracked as separate RFCs |
| RFC-018 | Temporal Validation Multi-Error | Done — `validatePlan` collects all errors via `errors.Join` |
| RFC-021 | Temporal Activity Heartbeats | Done — heartbeat goroutine in `runCommand` + `DownloadFile`; `HeartbeatTimeout: 30s` in pipeline |
| RFC-025 | Python Version Default Mismatch | Done — `launch_container.sh` default changed 3.12→3.13 with sync comment |
| RFC-026 | Env Var Documentation Gaps | Done — `ZEPHYR_*` and deprecated `SYGALDRY_*` vars documented in CLAUDE.md |
| RFC-030 | Git Ops Staged Files Safety | Done — sensitive-file filter in `commit` and `worktree-commit` in `git_ops.sh` |
| RFC-034 | Temporal Search Attributes | N/A — no Temporal search attributes exist in the codebase |
| RFC-036 | Worker Graceful Shutdown | Done — `WorkerStopTimeout: 30s`, `DeadlockDetectionTimeout: 5s`, `slog` in worker |
| RFC-038 | Multi-Engine Heartbeat Sleep | Done — `activity.RecordHeartbeat` on inter-round sleep in `multi_engine.go` (part of RFC-021) |
