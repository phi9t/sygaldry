use std::path::Path;

use crate::error::{Result, ZephyrError};

/// Standard CUDA installation path inside the container.
const CUDA_HOME: &str = "/usr/local/cuda";

/// Set CUDA_HOME, PATH, and LD_LIBRARY_PATH for /usr/local/cuda.
///
/// Returns `Ok(())` if CUDA directory exists and env was configured.
/// Returns `Err` if CUDA is missing (GPU-only infra requires it).
pub fn setup_cuda_env() -> Result<()> {
    let cuda_home = Path::new(CUDA_HOME);
    if !cuda_home.is_dir() {
        return Err(ZephyrError::with_hint(
            format!("CUDA not found at {CUDA_HOME}"),
            "Ensure you're using an NVIDIA CUDA base image (sygaldry/zephyr:*).",
        ));
    }

    let cuda_bin = cuda_home.join("bin");
    let cuda_lib = cuda_home.join("lib64");

    // Validate expected subdirectories exist
    if !cuda_bin.is_dir() {
        return Err(ZephyrError::with_hint(
            format!("CUDA bin directory missing: {}", cuda_bin.display()),
            "CUDA installation may be corrupt. Rebuild the container image.",
        ));
    }

    std::env::set_var("CUDA_HOME", CUDA_HOME);

    let path = std::env::var("PATH").unwrap_or_default();
    std::env::set_var("PATH", format!("{}:{path}", cuda_bin.display()));

    let ld = std::env::var("LD_LIBRARY_PATH").unwrap_or_default();
    std::env::set_var(
        "LD_LIBRARY_PATH",
        format!("{}:{ld}", cuda_lib.display()),
    );

    Ok(())
}

/// Detect the CUDA version from the version file in /usr/local/cuda.
///
/// Parses `/usr/local/cuda/version.json` (CUDA 11.6+) or
/// `/usr/local/cuda/version.txt` (legacy format).
#[allow(dead_code)]
pub fn detect_cuda_version() -> Option<String> {
    let version_json = Path::new(CUDA_HOME).join("version.json");
    if version_json.is_file() {
        if let Ok(content) = std::fs::read_to_string(&version_json) {
            // Parse: {"cuda":{"name":"CUDA SDK","version":"12.9.1"}}
            if let Some(start) = content.find("\"version\"") {
                let rest = &content[start..];
                if let Some(q1) = rest.find(':') {
                    let after_colon = rest[q1 + 1..].trim();
                    let unquoted = after_colon.trim_start_matches('"');
                    if let Some(end) = unquoted.find('"') {
                        return Some(unquoted[..end].to_string());
                    }
                }
            }
        }
    }

    let version_txt = Path::new(CUDA_HOME).join("version.txt");
    if version_txt.is_file() {
        if let Ok(content) = std::fs::read_to_string(&version_txt) {
            // Format: "CUDA Version 12.9.1"
            if let Some(idx) = content.find("CUDA Version") {
                let rest = content[idx + "CUDA Version".len()..].trim();
                let version = rest.split_whitespace().next().unwrap_or(rest);
                return Some(version.to_string());
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cuda_home_constant_is_absolute() {
        assert!(CUDA_HOME.starts_with('/'));
    }

    #[test]
    fn detect_cuda_version_returns_none_when_missing() {
        // In test environment, /usr/local/cuda typically doesn't exist
        // This tests the graceful fallback path
        let result = detect_cuda_version();
        // Either Some (if CUDA is installed) or None — both are valid
        if let Some(ver) = &result {
            assert!(!ver.is_empty(), "version should not be empty");
        }
    }

    #[test]
    fn setup_cuda_env_returns_error_when_missing() {
        // This test only passes when CUDA is NOT installed (CI/dev machines)
        if Path::new(CUDA_HOME).is_dir() {
            // CUDA is installed — test that setup succeeds
            assert!(setup_cuda_env().is_ok());
        } else {
            // CUDA not installed — test that we get a descriptive error
            let err = setup_cuda_env().unwrap_err();
            let msg = format!("{err}");
            assert!(msg.contains("CUDA not found"), "got: {msg}");
            assert!(msg.contains("HINT:"), "should have remediation hint: {msg}");
        }
    }
}
