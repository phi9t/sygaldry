# RFC-002: Rust as Container Infrastructure Foundation

**Status:** Draft — v3 (10-pass revision)
**Date:** 2026-03-16
**Priority:** High

---

## 1. Problem

The container infrastructure runs two parallel implementations. The Rust binary exists and is feature-complete, but the bash stack cannot be deleted because the Rust launcher still depends on bash scripts for entrypoint dispatch.

### 1.1 Current dispatch path

`bin/sygaldry:34-38` — Rust binary preferred for `shell|run|job|...`:
```bash
if [[ -x "${ZEPHYR_BIN}" ]]; then
    case "${1:-}" in
        shell|run|job|build|config|stage|validate|init|gpu-check|verify-spack|uv-install|hf-download|entrypoint)
            exec "${ZEPHYR_BIN}" "$@"
```

`bin/sygaldry:41-43` — bash fallback if binary not built:
```bash
readonly LAUNCHER="${SYGALDRY_HOME}/container/launch_container.sh"
readonly JOB_RUNNER="${SYGALDRY_HOME}/tools/zephyr_job"
```

`bin/sygaldry:103-113` — bash routes for `shell`, `run`, `job`:
```bash
shell) exec "${LAUNCHER}" "$@" ;;
run)   exec "${LAUNCHER}" --entrypoint run-job "$@" ;;
job)   exec "${JOB_RUNNER}" "$@" ;;
```

### 1.2 Critical blocker: launcher still validates bash scripts

`crates/zephyr/src/host/launcher.rs:77-104` — `resolve_entrypoint_dir()` checks that bash entrypoint scripts exist on the host:
```rust
// line 94-101
let host_entrypoint = config
    .sygaldry_home
    .join(format!("container/entrypoints/{entrypoint_name}.sh"));
if !host_entrypoint.exists() {
    return Err(ZephyrError::EntrypointNotFound(...));
}
```

This means: even when `sygaldry shell` routes through the Rust binary, the Rust launcher verifies `container/entrypoints/default.sh` exists before proceeding. If the bash scripts are deleted, `zephyr shell` breaks.

### 1.3 Gap: Rust launcher emits bash paths, not `zephyr entrypoint`

`crates/zephyr/src/host/docker_args.rs:26-43` — `resolve_entrypoint_path()` builds bash script paths:
```rust
// For non-baked images, docker runs: /workspace/container/entrypoints/default.sh
LaunchMode::Legacy => format!(
    "{}/container/entrypoints/{entrypoint_name}.sh",
    container_paths::WORKSPACE
)
```

Inside the container, `docker run ... /workspace/container/entrypoints/default.sh` runs the bash script, not `zephyr entrypoint default`.

The in-container Rust entrypoint system (`crates/zephyr/src/container/entrypoint.rs`) implements `zephyr entrypoint <name>` as a complete replacement for each bash script, but the launcher never invokes it.

### 1.4 Duplication inventory

| Bash | Rust | Lines overlap |
|------|------|--------------|
| `container/launch_container.sh` | `host/launcher.rs` + `host/docker_args.rs` | ~600 |
| `container/entrypoints/*.sh` (9 files, 745 LOC) | `container/entrypoint.rs` (850 LOC) | ~745 |
| `tools/zephyr_job` (~300 LOC) | `host/job.rs` (477 LOC) | ~265 |

---

## 2. Goals

1. Cut the Rust launcher's dependency on bash entrypoint file existence.
2. Make the Rust launcher dispatch to `zephyr entrypoint <name>` inside the container.
3. Delete `tools/zephyr_job` and `container/entrypoints/`.
4. Deprecate then delete `container/launch_container.sh`.
5. Slim `bin/sygaldry` to ~50 lines.

---

## 3. Non-Goals

- Changing any public CLI interface.
- Modifying the Dockerfile.
- Rewriting `host/docker_args.rs` (it is correct; only the entrypoint dispatch changes).

---

## 4. Phases

### Phase 1 — Add `zephyr entrypoint` dispatch to the Rust launcher

**File:** `crates/zephyr/src/host/launcher.rs`

Change `resolve_entrypoint_dir` to return a sentinel that signals "use Rust dispatch" instead of validating bash file existence:

```rust
// BEFORE (lines 77-104): validates bash script on host
fn resolve_entrypoint_dir(...) -> Result<Option<String>> {
    // ...
    let host_entrypoint = config.sygaldry_home.join(
        format!("container/entrypoints/{entrypoint_name}.sh"));
    if !host_entrypoint.exists() {
        return Err(ZephyrError::EntrypointNotFound(...));
    }
    Ok(None)  // → docker uses bash path via resolve_entrypoint_path
}
```

**File:** `crates/zephyr/src/host/docker_args.rs`

Add a new function `build_entrypoint_cmd` that returns `vec!["zephyr", "entrypoint", name]` when the image has the Rust binary baked in. Change `build()` to use this instead of `resolve_entrypoint_path()` when running with the current (development) image that has `zephyr` on `PATH`.

The simplest implementation: add an `--entrypoint zephyr` Docker flag + pass `entrypoint <name> [args...]` as CMD. This uses the in-container Rust binary unconditionally, eliminating the bash path:

```rust
// docker run ... --entrypoint zephyr <image> entrypoint run-job [args...]
fn build_docker_cmd(entrypoint_name: &str, passthrough: &[String]) -> Vec<String> {
    let mut cmd = vec!["--entrypoint".into(), "zephyr".into()];
    // image is appended by caller
    // CMD becomes: entrypoint <name> [passthrough...]
    cmd.push("entrypoint".into());
    cmd.push(entrypoint_name.into());
    cmd.extend_from_slice(passthrough);
    cmd
}
```

