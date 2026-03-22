use crate::error::{Result, ZephyrError};
use std::process::Command;

/// Detect host CUDA version from nvidia-smi output.
///
/// Returns `None` if nvidia-smi is not available or CUDA version cannot be parsed.
pub fn detect_host_cuda_version() -> Option<String> {
    let output = Command::new("nvidia-smi")
        .output()
        .ok()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_cuda_version(&stdout)
}

/// Parse "CUDA Version: X.Y" from nvidia-smi output.
fn parse_cuda_version(output: &str) -> Option<String> {
    for line in output.lines() {
        if let Some(pos) = line.find("CUDA Version:") {
            let rest = &line[pos + "CUDA Version:".len()..];
            let version = rest.split_whitespace().next()?;
            // Validate it looks like "12.9"
            let parts: Vec<&str> = version.split('.').collect();
            if parts.len() >= 2
                && parts[0].parse::<u32>().is_ok()
                && parts[1].parse::<u32>().is_ok()
            {
                return Some(version.to_string());
            }
        }
    }
    None
}

/// Compare two version strings "major.minor".
/// Returns true if `a` < `b`.
pub fn version_lt(a: &str, b: &str) -> bool {
    let parse = |s: &str| -> (u32, u32) {
        let mut parts = s.splitn(2, '.');
        let major = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        let minor = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
        (major, minor)
    };
    let (a_major, a_minor) = parse(a);
    let (b_major, b_minor) = parse(b);
    (a_major, a_minor) < (b_major, b_minor)
}

/// Validate that the host CUDA version meets the minimum requirement.
pub fn validate_cuda_version(required: &str) -> Result<()> {
    if let Some(host_version) = detect_host_cuda_version() {
        eprintln!("[zephyr] Host CUDA version: {host_version}");
        eprintln!("[zephyr] Required CUDA version: {required}");
        if version_lt(&host_version, required) {
            return Err(ZephyrError::CudaVersionTooOld {
                host: host_version,
                required: required.to_string(),
            });
        }
    } else {
        eprintln!("[zephyr] WARNING: Could not detect host CUDA version");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- parse_cuda_version --

    #[test]
    fn parse_cuda_version_from_nvidia_smi() {
        let output = r#"
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 560.35.03              Driver Version: 560.35.03      CUDA Version: 12.6     |
+-----------------------------------------------------------------------------------------+
"#;
        assert_eq!(parse_cuda_version(output), Some("12.6".to_string()));
    }

    #[test]
    fn parse_cuda_version_12_9() {
        let output = "| NVIDIA-SMI 575.00   Driver Version: 575.00    CUDA Version: 12.9     |";
        assert_eq!(parse_cuda_version(output), Some("12.9".to_string()));
    }

    #[test]
    fn parse_cuda_version_11_8() {
        let output = "CUDA Version: 11.8";
        assert_eq!(parse_cuda_version(output), Some("11.8".to_string()));
    }

    #[test]
    fn parse_cuda_version_missing() {
        assert_eq!(parse_cuda_version("no cuda here"), None);
    }

    #[test]
    fn parse_cuda_version_empty_string() {
        assert_eq!(parse_cuda_version(""), None);
    }

    #[test]
    fn parse_cuda_version_malformed() {
        assert_eq!(parse_cuda_version("CUDA Version: abc"), None);
        assert_eq!(parse_cuda_version("CUDA Version: "), None);
    }

    #[test]
    fn parse_cuda_version_only_major() {
        // "12" alone doesn't match because we require major.minor
        assert_eq!(parse_cuda_version("CUDA Version: 12"), None);
    }

    #[test]
    fn parse_cuda_version_with_extra_text() {
        let output = "Some header\nCUDA Version: 12.4  |\nSome footer";
        assert_eq!(parse_cuda_version(output), Some("12.4".to_string()));
    }

    // -- version_lt --

    #[test]
    fn version_lt_basic() {
        assert!(version_lt("11.8", "12.0"));
        assert!(version_lt("12.0", "12.9"));
    }

    #[test]
    fn version_lt_equal_is_false() {
        assert!(!version_lt("12.9", "12.9"));
        assert!(!version_lt("11.0", "11.0"));
    }

    #[test]
    fn version_lt_greater_is_false() {
        assert!(!version_lt("13.0", "12.9"));
        assert!(!version_lt("12.9", "12.0"));
    }

    #[test]
    fn version_lt_major_wins() {
        assert!(version_lt("1.99", "2.0"));
        assert!(!version_lt("2.0", "1.99"));
    }

    #[test]
    fn version_lt_single_digit() {
        assert!(version_lt("0.1", "0.2"));
        assert!(!version_lt("0.2", "0.1"));
    }

    #[test]
    fn version_lt_no_minor() {
        // Missing minor treated as 0
        assert!(version_lt("11", "12"));
        assert!(!version_lt("12", "11"));
    }

    #[test]
    fn version_lt_garbage_treated_as_zero() {
        assert!(!version_lt("abc", "def")); // both parse to (0, 0)
    }
}
