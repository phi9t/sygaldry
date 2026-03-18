# RFC Index — Sygaldry

Master index of all RFCs. Last updated: 2026-03-17.

Three overarching goals drive this RFC series:

1. **Simplify** — remove dead code, duplication, and accidental complexity
2. **Rust-authoritative** — `crates/zephyr/` is the single source of truth for container infrastructure; shell scripts delegate to the binary
3. **Temporal production-ready** — proper error handling, observability, resilience, and test coverage

---

## All RFCs

| # | Title | Status | Priority | Effort | Area |
|---|-------|--------|----------|--------|------|
| [RFC-001](RFC-001-SYGALDRY-ARCH-REVIEW.md) | Sygaldry Architectural Review and System Specification | Draft | — | — | architecture |
| [RFC-002](RFC-002-RUST-CONTAINER-FOUNDATION.md) | Rust as Container Infrastructure Foundation | Draft v3 | High | L | rust-core |
| [RFC-003](RFC-003-TEMPORAL-PROD-READINESS.md) | Temporal Production Readiness | Draft v3 | High | L | temporal |
| [RFC-004](RFC-004-SAIL-SIMPLIFICATION.md) | SAIL Infrastructure Simplification | Draft v3 | Low | M | agentic |
| [RFC-005](RFC-005-DEAD-CODE-PURGE.md) | Dead Code Purge | Draft v1 | Immediate | XS | rust-core / shell |
| [RFC-006](RFC-006-RUST-ENTRYPOINT-CONSOLIDATION.md) | Rust Entrypoint Consolidation | Draft v1 | High | M | rust-core |
| [RFC-007](RFC-007-TEMPORAL-OBSERVABILITY.md) | Temporal Activity Observability | Draft v1 | Medium | M | temporal |
| [RFC-008](RFC-008-PIPELINE-STEP-HARDENING.md) | Pipeline Step Hardening | Draft v1 | Medium | M | temporal |
| [RFC-009](RFC-009-DISCOVER-ISSUES-PERFORMANCE.md) | Issue Discovery Performance and Reliability | Draft v1 | Medium | S | agentic |
| [RFC-010](RFC-010-RUST-HOST-TESTING.md) | Rust Host Module Testing | Draft v1 | Medium | M | rust-core / testing |
| [RFC-011](RFC-011-CODEBASE-SIMPLIFICATION-AUDIT.md) | Codebase Simplification Audit | Draft v1 | Medium | S | all |
| [RFC-012](RFC-012-ORCHESTRATE-DECOMPOSITION.md) | Orchestrate Command Decomposition | Proposed | — | — | temporal |
| [RFC-013](RFC-013-DOCKERFILE-OPTIMIZATION.md) | Dockerfile Cache Invalidation and Layer Optimization | Proposed | — | — | docker |
| [RFC-014](RFC-014-RUST-CONFIG-CLEANUP.md) | Rust Config and Paths Cleanup | Proposed | — | — | rust-core |
| [RFC-015](RFC-015-VALIDATE-ALL-MODERNIZATION.md) | validate_all.sh Modernization | Proposed | — | — | shell |
| [RFC-016](RFC-016-K3S-YAML-EXTERNALIZATION.md) | K3s YAML Path Externalization | Proposed | — | — | temporal |
| [RFC-017](RFC-017-IMAGE-RS-CLEANUP.md) | image.rs Production Visibility and Safety Cleanup | Proposed | — | — | rust-core |
| [RFC-018](RFC-018-TEMPORAL-VALIDATION-MULTI-ERROR.md) | Temporal Plan Validation Multi-Error Reporting | Proposed | — | — | temporal |
| [RFC-019](RFC-019-RUST-DEAD-CODE-CLEANUP.md) | Rust Dead Code Cleanup | Proposed | Low | XS | rust-core |
| [RFC-020](RFC-020-RETIRE-LAUNCH-CONTAINER-SH.md) | Retire launch_container.sh — Delegate to Rust Binary | Proposed | High | M | shell / rust-core |
| [RFC-021](RFC-021-TEMPORAL-ACTIVITY-HEARTBEATS.md) | Add Heartbeats to Long-Running Temporal Activities | Proposed | High | S | temporal |
| [RFC-022](RFC-022-TEMPORAL-WORKFLOW-VERSIONING.md) | Add Workflow Versioning with workflow.GetVersion | Proposed | Medium | S | temporal |
| [RFC-023](RFC-023-TEMPORAL-QUERY-SIGNAL-HANDLERS.md) | Add Query and Signal Handlers to Pipeline Workflow | Proposed | Medium | M | temporal |
| [RFC-024](RFC-024-HF-CACHE-DIR-HARDCODED.md) | Stop Hardcoding HF Cache Dir in Activities | Proposed | Medium | XS | temporal |
| [RFC-025](RFC-025-PYTHON-VERSION-DEFAULT-MISMATCH.md) | Fix PYTHON_VERSION Default Mismatch Between Bash and Rust | Proposed | High | XS | shell / rust-core |
| [RFC-026](RFC-026-ENV-VAR-DOCUMENTATION-GAPS.md) | Fill Env Var Documentation Gaps in CLAUDE.md | Proposed | Low | XS | docs |
| [RFC-027](RFC-027-IMAGE-RS-SHOULD-BUILD-DECISION.md) | Extract should_build_decision from cfg(test) into Production Code | Proposed | Medium | S | rust-core |
| [RFC-028](RFC-028-CONTAINER-JOB-USE-ZEPHYR-BINARY.md) | ContainerJob Activity Should Use the zephyr Binary | Proposed | High | S | temporal / rust-core |
| [RFC-029](RFC-029-SAIL-RUST-COVERAGE.md) | SAIL discover_issues Should Cover Rust Crate Tests | Proposed | Medium | S | agentic |
| [RFC-030](RFC-030-GIT-OPS-STAGED-FILES-SAFETY.md) | git_ops.sh Should Not Stage Sensitive Files with git add -A | Proposed | High | S | agentic / shell |
| [RFC-031](RFC-031-CONTAINER-SUDO-NOPASSWD.md) | Scope Container User sudo Privileges | Proposed | Medium | S | docker |
| [RFC-032](RFC-032-DOCKER-IPC-NET-HOST.md) | Reduce --ipc=host and --net=host Exposure | Proposed | Medium | M | docker |
| [RFC-033](RFC-033-DOCKER-RESOURCE-LIMITS.md) | Add Resource Limits to docker run | Proposed | Low | S | docker |
| [RFC-034](RFC-034-TEMPORAL-SEARCH-ATTRIBUTES.md) | Replace Hardcoded Temporal Search Attribute Names | Proposed | Medium | S | temporal |
| [RFC-035](RFC-035-ORCHESTRATE-MERGE-TEST-COVERAGE.md) | Add Test Coverage for orchestrate merge* Functions | Proposed | Medium | M | testing |
| [RFC-036](RFC-036-WORKER-GRACEFUL-SHUTDOWN.md) | Add Graceful Shutdown to Temporal Worker | Proposed | Medium | S | temporal |
| [RFC-037](RFC-037-RFC-IMPL-TMP-PATHS.md) | Replace Hardcoded /tmp Paths in rfc_impl.go | Proposed | Low | XS | temporal |
| [RFC-038](RFC-038-MULTI-ENGINE-HEARTBEAT-SLEEP.md) | Make MultiEngineAgentTask Heartbeat-Aware | Proposed | Medium | S | temporal |
| [RFC-039](RFC-039-DOCKERFILE-DEAD-CODE.md) | Remove Commented-Out Dead Code from Dockerfile | Proposed | Low | XS | docker |
| [RFC-040](RFC-040-BUILD-SHARED-CACHES-TUPLE.md) | Replace build_shared_caches 8-Tuple Return with a Struct | Proposed | Low | XS | rust-core |
| [RFC-041](RFC-041-DETECT-USER-SPEC-DOCKER-INFO.md) | Cache detect_user_spec Result to Avoid docker info on Every Launch | Proposed | Low | S | rust-core |

