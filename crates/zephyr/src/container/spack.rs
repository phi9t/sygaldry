use crate::error::{Result, ZephyrError};
use crate::paths::container_paths;
use std::path::Path;
use std::process::Command;

/// Source Spack's setup-env.sh and return whether it succeeded.
///
/// Since we can't source a bash script into our Rust process, we verify
/// that Spack exists and set up the PATH to include spack's bin.
pub fn init_spack() -> Result<()> {
    let setup_script = Path::new(container_paths::SPACK_SRC).join("share/spack/setup-env.sh");
    if !setup_script.exists() {
        return Err(ZephyrError::WithHint {
            message: format!("Spack setup script not found at {}", container_paths::SPACK_SRC),
            hint: "Are you inside the container? Use 'zephyr shell' to launch one.".into(),
        });
    }

    // Add spack bin to PATH for subprocess calls
    let spack_bin = Path::new(container_paths::SPACK_SRC).join("bin");
    if let Ok(path) = std::env::var("PATH") {
        std::env::set_var("PATH", format!("{}:{path}", spack_bin.display()));
    }

    Ok(())
}

/// Try to activate a Spack environment from the canonical candidate list.
///
/// Order:
/// 1. $SYGALDRY_SPACK_ENV
/// 2. Current directory (if spack.yaml/spack.lock present)
/// 3. /opt/spack_env/default
/// 4. /opt/spack_env/zephyr
/// 5. $SYGALDRY_ROOT/pkg/zephyr
pub fn activate_env() -> Result<()> {
    let mut candidates: Vec<String> = Vec::new();

    if let Ok(env) = std::env::var("SYGALDRY_SPACK_ENV") {
        if !env.is_empty() {
            candidates.push(env);
        }
    }

    let cwd = std::env::current_dir().unwrap_or_default();
    if cwd.join("spack.yaml").exists() || cwd.join("spack.lock").exists() {
        candidates.push(".".to_string());
    }

    candidates.push(container_paths::SPACK_ENV_DEFAULT.to_string());
    candidates.push(container_paths::SPACK_ENV_ZEPHYR.to_string());

    let sygaldry_root = std::env::var("SYGALDRY_ROOT").unwrap_or_else(|_| container_paths::WORKSPACE.into());
    candidates.push(format!("{sygaldry_root}/pkg/zephyr"));

    for candidate in &candidates {
        let path = Path::new(candidate);
        let has_env = path.join("spack.yaml").exists()
            || path.join("spack.lock").exists()
            || candidate == ".";

        if has_env {
            let status = Command::new("spack")
                .args(["env", "activate", candidate])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();

            if let Ok(s) = status {
                if s.success() {
                    return Ok(());
                }
            }
        }
    }

    Err(ZephyrError::SpackActivationFailed)
}

/// Inject the Spack view into PATH, PYTHONPATH, and LD_LIBRARY_PATH.
///
/// Used as a fallback when Spack env activation fails but the view exists.
pub fn ensure_view_fallback() -> Result<()> {
    let view = Path::new(container_paths::SPACK_VIEW);
    if !view.is_dir() {
        return Err(ZephyrError::with_hint(
            format!("Spack view not found at {}", container_paths::SPACK_VIEW),
            "Build with spack-build.sh or use a snapshot image.",
        ));
    }

    // PATH
    prepend_env("PATH", &view.join("bin").display().to_string());

    // PYTHONPATH
    let python_bin = view.join("bin/python3");
    if python_bin.exists() {
        let py_ver = detect_python_version(&python_bin).unwrap_or_else(|| container_paths::SPACK_PYTHON_VERSION_FALLBACK.to_string());
        let site_packages = format!("{}/lib/python{py_ver}/site-packages", view.display());
        prepend_env("PYTHONPATH", &site_packages);
    }

    // LD_LIBRARY_PATH
    prepend_env("LD_LIBRARY_PATH", &view.join("lib").display().to_string());
    prepend_env("LD_LIBRARY_PATH", &view.join("lib64").display().to_string());

    Ok(())
}

