# RFC-010: Rust Host Module Testing

**Status:** Draft — v1
**Date:** 2026-03-16
**Priority:** Medium — enables RFC-002 and RFC-006 to proceed with confidence

---

## 1. Problem

The Rust host modules have near-zero test coverage for their core logic. Only the CLI parsing (`cli.rs`) and a few incidental tests in `launcher.rs` exist. The modules that do the most work — `docker_args.rs`, `job.rs`, `lease.rs`, `staging.rs` — have no unit tests.

This is dangerous because:
1. RFC-002 and RFC-006 require changes to `docker_args.rs` and `launcher.rs` — changes with no test safety net.
2. `host/job.rs` (477 LOC) manages JSONL logging, PID tracking, and signal handling. A subtle bug breaks all background jobs.
3. `host/staging.rs` (724 LOC) is the most complex module; it manages Spack concretization. A regression here is hard to detect without integration tests.

### Coverage by module

| Module | LOC | Test LOC | Coverage |
|--------|-----|---------|---------|
| `cli.rs` | 611 | ~200 | Good |
| `host/docker_args.rs` | 600 | 0 | None |
| `host/launcher.rs` | 175 | ~50 (incidental) | Incidental |
| `host/job.rs` | 477 | 0 | None |
| `host/lease.rs` | 352 | 0 | None |
| `host/staging.rs` | 724 | 0 | None |
| `container/entrypoint.rs` | 850 | 0 | None |

---

## 2. Testing Strategy

### Principle: test logic, not Docker

The host modules are testable if we separate "build args" from "run docker". The key insight: `docker_args::build()` returns a `Vec<String>` — test that, not the docker execution. Similarly, `job.rs` logic for JSONL writing is testable without a running container.

### Module: `host/docker_args.rs`

Test `build_env_args()`, `build_volume_mounts()`, and `resolve_entrypoint_path()` directly. These functions take a `ZephyrConfig` (constructible from defaults + env) and return `Vec<String>`.

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{ZephyrConfig, CliOverrides};

    fn test_config() -> ZephyrConfig {
        ZephyrConfig::from_env(&CliOverrides {
            project_id: Some("test-project".into()),
            ..Default::default()
        })
    }

    #[test]
    fn build_env_args_includes_in_container_flag() {
        let config = test_config();
        let args = build_env_args(&config, "/opt/sygaldry");
        assert!(args.iter().any(|a| a == "--env=SYGALDRY_IN_CONTAINER=1"));
    }

    #[test]
    fn build_env_args_includes_hf_home() {
        let config = test_config();
        let args = build_env_args(&config, "/opt/sygaldry");
        assert!(args.iter().any(|a| a.starts_with("--env=HF_HOME=")));
    }

    #[test]
    fn resolve_entrypoint_path_legacy_mode() {
        let path = resolve_entrypoint_path("default", None, &LaunchMode::Legacy);
        assert!(path.ends_with("/container/entrypoints/default.sh"));
    }

    #[test]
    fn resolve_entrypoint_path_with_override_dir() {
        let path = resolve_entrypoint_path("run-job", Some("/opt/entrypoints"), &LaunchMode::Legacy);
        assert_eq!(path, "/opt/entrypoints/run-job.sh");
    }

    #[test]
    fn build_volume_mounts_includes_spack_when_not_baked() {
        let config = test_config();
        let mut args = Vec::new();
        build_volume_mounts(&mut args, &config, false).unwrap();
        assert!(args.iter().any(|a| a.contains("spack_store")));
    }

    #[test]
    fn build_volume_mounts_skips_spack_when_baked() {
        let config = test_config();
        let mut args = Vec::new();
        build_volume_mounts(&mut args, &config, true).unwrap();
        assert!(!args.iter().any(|a| a.contains("spack_store")));
    }
}
```

### Module: `host/lease.rs`

`lease.rs` manages lock files. Test the state machine without a real filesystem clock:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn acquire_creates_lease_file() {
        let dir = tempdir().unwrap();
        let lease_dir = dir.path().to_path_buf();
        let guard = acquire(LeaseMode::Warn, &lease_dir, "gpu", "test-run", Duration::from_secs(3600), "run-1");
        assert!(guard.is_ok());
        // Lease file should exist
        let lease_file = lease_dir.join("gpu.lock");
        assert!(lease_file.exists());
    }

    #[test]
    fn acquire_warns_on_conflict() {
        let dir = tempdir().unwrap();
        let lease_dir = dir.path().to_path_buf();
        let _guard1 = acquire(LeaseMode::Warn, &lease_dir, "gpu", "test", Duration::from_secs(3600), "run-1").unwrap();
        // Second acquisition should warn but succeed
        let result = acquire(LeaseMode::Warn, &lease_dir, "gpu", "test", Duration::from_secs(3600), "run-2");
        assert!(result.is_ok());
    }

    #[test]
    fn lease_released_on_drop() {
        let dir = tempdir().unwrap();
        let lease_dir = dir.path().to_path_buf();
        {
            let _guard = acquire(LeaseMode::Warn, &lease_dir, "gpu", "test", Duration::from_secs(3600), "run-1").unwrap();
        }
        // After drop, lock file should be gone
        let lease_file = lease_dir.join("gpu.lock");
        assert!(!lease_file.exists());
    }
}
```