---

## Effort key

| Symbol | Meaning |
|--------|---------|
| XS | < 1 hour, single-file change |
| S | 1–4 hours, 1–3 files |
| M | 4–16 hours, cross-cutting |
| L | > 16 hours, multi-sprint |

---

## Priority key

| Level | Meaning |
|-------|---------|
| High | Correctness or reliability bug; implement immediately |
| Medium | Real improvement, do in current or next sprint |
| Low | Polish; do when bandwidth allows |
| Immediate | Zero-risk cleanup, do as first PR |

---

## Suggested implementation order

### Immediate (zero-risk, high signal)

1. RFC-025 — PYTHON_VERSION mismatch fix (one-line change, prevents silent bugs)
2. RFC-019 — Remove Rust dead code (`#[allow(dead_code)]`)
3. RFC-039 — Remove Dockerfile dead commented block
4. RFC-040 — `build_shared_caches` struct refactor
5. RFC-026 — CLAUDE.md env var documentation

### High priority (correctness)

6. RFC-021 — Temporal heartbeats (prevents activity timeouts during agent tasks)
7. RFC-030 — git_ops.sh sensitive file staging (security)
8. RFC-028 — ContainerJob use zephyr binary (consistency)
9. RFC-020 — Retire launch_container.sh (requires RFC-028 first)
10. RFC-024 — HF cache dir hardcoded

### Medium priority (production readiness)

11. RFC-022 — Workflow versioning
12. RFC-036 — Worker graceful shutdown
13. RFC-027 — should_build_decision out of cfg(test)
14. RFC-034 — Search attribute names
15. RFC-035 — orchestrate merge* test coverage
16. RFC-038 — MultiEngineAgentTask heartbeat sleep
17. RFC-023 — Query/signal handlers
18. RFC-029 — SAIL Rust coverage
19. RFC-031 — Container sudo scoping
20. RFC-032 — --ipc=host --net=host reduction

### Low priority (polish)

21. RFC-037 — /tmp paths in rfc_impl.go
22. RFC-033 — Docker resource limits
23. RFC-041 — docker info caching
24. RFC-014 (existing) — Rust config cleanup
