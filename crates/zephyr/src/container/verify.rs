use crate::error::{Result, ZephyrError};
use crate::paths::container_paths;
use std::path::Path;
use std::process::Command;

/// Full Spack verification (replaces verify-spack.sh).
///
/// Checks: Spack view exists, torch/jax importable, tensor ops, NN forward+backward.
pub fn run() -> Result<()> {
    // Initialize Spack
    super::spack::init_spack()?;
    super::spack::activate_env().map_err(|_| {
        ZephyrError::with_hint(
            "Spack environment not found",
            "Set SYGALDRY_SPACK_ENV to override, or build with spack-build.sh.",
        )
    })?;

    eprintln!("[verify-spack] === Step 1: Checking Spack view and packages ===");

    let view_bin = Path::new(container_paths::SPACK_VIEW).join("bin");
    if !view_bin.exists() {
        return Err(ZephyrError::with_hint(
            format!("Spack view not found at {}", container_paths::SPACK_VIEW),
            "Build with spack-build.sh or use a snapshot image.",
        ));
    }
    eprintln!("[verify-spack] Spack view: {} exists", container_paths::SPACK_VIEW);

    // Check torch import
    let spack_python = format!("{}/python3", view_bin.display());
    check_import(&spack_python, "torch", "py-torch")?;
    check_import(&spack_python, "jax", "py-jax")?;

    // Run the full verification script
    eprintln!("[verify-spack] === Step 2-4: Python verification ===");

    let status = Command::new("python3")
        .args(["-c", VERIFY_SCRIPT])
        .status()?;

    if status.success() {
        eprintln!("[verify-spack] === Verification complete ===");
        Ok(())
    } else {
        Err(ZephyrError::GpuValidationFailed(
            "Spack verification failed. See output above.".into(),
        ))
    }
}

fn check_import(python: &str, module: &str, pkg_name: &str) -> Result<()> {
    let status = Command::new(python)
        .args(["-c", &format!("import {module}")])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?;

    if status.success() {
        let output = Command::new(python)
            .args(["-c", &format!("import {module}; print({module}.__version__)")])
            .output()?;
        let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
        eprintln!("[verify-spack] {pkg_name}: found ({version})");
        Ok(())
    } else {
        Err(ZephyrError::with_hint(
            format!("{pkg_name} not importable from Spack view"),
            format!("Rebuild with spack-build.sh or check spack.lock for {pkg_name}."),
        ))
    }
}

/// Full verification Python script: tensor ops + NN forward/backward for both Torch and JAX.
const VERIFY_SCRIPT: &str = include_str!("../../scripts/verify_spack.py");

#[cfg(test)]
mod tests {
    use super::*;

    // -- VERIFY_SCRIPT content --

    #[test]
    fn verify_script_is_loaded() {
        assert!(!VERIFY_SCRIPT.is_empty());
    }

    #[test]
    fn verify_script_contains_torch_verification() {
        assert!(VERIFY_SCRIPT.contains("torch"));
        assert!(VERIFY_SCRIPT.contains("nn"));
    }

    #[test]
    fn verify_script_contains_jax_verification() {
        assert!(VERIFY_SCRIPT.contains("jax"));
    }

    #[test]
    fn verify_script_has_matmul_check() {
        assert!(VERIFY_SCRIPT.contains("matmul"));
    }

    #[test]
    fn verify_script_has_backward_pass() {
        assert!(VERIFY_SCRIPT.contains("backward"));
    }

    #[test]
    fn verify_script_has_gradient_check() {
        assert!(VERIFY_SCRIPT.contains("grad"));
    }

    // -- check_import format string --

    #[test]
    fn check_import_format_produces_valid_python() {
        let module = "torch";
        let import_stmt = format!("import {module}");
        assert_eq!(import_stmt, "import torch");
    }

    #[test]
    fn check_import_version_format_produces_valid_python() {
        let module = "jax";
        let version_stmt = format!("import {module}; print({module}.__version__)");
        assert_eq!(version_stmt, "import jax; print(jax.__version__)");
    }

    // -- view path construction --

    #[test]
    fn spack_view_bin_construction() {
        let view_bin = std::path::Path::new(container_paths::SPACK_VIEW).join("bin");
        assert!(view_bin.display().to_string().ends_with("/bin"));
        assert!(view_bin.display().to_string().starts_with(container_paths::SPACK_VIEW));
    }

    #[test]
    fn spack_python_path_construction() {
        let view_bin = std::path::Path::new(container_paths::SPACK_VIEW).join("bin");
        let spack_python = format!("{}/python3", view_bin.display());
        assert!(spack_python.contains("python3"));
        assert!(spack_python.starts_with(container_paths::SPACK_VIEW));
    }
}