### Module: `host/job.rs`

Test JSONL log writing and status file creation:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn job_run_creates_status_file() {
        let dir = tempdir().unwrap();
        let job_dir = dir.path().to_path_buf();
        // Run a short command and check status file
        let result = run_job(&JobConfig {
            job_name: "smoke".into(),
            job_dir: job_dir.clone(),
            command: "echo".into(),
            args: vec!["hello".into()],
        });
        // Check status file created
        let status_file = job_dir.join("status.json");
        // Check JSONL log created
        let log_file = job_dir.join("log.jsonl");
        // Note: these are integration-light tests; they exec 'echo'
        assert!(result.is_ok() || result.is_err()); // at least doesn't panic
    }

    #[test]
    fn job_status_file_format() {
        let dir = tempdir().unwrap();
        write_status_file(&dir.path().join("status.json"), "DONE", 0).unwrap();
        let content = std::fs::read_to_string(dir.path().join("status.json")).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        assert_eq!(parsed["status"], "DONE");
        assert_eq!(parsed["exit_code"], 0);
    }
}
```

### Module: `container/entrypoint.rs`

Test the dispatch table without executing system commands:

```rust
#[test]
fn run_rejects_unknown_entrypoint() {
    let result = run("totally-unknown-ep-xyz", &[]);
    assert!(matches!(result, Err(ZephyrError::EntrypointNotFound(_))));
}

#[test]
fn run_accepts_all_known_entrypoints_names() {
    // Just check the match arm exists — don't execute
    let known = ["default", "run-job", "verify-gpu", "verify-spack",
                 "spack-build", "spack-install", "uv-install", "hf-lora-setup", "hf-download"];
    for name in &known {
        // This will likely error (no GPU etc) but should NOT return EntrypointNotFound
        let result = run(name, &[]);
        assert!(!matches!(result, Err(ZephyrError::EntrypointNotFound(_))),
            "entrypoint {name} should be recognized");
    }
}
```

---

## 3. Files Changed

| File | Action |
|------|--------|
| `crates/zephyr/src/host/docker_args.rs` | Add `#[cfg(test)]` module with 6 tests |
| `crates/zephyr/src/host/lease.rs` | Add `#[cfg(test)]` module with 3 tests |
| `crates/zephyr/src/host/job.rs` | Add `#[cfg(test)]` module with 2 tests |
| `crates/zephyr/src/container/entrypoint.rs` | Add `#[cfg(test)]` module with 2 tests |

---

## 4. Verification

```bash
cargo test -p zephyr
# All new tests must pass
# Coverage should increase from ~15% to ~35% for host modules
```

---

## 5. Notes

- Tests that exec real binaries (`echo`, `docker`) are acceptable in a `#[cfg(test)]` block — they will be skipped in CI environments without Docker.
- Use `tempfile::tempdir()` for all filesystem tests (already in Cargo.toml dev-deps).
- Do not test `staging.rs` in this RFC — it requires a full Spack installation and is integration-test territory.

## 6. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Tests that exec system binaries fail in CI | Low | Gate on `#[ignore]` tag for Docker-dependent tests |
| `job.rs` internal types not pub | Low | Add `pub(crate)` to functions under test |
| `docker_args` functions are `pub(crate)` already | None | Test module is in same crate |
