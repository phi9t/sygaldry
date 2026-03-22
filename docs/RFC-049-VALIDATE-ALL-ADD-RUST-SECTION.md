# RFC-049: Add Rust Validation Section to validate_all.sh

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Medium
**Effort:** S

---

## Problem

`validate_all.sh` covers Go (build, vet, test), Python (ruff, black, pytest), and Shell (shellcheck), but has **no Rust section**. The Rust crate at `crates/zephyr/` is a primary production artifact — it produces the `zephyr` binary used by the entire container infrastructure — yet `validate_all.sh` never runs `cargo build`, `cargo test`, or `cargo clippy`.

`grep -i 'rust\|cargo\|clippy' validate_all.sh` returns empty.

Consequences:
- CI (`validate_all.sh`) can pass while the Rust crate fails to compile.
- `cargo clippy` warnings (e.g., unused imports, redundant clones) accumulate undetected.
- A developer running `./validate_all.sh` gets a false green signal that the full codebase is healthy.

---

## Solution

Add a Rust section to `validate_all.sh` after the existing Go section. The section should:

1. Skip gracefully if `cargo` is not installed (matching the pattern used for Go and Python).
2. Run `cargo build --manifest-path crates/zephyr/Cargo.toml` (release build optional, debug is sufficient for CI).
3. Run `cargo test --manifest-path crates/zephyr/Cargo.toml`.
4. Run `cargo clippy --manifest-path crates/zephyr/Cargo.toml -- -D warnings` (treat clippy warnings as errors).

Minimal addition (following existing `section` + `run_check` pattern in `validate_all.sh`):

```bash
# ---- Rust checks ----
CARGO_MANIFEST="crates/zephyr/Cargo.toml"
if command -v cargo &>/dev/null && [[ -f "${CARGO_MANIFEST}" ]]; then
    section "Rust: cargo build"
    run_check "cargo build" cargo build --manifest-path "${CARGO_MANIFEST}"

    section "Rust: cargo test"
    run_check "cargo test" cargo test --manifest-path "${CARGO_MANIFEST}"

    section "Rust: cargo clippy"
    run_check "cargo clippy" cargo clippy --manifest-path "${CARGO_MANIFEST}" -- -D warnings
else
    log "SKIP: cargo not installed or ${CARGO_MANIFEST} not found"
fi
```

The `--quick` flag (which skips shellcheck) should **not** skip the Rust section — Rust compilation is fast enough for routine use.

---

## Acceptance Criteria

1. `grep -n 'cargo' validate_all.sh | wc -l` returns at least 3.
2. Running `./validate_all.sh --quick` from the repo root exits 0 when the Rust crate compiles and tests pass.
3. `grep -n 'SKIP.*cargo\|cargo not installed' validate_all.sh` returns a line (graceful skip path present).
