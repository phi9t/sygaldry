# RFC-029: SAIL discover_issues Should Cover Rust Crate Tests

**Status:** Proposed
**Priority:** Medium
**Effort:** S
**Area:** agentic

## Problem

`tools/agentic/discover_issues.py` scans for Go coverage gaps in the `temporal/` directory only. The `crates/zephyr/` Rust crate has its own test suite (`cargo test`) and coverage tooling (`cargo llvm-cov` or `cargo tarpaulin`), but SAIL never discovers missing coverage there. As a result, SAIL agents can improve Go test coverage while leaving Rust coverage stagnant.

Additionally, `discover_uncovered_functions()` hardcodes `/tmp/sail-coverage.out` (line ~464) as the Go coverage file path, making it incompatible with parallel SAIL runs or non-default configurations.

## Evidence

`tools/agentic/discover_issues.py` line ~464:
```python
coverage_file = "/tmp/sail-coverage.out"
```

The function only calls:
```python
subprocess.run(["go", "test", "-coverprofile", coverage_file, "./..."],
               cwd=str(TEMPORAL_DIR), ...)
```

No call to `cargo test` or `cargo llvm-cov` anywhere in the file.

`TEMPORAL_DIR` is hardcoded to `REPO_ROOT / "temporal"` — there is no `RUST_DIR` equivalent.

## Proposed Changes

1. Add a `RUST_CRATE_DIR = REPO_ROOT / "crates" / "zephyr"` constant.

2. Add a `discover_uncovered_rust_functions()` issue source that:
   - Runs `cargo llvm-cov --json --output-path /tmp/sail-rust-coverage.json` in `RUST_CRATE_DIR`
   - Parses the JSON output for functions with `0` execution count
   - Emits issues with `source=rust_coverage`, `priority=2`, pointing to uncovered function+file

3. Make the Go coverage file path configurable:
   ```python
   coverage_file = os.environ.get("SAIL_GO_COVERAGE_FILE", "/tmp/sail-coverage.out")
   ```

4. Register the new issue source in the `ISSUE_SOURCES` list.

5. Check for `cargo llvm-cov` availability before running; skip with a warning if absent (graceful degradation).

## Files Changed

- `tools/agentic/discover_issues.py` — new `discover_uncovered_rust_functions()`, configurable coverage file path

## Verification

```bash
cd /mnt/data_infra/workspace/sygaldry
python tools/agentic/discover_issues.py 2>&1 | grep rust_coverage | head -5
# Should emit rust_coverage issues if any uncovered functions exist.
# Confirm no crash if cargo-llvm-cov is absent.
```
