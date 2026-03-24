use crate::config::LeaseMode;
use crate::error::{Result, ZephyrError};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// RAII guard that removes the lease file on drop.
pub struct LeaseGuard {
    path: PathBuf,
}

impl Drop for LeaseGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

impl LeaseGuard {
    #[cfg(test)]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

fn lease_file_for(dir: &Path, resource: &str) -> PathBuf {
    dir.join(format!("{resource}.lease"))
}

/// Read the expiry epoch from an existing lease file.
fn read_lease_expiry(path: &Path) -> Option<i64> {
    let content = std::fs::read_to_string(path).ok()?;
    for line in content.lines() {
        if let Some(val) = line.strip_prefix("expires_epoch=") {
            return val.trim().parse().ok();
        }
    }
    None
}

/// Read the PID from an existing lease file.
fn read_lease_pid(path: &Path) -> Option<i32> {
    let content = std::fs::read_to_string(path).ok()?;
    for line in content.lines() {
        if let Some(val) = line.strip_prefix("pid=") {
            return val.trim().parse().ok();
        }
    }
    None
}

/// Check whether a PID refers to a running process via kill(pid, 0).
/// Returns false only when ESRCH (no such process); treats EPERM as alive.
fn pid_is_alive(pid: i32) -> bool {
    let ret = unsafe { libc::kill(pid, 0) };
    if ret == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

/// Release a lease for a resource.
///
/// If `force` is false and the holding PID is still alive, returns an error.
/// If the PID is dead (or no PID recorded), or `force` is true, removes the lease file.
pub fn release(dir: &Path, resource: &str, force: bool) -> Result<()> {
    let lease_file = lease_file_for(dir, resource);
    if !lease_file.exists() {
        println!("no lease file found for {resource}");
        return Ok(());
    }

    if !force {
        if let Some(pid) = read_lease_pid(&lease_file) {
            if pid_is_alive(pid) {
                eprintln!(
                    "[zephyr] warn: lease is held by running process PID {pid}; use --force to override"
                );
                return Err(ZephyrError::LeaseConflict {
                    resource: resource.to_string(),
                    lease_file,
                });
            }
        }
    }

    std::fs::remove_file(&lease_file)?;
    println!("lease released");
    Ok(())
}

/// Attempt to acquire a lease on a resource.
///
/// Returns `Some(LeaseGuard)` on success (or if mode is Off, returns None).
/// The guard releases the lease on drop.
pub fn acquire(
    mode: LeaseMode,
    dir: &Path,
    resource: &str,
    owner: &str,
    ttl: Duration,
    run_id: &str,
) -> Result<Option<LeaseGuard>> {
    if mode == LeaseMode::Off {
        return Ok(None);
    }

    std::fs::create_dir_all(dir)?;
    let lease_file = lease_file_for(dir, resource);

    let now = chrono::Utc::now().timestamp();

    // Check existing lease
    if lease_file.exists() {
        if let Some(expiry) = read_lease_expiry(&lease_file) {
            if expiry >= now {
                // Check if the holding process is still alive before conflicting.
                if let Some(pid) = read_lease_pid(&lease_file) {
                    if !pid_is_alive(pid) {
                        eprintln!(
                            "[zephyr] warn: stale lease found for PID {pid} (process not running); recovering"
                        );
                        // Fall through to overwrite the stale lease.
                    } else {
                        let msg = format!("Resource lease exists ({resource}) at {}", lease_file.display());
                        match mode {
                            LeaseMode::Enforce => {
                                return Err(ZephyrError::LeaseConflict {
                                    resource: resource.to_string(),
                                    lease_file,
                                });
                            }
                            LeaseMode::Warn => {
                                eprintln!("[zephyr] WARNING: {msg}");
                            }
                            LeaseMode::Off => unreachable!(),
                        }
                    }
                } else {
                    let msg = format!("Resource lease exists ({resource}) at {}", lease_file.display());
                    match mode {
                        LeaseMode::Enforce => {
                            return Err(ZephyrError::LeaseConflict {
                                resource: resource.to_string(),
                                lease_file,
                            });
                        }
                        LeaseMode::Warn => {
                            eprintln!("[zephyr] WARNING: {msg}");
                        }
                        LeaseMode::Off => unreachable!(),
                    }
                }
            }
        }
    }

    // Write new lease
    let expires = now + ttl.as_secs() as i64;
    let pid = std::process::id();
    let content = format!(
        "resource={resource}\n\
         owner={owner}\n\
         run_id={run_id}\n\
         pid={pid}\n\
         created_epoch={now}\n\
         expires_epoch={expires}\n"
    );
    std::fs::write(&lease_file, content)?;

    Ok(Some(LeaseGuard { path: lease_file }))
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- lease_file_for --

    #[test]
    fn lease_file_for_builds_path() {
        let dir = std::path::Path::new("/tmp/leases");
        let path = lease_file_for(dir, "gpu-all");
        assert_eq!(path, PathBuf::from("/tmp/leases/gpu-all.lease"));
    }

    #[test]
    fn lease_file_for_handles_special_chars() {
        let dir = std::path::Path::new("/tmp/leases");
        let path = lease_file_for(dir, "gpu-0");
        assert_eq!(path, PathBuf::from("/tmp/leases/gpu-0.lease"));
    }

    // -- read_lease_expiry --

    #[test]
    fn read_lease_expiry_parses_valid() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("test.lease");
        std::fs::write(&f, "resource=gpu\nexpires_epoch=1700000000\n").unwrap();
        assert_eq!(read_lease_expiry(&f), Some(1700000000));
    }

    #[test]
    fn read_lease_expiry_returns_none_for_missing_file() {
        let path = Path::new("/tmp/__nonexistent_lease_test__");
        assert_eq!(read_lease_expiry(path), None);
    }

    #[test]
    fn read_lease_expiry_returns_none_for_bad_content() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("bad.lease");
        std::fs::write(&f, "no_expiry_here=true\n").unwrap();
        assert_eq!(read_lease_expiry(&f), None);
    }

