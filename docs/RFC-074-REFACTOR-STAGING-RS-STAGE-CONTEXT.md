# RFC-074: Refactor staging.rs Private Functions to Use StageContext Struct

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Medium
**Effort:** S

---

## Problem

Three private functions in `crates/zephyr/src/host/staging.rs` suppress Clippy's
`too_many_arguments` lint because they each take 8-9 parameters, 5 of which are
identical across all three:

```rust
#[allow(clippy::too_many_arguments)]  // line 346
fn run_step(program, args, step_name, exit_code,
            paths, config, specs_csv, forbidden_csv, stage_env) → Result<()>

#[allow(clippy::too_many_arguments)]  // line 368
fn run_spack_cmd(spack_args, stage_env, log_file, step_name, exit_code,
                 paths, config, specs_csv, forbidden_csv) → Result<()>

#[allow(clippy::too_many_arguments)]  // line 401
fn write_final_status(paths, config, specs_csv, forbidden_csv, stage_env,
                      status, failed_step, failure_message)
```

The repeated 5-tuple `(paths, config, specs_csv, forbidden_csv, stage_env)` represents
"the staging context for this run" and should be a struct.

---

## Solution

Introduce a private `StageContext<'a>` struct in `staging.rs`:

```rust
struct StageContext<'a> {
    paths: &'a StagePaths,
    config: &'a StageConfig,
    specs_csv: &'a str,
    forbidden_csv: &'a str,
    stage_env: &'a str,
}
```

Refactor the three functions to accept `&StageContext` instead of the 5 individual
params, dropping all three `#[allow(clippy::too_many_arguments)]` annotations. The
call sites in `run_stage` construct the struct once and pass a reference.

---

## Acceptance Criteria

1. `grep -n '#\[allow(clippy::too_many_arguments)\]' crates/zephyr/src/host/staging.rs` returns 0 matches.
2. `cargo clippy -p zephyr -- -D warnings` passes (no suppressed warnings).
3. `cargo test -p zephyr` passes.
