use crate::config::ZephyrConfig;
use crate::error::{Result, ZephyrError};

/// Create all required host-side directories and write the layout version file.
pub fn setup_host_directories(config: &ZephyrConfig) -> Result<()> {
    config.layout.ensure_dirs()?;
    config.layout.write_layout_version()?;
    validate_layout(&config.layout)?;
    Ok(())
}

/// Validate that critical directories are writable after creation.
///
/// Catches permission issues early rather than failing mid-launch with
/// opaque IO errors deep in Docker argument building.
fn validate_layout(layout: &crate::paths::HostLayout) -> Result<()> {
    let critical = [
        (&layout.home, "home"),
        (&layout.config, "config"),
        (&layout.logs, "logs"),
        (&layout.leases, "leases"),
    ];

    for (dir, label) in &critical {
        // Try writing a canary file to verify write access
        let canary = dir.join(".zephyr_canary");
        std::fs::write(&canary, b"").map_err(|e| {
            ZephyrError::with_hint(
                format!("Directory '{}' ({label}) is not writable: {e}", dir.display()),
                "Check file permissions or ownership. The container user needs write access.",
            )
        })?;
        let _ = std::fs::remove_file(&canary);
    }

    // Verify spack store exists (it's a shared 42GB artifact — never auto-created)
    if layout.spack_store.exists() && !layout.spack_store.is_dir() {
        return Err(ZephyrError::with_hint(
            format!(
                "Spack store path exists but is not a directory: {}",
                layout.spack_store.display()
            ),
            "Remove the file and ensure the Spack store is a directory.",
        ));
    }

    Ok(())
}

/// Print a human-readable summary of the host layout for diagnostics.
#[allow(dead_code)]
pub fn print_layout_summary(layout: &crate::paths::HostLayout) {
    eprintln!("[zephyr] Host layout:");
    eprintln!("  cache_root:   {}", layout.cache_root.display());
    eprintln!("  project_root: {}", layout.project_root.display());
    eprintln!("  spack_store:  {} ({})", layout.spack_store.display(), dir_status(&layout.spack_store));
    eprintln!("  hf_cache:     {} ({})", layout.hf_cache.display(), dir_status(&layout.hf_cache));
    eprintln!("  uv_cache:     {} ({})", layout.uv_cache.display(), dir_status(&layout.uv_cache));
}

fn dir_status(path: &std::path::Path) -> &'static str {
    if !path.exists() {
        "missing"
    } else if path.is_dir() {
        "ok"
    } else {
        "NOT a directory"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::HostLayout;
    use std::path::Path;

    fn test_layout(root: &Path) -> HostLayout {
        HostLayout {
            cache_root: root.join("cache"),
            shared_root: root.join("shared"),
            build_root: root.join("build"),
            projects_root: root.join("projects"),
            project_root: root.join("project"),
            meta_root: root.join("meta"),
            home: root.join("project/home"),
            config: root.join("project/config"),
            local_share: root.join("project/local_share"),
            outputs: root.join("project/outputs"),
            workspace: root.join("project/workspace"),
            runs: root.join("project/runs"),
            leases: root.join("project/leases"),
            logs: root.join("project/logs"),
            spack_store: root.join("shared/spack_store"),
            bazel_cache: root.join("shared/bazel_cache"),
            hf_cache: root.join("shared/hf_cache"),
            uv_cache: root.join("shared/uv_cache"),
            torch_cache: root.join("shared/torch_cache"),
            triton_cache: root.join("shared/triton_cache"),
            nv_compute_cache: root.join("shared/nv_compute_cache"),
            jax_cache: root.join("shared/jax_cache"),
        }
    }

    #[test]
    fn validate_layout_succeeds_for_writable_dirs() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = test_layout(tmp.path());
        layout.ensure_dirs().unwrap();
        assert!(validate_layout(&layout).is_ok());
    }

    #[test]
    fn validate_layout_catches_spack_store_file_not_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = test_layout(tmp.path());
        layout.ensure_dirs().unwrap();

        // Replace spack_store dir with a file
        std::fs::remove_dir(&layout.spack_store).unwrap();
        std::fs::write(&layout.spack_store, b"not a dir").unwrap();

        let err = validate_layout(&layout).unwrap_err();
        let msg = format!("{err}");
        assert!(msg.contains("not a directory"), "got: {msg}");
    }

    #[test]
    fn dir_status_reports_correctly() {
        let tmp = tempfile::tempdir().unwrap();
        let existing = tmp.path().join("exists");
        std::fs::create_dir(&existing).unwrap();
        assert_eq!(dir_status(&existing), "ok");

        let missing = tmp.path().join("missing");
        assert_eq!(dir_status(&missing), "missing");

        let file = tmp.path().join("file");
        std::fs::write(&file, b"x").unwrap();
        assert_eq!(dir_status(&file), "NOT a directory");
    }
}