    #[test]
    fn read_lease_expiry_returns_none_for_non_numeric() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("bad2.lease");
        std::fs::write(&f, "expires_epoch=not_a_number\n").unwrap();
        assert_eq!(read_lease_expiry(&f), None);
    }

    // -- acquire --

    #[test]
    fn acquire_and_drop_removes_file() {
        let tmp = tempfile::tempdir().unwrap();
        let guard = acquire(
            LeaseMode::Warn,
            tmp.path(),
            "test-gpu",
            "test-owner",
            Duration::from_secs(60),
            "run-test",
        )
        .unwrap()
        .unwrap();

        let path = guard.path().to_path_buf();
        assert!(path.exists());
        drop(guard);
        assert!(!path.exists());
    }

    #[test]
    fn acquire_off_returns_none() {
        let tmp = tempfile::tempdir().unwrap();
        let guard = acquire(
            LeaseMode::Off,
            tmp.path(),
            "test-gpu",
            "test-owner",
            Duration::from_secs(60),
            "run-test",
        )
        .unwrap();
        assert!(guard.is_none());
    }

    #[test]
    fn acquire_off_does_not_create_file() {
        let tmp = tempfile::tempdir().unwrap();
        let _ = acquire(
            LeaseMode::Off,
            tmp.path(),
            "test-gpu",
            "test-owner",
            Duration::from_secs(60),
            "run-test",
        )
        .unwrap();
        let lease = tmp.path().join("test-gpu.lease");
        assert!(!lease.exists());
    }

    #[test]
    fn acquire_enforce_conflicts() {
        let tmp = tempfile::tempdir().unwrap();
        let _guard1 = acquire(
            LeaseMode::Enforce,
            tmp.path(),
            "test-gpu",
            "owner1",
            Duration::from_secs(3600),
            "run-1",
        )
        .unwrap();

        let result = acquire(
            LeaseMode::Enforce,
            tmp.path(),
            "test-gpu",
            "owner2",
            Duration::from_secs(3600),
            "run-2",
        );
        assert!(result.is_err());
    }

    #[test]
    fn acquire_warn_allows_conflict() {
        let tmp = tempfile::tempdir().unwrap();
        let _guard1 = acquire(
            LeaseMode::Warn,
            tmp.path(),
            "test-gpu",
            "owner1",
            Duration::from_secs(3600),
            "run-1",
        )
        .unwrap();

        // Warn mode: acquire succeeds even with existing lease
        let guard2 = acquire(
            LeaseMode::Warn,
            tmp.path(),
            "test-gpu",
            "owner2",
            Duration::from_secs(3600),
            "run-2",
        );
        assert!(guard2.is_ok());
        assert!(guard2.unwrap().is_some());
    }

    #[test]
    fn acquire_creates_dir_if_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let lease_dir = tmp.path().join("nested").join("leases");
        assert!(!lease_dir.exists());

        let _guard = acquire(
            LeaseMode::Warn,
            &lease_dir,
            "test-gpu",
            "owner",
            Duration::from_secs(60),
            "run-1",
        )
        .unwrap();
        assert!(lease_dir.exists());
    }

    #[test]
    fn acquire_writes_all_fields() {
        let tmp = tempfile::tempdir().unwrap();
        let guard = acquire(
            LeaseMode::Warn,
            tmp.path(),
            "gpu-all",
            "my-project",
            Duration::from_secs(3600),
            "run-42",
        )
        .unwrap()
        .unwrap();

        let content = std::fs::read_to_string(guard.path()).unwrap();
        assert!(content.contains("resource=gpu-all"));
        assert!(content.contains("owner=my-project"));
        assert!(content.contains("run_id=run-42"));
        assert!(content.contains(&format!("pid={}", std::process::id())));
        assert!(content.contains("created_epoch="));
        assert!(content.contains("expires_epoch="));
    }

    #[test]
    fn acquire_expired_lease_allows_new_acquire_enforce() {
        let tmp = tempfile::tempdir().unwrap();
        // Write an expired lease manually
        let lease_file = tmp.path().join("test-gpu.lease");
        let past = chrono::Utc::now().timestamp() - 100;
        std::fs::write(
            &lease_file,
            format!("resource=test-gpu\nexpires_epoch={past}\n"),
        )
        .unwrap();

        // Should succeed even in enforce mode because lease is expired
        let result = acquire(
            LeaseMode::Enforce,
            tmp.path(),
            "test-gpu",
            "new-owner",
            Duration::from_secs(60),
            "run-new",
        );
        assert!(result.is_ok());
    }

    #[test]
    fn acquire_different_resource_no_conflict() {
        let tmp = tempfile::tempdir().unwrap();
        let _guard1 = acquire(
            LeaseMode::Enforce,
            tmp.path(),
            "gpu-0",
            "owner1",
            Duration::from_secs(3600),
            "run-1",
        )
        .unwrap();

        let result = acquire(
            LeaseMode::Enforce,
            tmp.path(),
            "gpu-1",
            "owner2",
            Duration::from_secs(3600),
            "run-2",
        );
        assert!(result.is_ok());
    }

    #[test]
    fn test_acquire_stale_pid_recovers() {
        let tmp = tempfile::tempdir().unwrap();
        // Write a lease with a dead PID (PID 1 always exists, but use a PID that
        // will never be a running process: i32::MAX is effectively guaranteed dead).
        let lease_file = tmp.path().join("test-gpu.lease");
        let future = chrono::Utc::now().timestamp() + 3600;
        std::fs::write(
            &lease_file,
            format!("resource=test-gpu\npid=2147483647\nexpires_epoch={future}\n"),
        )
        .unwrap();

        // Should succeed in enforce mode because the PID is dead.
        let result = acquire(
            LeaseMode::Enforce,
            tmp.path(),
            "test-gpu",
            "new-owner",
            Duration::from_secs(60),
            "run-recovery",
        );
        assert!(result.is_ok(), "expected stale-lease recovery");
    }

    #[test]
    fn release_removes_stale_lease() {
        let tmp = tempfile::tempdir().unwrap();
        let lease_file = tmp.path().join("gpu-all.lease");
        let future = chrono::Utc::now().timestamp() + 3600;
        // Write a lease with a dead PID.
        std::fs::write(
            &lease_file,
            format!("resource=gpu-all\npid=2147483647\nexpires_epoch={future}\n"),
        )
        .unwrap();

        let result = release(tmp.path(), "gpu-all", false);
        assert!(result.is_ok());
        assert!(!lease_file.exists());
    }

    #[test]
    fn release_force_removes_any_lease() {
        let tmp = tempfile::tempdir().unwrap();
        let lease_file = tmp.path().join("gpu-all.lease");
        let future = chrono::Utc::now().timestamp() + 3600;
        let pid = std::process::id() as i32;
        std::fs::write(
            &lease_file,
            format!("resource=gpu-all\npid={pid}\nexpires_epoch={future}\n"),
        )
        .unwrap();

        let result = release(tmp.path(), "gpu-all", true);
        assert!(result.is_ok());
        assert!(!lease_file.exists());
    }

    #[test]
    fn release_no_lease_file_is_ok() {
        let tmp = tempfile::tempdir().unwrap();
        let result = release(tmp.path(), "gpu-all", false);
        assert!(result.is_ok());
    }
}
