use crate::error::{Result, ZephyrError};
use crate::paths::container_paths;
use std::path::Path;
use std::process::Command;

/// Install packages with uv, respecting Spack constraints.
///
/// Replaces `container/entrypoints/uv-install.sh`.
pub fn install(packages: &[String], venv_dir: &str) -> Result<()> {
    // Initialize Spack for the view Python
    let _ = super::spack::init_spack();

    // Find Spack Python
    let spack_py = Path::new(container_paths::SPACK_VIEW).join("bin/python3");
    let python_bin = if spack_py.exists() {
        spack_py.display().to_string()
    } else {
        which::which("python3")
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| "python3".to_string())
    };

    // Check uv is available
    which::which("uv").map_err(|_| {
        ZephyrError::with_hint(
            "uv not found in PATH",
            "uv is installed in the container image; ensure you are inside.",
        )
    })?;

    // Create venv with Spack Python
    eprintln!("[zephyr] Creating venv at {venv_dir} with {python_bin}");
    run_cmd("uv", &["venv", "--python", &python_bin, "--system-site-packages", venv_dir])?;

    // Detect Python version for .pth file
    let py_ver = detect_py_version(&python_bin)?;
    let site_packages = format!("{venv_dir}/lib/python{py_ver}/site-packages");
    std::fs::create_dir_all(&site_packages)?;

    // Write Spack view .pth file
    let spack_site = format!("{}/lib/python{py_ver}/site-packages", container_paths::SPACK_VIEW);
    if Path::new(&spack_site).is_dir() {
        std::fs::write(format!("{site_packages}/spack-view.pth"), &spack_site)?;
    } else {
        eprintln!("[zephyr] WARNING: Spack view site-packages not found for python{py_ver}");
    }

    // Generate constraints file from Spack-owned packages
    let constraints_file = "/tmp/spack-constraints.txt";
    generate_constraints(&python_bin, constraints_file)?;

    // Build uv pip install args
    let mut uv_args = vec![
        "pip".to_string(),
        "install".to_string(),
        "--constraint".to_string(),
        constraints_file.to_string(),
    ];

    // Add NVIDIA overrides if present
    let nvidia_overrides = find_config_file("nvidia_overrides.txt");
    if let Some(ref path) = nvidia_overrides {
        uv_args.push("--override".to_string());
        uv_args.push(path.clone());
    }

    // Add packages
    uv_args.extend(packages.iter().cloned());

    let arg_refs: Vec<&str> = uv_args.iter().map(|s| s.as_str()).collect();
    run_cmd("uv", &arg_refs)?;

    eprintln!("[zephyr] Installed packages in {venv_dir}");
    eprintln!("[zephyr] Activate with: source {venv_dir}/bin/activate");
    Ok(())
}

fn detect_py_version(python_bin: &str) -> Result<String> {
    let output = Command::new(python_bin)
        .args(["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"])
        .output()?;
    let ver = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if ver.is_empty() {
        Ok(container_paths::SPACK_PYTHON_VERSION_FALLBACK.to_string())
    } else {
        Ok(ver)
    }
}

/// Python script that generates Spack constraints.
/// Uses __CONF_PATH__ as a placeholder replaced at runtime.
const CONSTRAINTS_SCRIPT: &str = include_str!("../../scripts/gen_constraints.py");

fn generate_constraints(python_bin: &str, output_path: &str) -> Result<()> {
    let spack_owned_conf = find_config_file("spack_owned_packages.conf")
        .unwrap_or_default();

    // Write script to temp file to avoid shell escaping issues with -c
    let script_path = "/tmp/zephyr-gen-constraints.py";
    let script = CONSTRAINTS_SCRIPT.replace("__CONF_PATH__", &spack_owned_conf);
    std::fs::write(script_path, &script)?;

    let output = Command::new(python_bin).args([script_path]).output()?;
    std::fs::write(output_path, &output.stdout)?;
    let _ = std::fs::remove_file(script_path);
    Ok(())
}

pub(crate) fn find_config_file(name: &str) -> Option<String> {
    let candidates = [
        format!("{}/{name}", container_paths::ENTRYPOINT_DIR),
        format!("/opt/spack_env/{name}"),
    ];
    for c in &candidates {
        if Path::new(c).exists() {
            return Some(c.clone());
        }
    }
    None
}

pub(crate) fn run_cmd(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program).args(args).status()?;
    if !status.success() {
        return Err(ZephyrError::CommandFailed {
            command: format!("{program} {}", args.join(" ")),
            code: status.code().unwrap_or(1),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_config_file_returns_none_outside_container() {
        // Neither /opt/container_entrypoints nor /opt/spack_env exist on host
        assert_eq!(find_config_file("nonexistent.conf"), None);
    }

    #[test]
    fn constraints_script_contains_placeholder() {
        assert!(CONSTRAINTS_SCRIPT.contains("__CONF_PATH__"));
    }

    #[test]
    fn constraints_script_placeholder_replaceable() {
        let replaced = CONSTRAINTS_SCRIPT.replace("__CONF_PATH__", "/tmp/test.conf");
        assert!(replaced.contains("/tmp/test.conf"));
        assert!(!replaced.contains("__CONF_PATH__"));
    }

    #[test]
    fn constraints_script_is_valid_python_structure() {
        // Verify key Python elements exist
        assert!(CONSTRAINTS_SCRIPT.contains("import importlib.metadata"));
        assert!(CONSTRAINTS_SCRIPT.contains("print("));
    }

    // -- run_cmd --

    #[test]
    fn run_cmd_returns_error_for_nonexistent_program() {
        let result = run_cmd("nonexistent-binary-xyz-abc", &["arg1"]);
        assert!(result.is_err());
    }

    #[test]
    fn run_cmd_succeeds_for_true() {
        let result = run_cmd("true", &[]);
        assert!(result.is_ok());
    }

    #[test]
    fn run_cmd_fails_for_false() {
        let result = run_cmd("false", &[]);
        assert!(result.is_err());
        match result.unwrap_err() {
            ZephyrError::CommandFailed { command, code } => {
                assert!(command.contains("false"));
                assert_eq!(code, 1);
            }
            e => panic!("expected CommandFailed, got: {e}"),
        }
    }

    // -- detect_py_version --

    #[test]
    fn detect_py_version_returns_fallback_for_nonexistent() {
        // Command::new will fail on nonexistent binary → Io error
        let result = detect_py_version("/nonexistent/python3");
        assert!(result.is_err());
    }

    #[test]
    fn detect_py_version_with_system_python() {
        // Adaptive: works only if python3 is in PATH
        if which::which("python3").is_ok() {
            let ver = detect_py_version("python3").unwrap();
            assert!(ver.contains('.'), "should have major.minor: {ver}");
        }
    }

    #[test]
    fn detect_py_version_fallback_on_empty_output() {
        // /usr/bin/true outputs nothing → empty version → returns fallback
        let ver = detect_py_version("true").unwrap();
        assert_eq!(ver, container_paths::SPACK_PYTHON_VERSION_FALLBACK);
    }

    // -- find_config_file --

    #[test]
    fn find_config_file_returns_none_for_specific_name() {
        // Verify specific names that don't exist outside container
        assert_eq!(find_config_file("nvidia_overrides.txt"), None);
        assert_eq!(find_config_file("spack_owned_packages.conf"), None);
        assert_eq!(find_config_file("llm_serving_overrides.txt"), None);
    }
}