Prerequisite: verify `zephyr` is on `PATH` inside the container (it is, via Spack view or `/usr/local/bin`). Add a check in `requirements::check_all()` that confirms the image has `zephyr` available.

**Tests to add** (`host/launcher.rs` test block):
- `resolve_entrypoint_dir_uses_rust_when_available` — mock image label, assert Rust path chosen
- `build_docker_cmd_emits_zephyr_entrypoint` — assert `--entrypoint zephyr ... entrypoint default` in args

---

### Phase 2 — Delete `tools/zephyr_job`

`tools/zephyr_job` (~300 LOC) is superseded by `zephyr job` Rust subcommand (`host/job.rs`, 477 LOC).

```bash
git rm tools/zephyr_job
```

Remove from `bin/sygaldry`:
- Line 42: `readonly JOB_RUNNER="${SYGALDRY_HOME}/tools/zephyr_job"`
- Line 113: `exec "${JOB_RUNNER}" "$@"`

The `job` branch at `bin/sygaldry:111-114` is already unreachable when the Rust binary is built (line 34-38 catches it first). Make it explicit: after removing `JOB_RUNNER`, the bash `job)` branch should `die "zephyr binary not found — run: cargo build -p zephyr --release"`.

---

### Phase 3 — Delete `container/entrypoints/`

After Phase 1, the Rust launcher no longer validates bash script file existence. The bash entrypoints are no longer needed.

```bash
git rm -r container/entrypoints/
```

**Verify** all 9 entrypoints have Rust equivalents in `container/entrypoint.rs:10-21`:
```
"default"        → entrypoint_default
"run-job"        → entrypoint_run_job
"verify-gpu"     → gpu_check::run
"verify-spack"   → verify::run
"spack-build"    → entrypoint_spack_build
"spack-install"  → entrypoint_spack_install
"uv-install"     → uv_install::install
"hf-lora-setup"  → entrypoint_hf_lora_setup
"hf-download"    → entrypoint_hf_download
```
All 9 covered. ✓

---

### Phase 4 — Slim `bin/sygaldry` to ~50 lines

After Phases 1-3, the bash dispatcher's only job is to find the Rust binary. Target:

```bash
#!/usr/bin/env bash
set -eu -o pipefail
SYGALDRY_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export SYGALDRY_HOME

ZEPHYR_BIN="${SYGALDRY_HOME}/crates/zephyr/target/release/zephyr"
if [[ ! -x "${ZEPHYR_BIN}" ]]; then
    echo "[sygaldry] Rust binary not found. Build with:" >&2
    echo "  cargo build --release -p zephyr" >&2
    exit 127
fi

# Subcommands that delegate to non-Rust tools
case "${1:-}" in
    sail)      shift; exec "${SYGALDRY_HOME}/tools/agentic/run_improvement_loop.sh" "$@" ;;
    k3s)       shift; exec "${SYGALDRY_HOME}/k3s/bin/kentai-dispatch" "$@" ;;
    snapshot)  shift; exec "${SYGALDRY_HOME}/container/snapshot_all.sh" "$@" ;;
    validate)  shift; exec "${SYGALDRY_HOME}/validate_all.sh" "$@" ;;
    *)         exec "${ZEPHYR_BIN}" "$@" ;;
esac
```

The `sail` and `k3s` dispatches remain in bash because they delegate to Python/shell tools, not container operations. All container operations route through `exec "${ZEPHYR_BIN}"`.

Note: `completions`, `version`, `config show`, `help` are already handled inside the Rust binary.

---

### Phase 5 — Deprecate `container/launch_container.sh`

Add to top of file:
```bash
echo "[DEPRECATED] launch_container.sh is superseded by 'zephyr shell'." >&2
echo "             This file will be deleted after the next SAIL validation cycle." >&2
```

After SAIL runs clean for one cycle: `git rm container/launch_container.sh`.

---

## 5. Files Changed

| File | Action |
|------|--------|
| `crates/zephyr/src/host/launcher.rs` | Remove bash existence check; add `zephyr entrypoint` dispatch signal |
| `crates/zephyr/src/host/docker_args.rs` | `build_docker_cmd()` emits `--entrypoint zephyr ... entrypoint <name>` |
| `tools/zephyr_job` | Deleted |
| `container/entrypoints/` | Deleted (9 files) |
| `container/launch_container.sh` | Deprecation header → deleted in follow-up |
| `bin/sygaldry` | Slimmed to ~50 lines |

---

## 6. Verification

```bash
# Rust unit tests
cargo test -p zephyr

# Smoke tests (require built binary + running Docker)
sygaldry shell --dry-run         # routes through Rust, no bash scripts needed
sygaldry run -- echo hello       # Rust launcher, zephyr entrypoint run-job
sygaldry job run test -- echo 1  # Rust job runner

# Confirm bash scripts are gone
[[ ! -f container/entrypoints/default.sh ]] && echo OK

# Validate
./validate_all.sh --quick
```

---

## 7. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| `zephyr` not on `PATH` inside container | High | `requirements::check_all()` gates on it; `cargo test` validates |
| Bash entrypoints had undocumented behavior not in Rust | Medium | Full entrypoint coverage in `entrypoint.rs:10-21`; smoke test each name |
| Users with old `launch_container.sh` scripts | Low | Deprecation warning for one cycle |
| Fallback bash routes still reachable when binary missing | Medium | Phase 4 makes the fallback explicit: print error and exit 127 |
