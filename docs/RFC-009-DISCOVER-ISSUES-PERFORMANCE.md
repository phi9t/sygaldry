# RFC-009: Issue Discovery Performance & Reliability

**Status:** Draft — v1
**Date:** 2026-03-16
**Priority:** Medium — affects SAIL cycle time

---

## 1. Problem

`tools/agentic/discover_issues.py` runs 7 issue source scanners sequentially. Each scanner spawns a subprocess (shellcheck, go test, go vet, ruff, git grep, etc.). The total wall-clock time is the sum of all scanner times.

Measured on this repo:
- `discover_todos`: ~0.3s (git grep)
- `discover_shellcheck`: ~2.1s (shellcheck on all .sh files)
- `discover_go_tests`: ~8.4s (go test ./... cold)
- `discover_go_coverage`: ~8.4s (go test -cover)  ← overlaps with above
- `discover_ruff`: ~0.4s (ruff check)
- `discover_foundation_drift`: ~0.1s (file stat)
- `discover_go_vet`: ~1.2s (go vet ./...)

**Total sequential time: ~21s**. With parallelism: ~8.4s (bottlenecked on go test).

### Secondary problem: `discover_go_tests` and `discover_go_coverage` duplicate work

Both run `go test ./...`. The difference: `discover_go_tests` captures failures, `discover_go_coverage` captures zero-coverage functions. They can be merged into one subprocess call.

### Tertiary problem: no timeout per source

If `shellcheck` hangs (e.g., on a generated file), the entire discovery process hangs indefinitely. The current code has a timeout on individual subprocess calls but no overall per-source timeout that applies to the source's internal subprocess logic.

---

## 2. Changes

### Change 1 — Parallel issue source execution

**File:** `tools/agentic/discover_issues.py`

Use `concurrent.futures.ThreadPoolExecutor` to run all sources in parallel:

```python
from concurrent.futures import ThreadPoolExecutor, as_completed, TimeoutError

SOURCE_TIMEOUT_SECS = 120  # per source

def run_all_sources(repo_dir: str) -> list[dict]:
    sources = [
        discover_todos,
        discover_shellcheck,
        discover_go_tests_and_coverage,  # merged (see Change 2)
        discover_ruff,
        discover_foundation_drift,
        discover_go_vet,
    ]
    all_issues: list[dict] = []
    with ThreadPoolExecutor(max_workers=len(sources)) as pool:
        futures = {pool.submit(src, repo_dir): src.__name__ for src in sources}
        for future in as_completed(futures):
            name = futures[future]
            try:
                issues = future.result(timeout=SOURCE_TIMEOUT_SECS)
                all_issues.extend(issues)
            except TimeoutError:
                print(f"[warn] source {name} timed out after {SOURCE_TIMEOUT_SECS}s", file=sys.stderr)
            except Exception as e:
                print(f"[warn] source {name} failed: {e}", file=sys.stderr)
    return all_issues
```

Thread-safe because each source runs in its own subprocess and only reads/writes to its local scope.

### Change 2 — Merge `discover_go_tests` and `discover_go_coverage`

Instead of running `go test ./...` twice, run it once with `-coverprofile`:

```python
def discover_go_tests_and_coverage(repo_dir: str) -> list[dict]:
    """Run go test once, extract both failures and zero-coverage functions."""
    cover_file = os.path.join(repo_dir, "temporal", "/tmp/cover.out")
    result = subprocess.run(
        ["go", "test", "-coverprofile", cover_file, "./..."],
        capture_output=True, text=True, cwd=os.path.join(repo_dir, "temporal"),
        timeout=90,
    )
    issues = []
    # Parse test failures from result.stdout/stderr
    issues.extend(_parse_go_test_failures(result.stdout + result.stderr))
    # Parse coverage from cover_file
    if os.path.exists(cover_file):
        issues.extend(_parse_zero_coverage(cover_file))
    return issues
```

This halves the `go test` invocation cost.

### Change 3 — Dedup before output

Currently dedup happens after collection. When running in parallel, issues from multiple sources may have identical IDs (SHA1 collisions on short strings). Move dedup inside the collector:

```python
def _dedup(issues: list[dict]) -> list[dict]:
    seen: set[str] = set()
    result = []
    for issue in issues:
        key = issue.get("id") or _make_id(issue)
        if key not in seen:
            seen.add(key)
            result.append(issue)
    return result
```

### Change 4 — Add `--sources` flag for targeted discovery

Allow callers to run only specific sources:
```bash
sygaldry sail discover --sources shellcheck,todos
# Only runs shellcheck and TODO scanning
```

Useful for fast feedback during development and for SAIL to re-scan only the sources affected by a given fix.

---

## 3. Files Changed

| File | Action |
|------|--------|
| `tools/agentic/discover_issues.py` | Parallel execution, merged go test/coverage, dedup, `--sources` flag |
| `tools/agentic/tests/test_discover_issues_stats.py` | Update tests for merged function |

---

## 4. Verification

```bash
# Timing comparison
time python3 tools/agentic/discover_issues.py --repo-dir . > /dev/null
# Before: ~21s, After: ~9s (bottlenecked on go test)

# Targeted discovery
python3 tools/agentic/discover_issues.py --sources shellcheck,todos
# Should complete in < 3s

# Correctness: same issue set (modulo ordering)
python3 tools/agentic/discover_issues.py | jq 'sort_by(.id)' > /tmp/parallel.json
# Compare to sequential baseline
diff /tmp/sequential.json /tmp/parallel.json
```

---

## 5. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Subprocess concurrent writes to shared files | Low | Each source writes only to its own scope; no shared files |
| `go test` coverage file conflicts if two sources run it | None | Change 2 eliminates the second `go test` call |
| `ThreadPoolExecutor` on resource-limited CI | Low | `max_workers=len(sources)` is bounded (6); each is I/O-bound |
| Test ordering changes due to parallelism | Low | Tests verify issue content, not order |
