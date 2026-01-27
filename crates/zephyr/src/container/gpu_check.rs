use crate::error::{Result, ZephyrError};
use std::process::Command;

/// GPU validation script run via python3.
///
/// Checks both PyTorch CUDA and JAX GPU availability, including
/// tensor ops and neural network forward/backward passes.
const GPU_CHECK_SCRIPT: &str = include_str!("../../scripts/gpu_check.py");

/// Run GPU validation.
pub fn run() -> Result<()> {
    // Ensure Spack view is on PATH
    let _ = super::spack::init_spack();
    if super::spack::activate_env().is_err() {
        let _ = super::spack::ensure_view_fallback();
    }
    let _ = super::cuda::setup_cuda_env();

    let status = Command::new("python3")
        .args(["-c", GPU_CHECK_SCRIPT])
        .status()?;

    if status.success() {
        Ok(())
    } else {
        Err(ZephyrError::GpuValidationFailed(
            "One or more GPU checks failed. See output above.".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_check_script_is_loaded() {
        assert!(!GPU_CHECK_SCRIPT.is_empty());
    }

    #[test]
    fn gpu_check_script_contains_torch_check() {
        assert!(GPU_CHECK_SCRIPT.contains("torch"));
        assert!(GPU_CHECK_SCRIPT.contains("cuda"));
    }

    #[test]
    fn gpu_check_script_contains_jax_check() {
        assert!(GPU_CHECK_SCRIPT.contains("jax"));
    }

    #[test]
    fn gpu_check_script_is_valid_python_structure() {
        assert!(GPU_CHECK_SCRIPT.contains("import"));
    }

    #[test]
    fn gpu_check_script_has_exit_on_failure() {
        assert!(GPU_CHECK_SCRIPT.contains("sys.exit(1)"));
    }

    #[test]
    fn gpu_check_script_tests_matmul() {
        assert!(GPU_CHECK_SCRIPT.contains("matmul"));
    }
}