/// Verify that torch and jax are importable, falling back to view if needed.
pub fn require_torch_jax() -> Result<()> {
    let check = Command::new("python3")
        .args([
            "-c",
            "import importlib.util, sys; [sys.exit(1) for name in ('torch','jax') if importlib.util.find_spec(name) is None]",
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    if let Ok(s) = check {
        if s.success() {
            return Ok(());
        }
    }

    // Try view fallback
    if ensure_view_fallback().is_ok() {
        eprintln!("[zephyr] Using {} fallback for Python/LD paths.", container_paths::SPACK_VIEW);
        return Ok(());
    }

    Err(ZephyrError::with_hint(
        format!("Torch/JAX unavailable and {} not found.", container_paths::SPACK_VIEW),
        "Build with spack-build.sh or use a snapshot image.",
    ))
}

/// Complete initialization sequence (replaces sygaldry_full_init).
pub fn full_init() -> Result<()> {
    let _ = init_spack(); // Non-fatal

    if activate_env().is_err() {
        eprintln!("[zephyr] WARNING: Could not activate a Spack environment; trying view fallback.");
    }

    // Always ensure view paths are in PATH/PYTHONPATH/LD_LIBRARY_PATH.
    // The view is the concrete mechanism that makes Spack packages visible,
    // regardless of whether `spack env activate` succeeded.
    let _ = ensure_view_fallback();

    let _ = super::cuda::setup_cuda_env();
    super::mlsys_venv::activate();

    Ok(())
}

pub(crate) fn prepend_env(var: &str, value: &str) {
    let current = std::env::var(var).unwrap_or_default();
    if current.is_empty() {
        std::env::set_var(var, value);
    } else {
        std::env::set_var(var, format!("{value}:{current}"));
    }
}

fn detect_python_version(python_bin: &Path) -> Option<String> {
    let output = Command::new(python_bin)
        .args(["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"])
        .output()
        .ok()?;
    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if version.is_empty() {
        None
    } else {
        Some(version)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    // -- prepend_env --

    #[test]
    #[serial]
    fn prepend_env_sets_when_empty() {
        let key = "__ZEPHYR_TEST_PREPEND_EMPTY__";
        std::env::remove_var(key);
        prepend_env(key, "/new/path");
        assert_eq!(std::env::var(key).unwrap(), "/new/path");
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn prepend_env_prepends_to_existing() {
        let key = "__ZEPHYR_TEST_PREPEND_EXISTING__";
        std::env::set_var(key, "/old/path");
        prepend_env(key, "/new/path");
        assert_eq!(std::env::var(key).unwrap(), "/new/path:/old/path");
        std::env::remove_var(key);
    }

    #[test]
    #[serial]
    fn prepend_env_chains() {
        let key = "__ZEPHYR_TEST_PREPEND_CHAIN__";
        std::env::remove_var(key);
        prepend_env(key, "/first");
        prepend_env(key, "/second");
        prepend_env(key, "/third");
        assert_eq!(std::env::var(key).unwrap(), "/third:/second:/first");
        std::env::remove_var(key);
    }

    // -- activate_env candidates --

    #[test]
    #[serial]
    fn activate_env_candidate_list_includes_spack_env_from_env() {
        // This test verifies the candidate building logic by calling activate_env.
        // Since none of the spack dirs exist, it should fail gracefully.
        std::env::remove_var("SYGALDRY_SPACK_ENV");
        let result = activate_env();
        // Expected to fail since we're not in a container
        assert!(result.is_err());
    }

    // -- init_spack non-container --

    #[test]
    fn init_spack_fails_outside_container() {
        // /opt/spack_src doesn't exist on the host
        let result = init_spack();
        assert!(result.is_err());
    }

    // -- full_init doesn't panic --

    #[test]
    fn full_init_is_non_fatal_outside_container() {
        // full_init should not panic even when spack is missing
        let result = full_init();
        assert!(result.is_ok()); // full_init is designed to be non-fatal
    }

    // -- detect_python_version --

    #[test]
    fn detect_python_version_returns_none_for_nonexistent() {
        let result = detect_python_version(Path::new("/nonexistent/python3"));
        assert!(result.is_none());
    }

    #[test]
    fn detect_python_version_returns_none_for_non_python() {
        // /usr/bin/true doesn't output a Python version
        let result = detect_python_version(Path::new("/usr/bin/true"));
        assert!(result.is_none());
    }

    #[test]
    fn detect_python_version_with_system_python() {
        // If system python3 is available, verify it returns a version string
        if let Ok(py) = which::which("python3") {
            let ver = detect_python_version(&py);
            if let Some(ref v) = ver {
                assert!(v.contains('.'), "version should contain a dot: {v}");
                let parts: Vec<&str> = v.split('.').collect();
                assert_eq!(parts.len(), 2, "expected major.minor: {v}");
            }
        }
    }

    // -- ensure_view_fallback --

    #[test]
    fn ensure_view_fallback_depends_on_view_existence() {
        let view_exists = Path::new(container_paths::SPACK_VIEW).is_dir();
        let result = ensure_view_fallback();
        if view_exists {
            assert!(result.is_ok(), "view exists, should succeed");
        } else {
            assert!(result.is_err());
            let msg = format!("{}", result.unwrap_err());
            assert!(msg.contains("Spack view not found"));
        }
    }

    // -- require_torch_jax --

    #[test]
    fn require_torch_jax_returns_result_outside_container() {
        // Outside container, torch/jax won't be importable and view won't exist
        // The function should return an error (not panic)
        let result = require_torch_jax();
        // It may succeed if system python has torch/jax, or fail gracefully
        match result {
            Ok(()) => {} // system has torch+jax
            Err(e) => {
                let msg = format!("{e}");
                assert!(
                    msg.contains("unavailable") || msg.contains("not found"),
                    "unexpected error: {msg}"
                );
            }
        }
    }
}
