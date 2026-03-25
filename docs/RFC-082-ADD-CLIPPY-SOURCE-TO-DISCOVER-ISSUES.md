# RFC-082: Add cargo_clippy Source to discover_issues.py

**Status:** Open
**Date:** 2026-03-25
**Priority:** Medium
**Effort:** S

---

## Problem

`validate_all.sh` runs `cargo clippy --manifest-path crates/zephyr/Cargo.toml -- -D warnings`
(line 235), but `tools/agentic/discover_issues.py` has no corresponding `cargo_clippy` source.

This means the SAIL improvement loop never surfaces `cargo clippy -D warnings` failures as
actionable issues. If a clippy regression is introduced, `validate_all.sh` will catch it but
SAIL will not — the two CI surfaces are asymmetric.

Confirmed: `grep -n 'clippy' tools/agentic/discover_issues.py` returns empty.
The `sources` list (currently starting at line 735 of `discover_issues.py`) contains
`go_tests_and_coverage`, `rust_coverage`, `go_vet`, `shellcheck`, `todo`, `ruff`,
`foundation_drift`, and `open_rfcs`, but not `cargo_clippy`.

---

## Solution

Add a `discover_cargo_clippy` function to `tools/agentic/discover_issues.py` and register
it in the `sources` list inside `main()`.

The function must use the same toolchain-aware invocation as `validate_all.sh` (lines 214–226)
to avoid ABI mismatches when `cargo` comes from Spack but `clippy` comes from rustup.
Specifically, if `crates/zephyr/rust-toolchain.toml` exists and `rustup` is on PATH, resolve
the toolchain binary dir and prepend it to PATH before invoking `cargo clippy`.

The function should:
1. Return `[]` immediately when `cargo` is not on `PATH`.
2. Resolve the rustup toolchain bin dir from `crates/zephyr/rust-toolchain.toml` if available
   (same logic as `validate_all.sh` lines 218–226), and set `env["PATH"]` accordingly.
3. Run `cargo clippy --manifest-path <repo>/crates/zephyr/Cargo.toml --message-format json -- -D warnings`
   with `stderr=subprocess.STDOUT` and parse each line as a JSON compiler message.
4. Emit one `Issue` per `compiler-message` entry where `message["level"] == "error"`.
5. Use `type = "cargo_clippy"`, `priority = 2`.
6. Cite `file:line` from `message["spans"][0]` when available; fall back to the crate root.

Register in the `sources` list inside `main()`:
```python
("cargo_clippy", discover_cargo_clippy),
```

Also update the `type` schema comment at line 21:
```python
# "type": "todo|shellcheck|go_test|ruff|foundation_drift|go_vet|go_coverage|rust_coverage|cargo_clippy|rfc",
```

---

## Acceptance Criteria

1. `grep -n 'cargo_clippy' tools/agentic/discover_issues.py` returns ≥ 2 matches
2. `python3 tools/agentic/discover_issues.py --sources cargo_clippy 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)), 'issues')"` runs without error and prints `0 issues` on a clean tree
3. `.venv-lint/bin/ruff check tools/agentic/discover_issues.py` passes
4. The function does not invoke `cargo` when `shutil.which("cargo")` returns `None` (verified by a unit test or by running with `PATH='' python3 tools/agentic/discover_issues.py --sources cargo_clippy`)
