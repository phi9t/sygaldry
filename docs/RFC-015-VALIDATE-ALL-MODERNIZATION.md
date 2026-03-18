# RFC-015: validate_all.sh Modernization

**Status:** Proposed
**File:** `validate_all.sh`

---

## Problem

`validate_all.sh` has three recurring quality issues: an arithmetic pattern
that silences real errors, hardcoded tool paths with no existence checks, and
duplicate env var setup across modes.

---

## Key Findings

### 1. `((FAILURES++)) || true` suppresses arithmetic exit codes

The `run_check` function (lines 44–53) uses:

```bash
# validate_all.sh:44-53
run_check() {
    local name="$1"
    shift
    if "$@"; then
        log "PASS: ${name}"
    else
        log "FAIL: ${name}"
        ((FAILURES++)) || true
    fi
}
```

`((FAILURES++))` is arithmetic evaluation. When `FAILURES` is `0`, the
expression `((0++))` evaluates to `0` (falsy in bash arithmetic context) and
returns exit code `1`. With `set -e` active, this would abort the script. The
`|| true` prevents that abort.

However, `|| true` also suppresses any unexpected non-zero exit from the
`((...))` expansion itself (e.g., a syntax error). The idiomatic bash pattern
that is safe under `set -e` without masking errors is:

```bash
FAILURES=$((FAILURES + 1))
```

This is a pure arithmetic assignment; its exit code is always `0`.

### 2. Tool paths are hardcoded without existence checks

The Python tool paths are derived from `VENV_DIR` (line 203) with no validation
beyond `[[ -d "${VENV_DIR}" ]]`:

```bash
# validate_all.sh:203-206
VENV_DIR="${SCRIPT_DIR}/.venv-lint"
if [[ -d "${VENV_DIR}" ]]; then
    RUFF="${VENV_DIR}/bin/ruff"
    BLACK="${VENV_DIR}/bin/black"
```

The individual executable checks (`[[ -x "${RUFF}" ]]`, `[[ -x "${BLACK}" ]]`)
are present for `ruff` and `black` (lines 228–239), but `PYTEST` (line 242) is
assigned before its existence is tested:

```bash
# validate_all.sh:242-264
PYTEST="${VENV_DIR}/bin/pytest"
if [[ -x "${PYTEST}" ]] && [[ ${#py_files[@]} -gt 0 ]]; then
```

`PYTEST` is declared with the same guard pattern, which is consistent. The
`shellcheck` path (lines 273–277) uses `command -v` with a fallback to
`/tmp/shellcheck`, which is correct.

The `go` binary is invoked directly (lines 193–200) with no `command -v go`
check. If Go is not installed, `go build` and `go test` will fail with an
unhelpful `command not found` message rather than a clear skip.

### 3. `SYGALDRY_PROJECT_ID` env var setup is duplicated across modes

The infra mode (lines 312–313) sets `_INFRA_PROJECT`:

```bash
# validate_all.sh:313
_INFRA_PROJECT="${SYGALDRY_PROJECT_ID:-zephyr-verify}"
```

This is an inline one-liner that is repeated conceptually across the three infra
`run_check` calls. For multi-repo and snapshot modes, no project ID is resolved.
These modes all need the same `SYGALDRY_PROJECT_ID` fallback logic but handle it
ad-hoc or not at all.

### 4. Manual case-based flag parsing

The flag parsing loop (lines 70–140) is a manual `case` statement over 13 flags.
This is not wrong, but it lacks:
- A `--help` or `-h` flag
- Any rejection of unknown flags (the default `*) shift` at line 136–138 silently
  discards unrecognized arguments)

```bash
# validate_all.sh:136-138
        *)
            shift
            ;;
```

An unknown flag is dropped without warning, making typos in flag names
invisible.

---

## Proposed Changes

### 1. Replace `((FAILURES++)) || true` with safe arithmetic

```bash
# Before
((FAILURES++)) || true

# After
FAILURES=$((FAILURES + 1))
```

Apply to both occurrences: `run_check` (line 51) and the pytest special case
(line 259).

### 2. Add a Go existence check

```bash
section "Go: build"
if ! command -v go >/dev/null 2>&1; then
    log "SKIP: go not found"
else
    run_check "go build ./cmd/worker" go build -C "${SCRIPT_DIR}/temporal" ./cmd/worker
    run_check "go build ./cmd/orchestrate" go build -C "${SCRIPT_DIR}/temporal" ./cmd/orchestrate
fi
```

### 3. Warn on unknown flags

```bash
        *)
            log "WARNING: unknown flag '$1' ignored" >&2
            shift
            ;;
```

### 4. Optionally extract env-setup into a function

If multiple modes need common env setup (project ID resolution, cache root
setup), extract:

```bash
setup_env() {
    SYGALDRY_PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-verify}"
    export SYGALDRY_PROJECT_ID
}
```

Call once at the top of each mode that requires it, rather than inlining the
default inline at each use site.

---

## Files Changed

| File | Action |
|------|--------|
| `validate_all.sh` | Replace `((FAILURES++)) || true`, add Go check, warn on unknown flags |

---

## Verification

```bash
shellcheck -s bash -S warning validate_all.sh
./validate_all.sh --quick
```

The script must exit `0` when all checks pass and `1` when any check fails.
Verify that the failure counter increments correctly when a check fails:

```bash
# Inject a deliberate failure
bash -c 'FAILURES=0; FAILURES=$((FAILURES + 1)); echo "FAILURES=${FAILURES}"'
# Expected: FAILURES=1
```
