# RFC-011: Codebase Simplification Audit

**Status:** Draft — v1
**Date:** 2026-03-16
**Priority:** Medium — consolidates findings from the full 10-pass review

---

## 1. Purpose

This RFC catalogs all simplification opportunities that do not fit cleanly into RFC-002 through RFC-010. It serves as a reference for future SAIL cycles and manual cleanup.

---

## 2. Findings by Subsystem

### 2.1 `crates/zephyr/src/container/entrypoint.rs` (850 LOC)

The largest Rust source file. It handles 9 entrypoints with significant logic in each. Three functions are individually long:

- `entrypoint_default` (~100 LOC): welcome banner, Spack init, GPU check, shell exec
- `entrypoint_hf_download` (~120 LOC): argument parsing, download loop, progress reporting
- `exec_shell_with_rc` (~80 LOC): .bashrc detection, shell selection

**Opportunity:** Extract `print_welcome()`, `exec_shell_with_rc()`, and `hf_download_core()` to named sub-modules or a `container/shell.rs` file. No behavior change — purely structural.

**Priority:** Low (the file works correctly; this is readability only).

---

### 2.2 `crates/zephyr/src/host/staging.rs` (724 LOC)

Second-largest Rust file. The `run()` function is ~200 LOC with a deeply nested state machine for Spack concretization. Specific complexity hotspot:

- Lines ~150-280: forbidden package check embedded inline
- Lines ~350-450: GPU verification runs unconditionally; should be gated on `config.gpu_verify`

**Opportunity:** Extract `check_forbidden_packages()` and `run_gpu_verify()` as named functions. Add an explicit early-return when `!config.gpu_verify`.

**Priority:** Medium (affects RFC-006 indirectly; staging is called during container setup).

---

### 2.3 `temporal/cmd/orchestrate/main.go` (997 LOC)

The largest Go file. Three distinct concerns live in one file:
- YAML plan parsing (lines ~1-200)
- Plan validation (lines ~200-500)
- Temporal client + workflow execution (lines ~500-700)
- Result reporting (lines ~700-997)

**Opportunity:** Extract to sub-packages:
- `cmd/orchestrate/plan/` — YAML parsing + validation
- `cmd/orchestrate/execute/` — Temporal submission
- `cmd/orchestrate/report/` — result formatting

This would make each concern testable in isolation. Current test file (`main_test.go`, 612 LOC) tests validation heavily but execution not at all.

**Priority:** Low (it works; this is architectural).

---

### 2.4 `bin/sygaldry` bash completion (lines 227-255)

The bash completion function `_sygaldry_completions` defines completions inline. After RFC-002 Phase 4 slims `bin/sygaldry` to ~50 lines, completions should be moved to a separate file:

```bash
# bin/completions/sygaldry.bash
_sygaldry_completions() { ... }
complete -F _sygaldry_completions sygaldry
```

And `sygaldry completions bash` would `cat bin/completions/sygaldry.bash`. This keeps the main dispatcher clean.

**Priority:** Low.

---

### 2.5 `tools/agentic/run_improvement_loop.sh` (887 LOC)

Beyond the RFC-004 changes (dedup `_cfg_section`, extract Python), there are additional simplification opportunities:

**Lines 200-350: Plan file selection logic** — selects `major_improvement_loop.yaml` vs `improvement_loop.yaml` based on 6 conditions. This could move to `generate_plan.py` as a function `select_plan_file()` returning the path. The shell script would become:

```bash
PLAN_FILE="$(python3 "${SCRIPT_DIR}/generate_plan.py" --select-plan-file ...)"
```

**Lines 400-550: Run directory setup** — creates ~15 files/directories with specific naming. Could be a Python function `setup_run_dir(run_id, artifacts_dir)` → structured dataclass with paths.

**Priority:** Low — do after RFC-004 is merged.

---

### 2.6 Environment variable namespace drift

The codebase uses two conflicting env var prefixes:
- `SYGALDRY_*` — original namespace
- `ZEPHYR_*` — newer namespace (preferred per CLAUDE.md)

Some variables exist in both:
- `SYGALDRY_SPACK_STORE` → `ZEPHYR_SHARED_SPACK_STORE`
- `SYGALDRY_UV_CACHE` → `ZEPHYR_SHARED_UV_CACHE`
- `SYGALDRY_HF_CACHE` → `ZEPHYR_SHARED_HF_CACHE`

`crates/zephyr/src/config.rs` already handles both with fallback. But `container/launch_container.sh` has a 60-line block of fallback handling. After `launch_container.sh` is deleted (RFC-002), this duplication disappears naturally.

**Action required:** None (cleans up with RFC-002). Document here for awareness.

---

### 2.7 `tools/agentic/config.yaml` — `min_priority: 2` excludes normal issues

`tools/agentic/config.yaml` sets `min_priority: 2`. This means SAIL only processes `priority <= 2` issues (critical and high). The 10 `go_coverage` issues (likely priority 3) and 10 `shellcheck SC2034` issues (priority 3) are excluded from every SAIL cycle.

**Opportunity:** Reduce `min_priority` to 3 once the high-priority issues (priority 1+2) are cleared. Or add a `--min-priority` flag to `run_improvement_loop.sh` that lets SAIL dynamically lower the threshold when the backlog is empty.

**Priority:** Medium (affects SAIL self-improvement throughput).

---

### 2.8 `temporal/internal/workflows/pipeline.go` — `sortedStepIDs` allocation

`pipeline.go` contains `sortedStepIDs(pending map[string]PipelineStep) []string` which allocates a new slice and sorts it on every scheduler tick. For pipelines with 100+ steps, this is O(N log N) per tick. Not a current bottleneck but worth noting.

**Opportunity:** Pre-compute topological order once before the scheduler loop. The current loop works correctly; this is an optimization for large pipelines.

**Priority:** Low.

---

### 2.9 `k3s/` directory — incomplete and undocumented

`k3s/` (640 LOC across 13 files) contains job runner and bootstrap scripts but:
- No `README.md`
- `k3s/bin/kentai` and `k3s/bin/kjob` are used from `bin/sygaldry` but have no documentation
- The Kubernetes job step type in Temporal (`K8sJobSpec`) is supposed to delegate to k3s but the implementation is missing (see RFC-008)

**Opportunity:** Either document k3s/ properly or mark it as experimental in CLAUDE.md. RFC-008 Change 1 at minimum makes the missing implementation explicit.

---

### 2.10 `multimodal_research/` — detached code

The `multimodal_research/` directory appears to be experimental research code. It's not referenced from any build script, not tested in `validate_all.sh`, and not mentioned in CLAUDE.md.

**Opportunity:** Either integrate it into the main build or move it to a separate branch/repo. Leaving unvalidated code in main creates confusion about what is maintained.

**Priority:** Low — depends on whether this work is active.

---

## 3. Prioritized Action List

| # | Finding | Effort | Priority | RFC |
|---|---------|--------|----------|-----|
| 1 | Dead code purge (`cmd/run`, `orchestration.go`) | 1h | Immediate | RFC-005 |
| 2 | SAIL `min_priority` lowered to 3 | 5m | High | (inline) |
| 3 | `staging.rs` forbidden package extraction | 2h | Medium | RFC-010 prereq |
| 4 | `orchestrate/main.go` sub-package extraction | 1d | Low | Future |
| 5 | `entrypoint.rs` sub-module extraction | 4h | Low | Future |
| 6 | `multimodal_research/` disposition | 30m | Low | Owner decision |
| 7 | `k3s/` documentation | 2h | Low | RFC-008 |
| 8 | Bash completion extraction | 30m | Low | RFC-002 Phase 4 |

---

## 4. Metrics

Adopting RFC-002 through RFC-010 reduces the codebase by approximately:

| Category | Lines Before | Lines After | Delta |
|----------|-------------|-------------|-------|
| Bash (container infra) | ~2,200 | ~200 | −2,000 |
| Go (dead code) | 5,744 | 5,519 | −225 |
| Shell (SAIL) | 1,361 | ~950 | −411 |
| Python (SAIL) | ~700 (embedded) | ~500 (standalone) | −200 |
| **Total reduction** | **31,270** | **~28,434** | **−2,836 (~9%)** |

The reduction is real simplification: dead parallel implementations removed, not logic deleted.
