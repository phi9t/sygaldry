use crate::config::ZephyrConfig;
use crate::error::{Result, ZephyrError};
use crate::host::{cuda, dirs, docker_args, image, lease, requirements};
use std::time::Duration;

/// Default lease TTL (6 hours).
const LEASE_TTL_SECS: u64 = 21600;

/// Returns true when the in-container `zephyr` binary should be used as the
/// Docker entrypoint instead of a bash script.
///
/// Activated by either:
/// - `ZEPHYR_USE_RUST_ENTRYPOINTS=1` environment variable, or
/// - the image carrying a `sygaldry.zephyr.version` or
///   `sygaldry.entrypoints.baked=true` label.
pub(crate) fn image_has_rust_entrypoints(image_name: &str) -> bool {
    if std::env::var("ZEPHYR_USE_RUST_ENTRYPOINTS").as_deref() == Ok("1") {
        return true;
    }
    image::read_image_label(image_name, "sygaldry.zephyr.version").is_some()
        || image::read_image_label(image_name, "sygaldry.entrypoints.baked").as_deref()
            == Some("true")
}

/// Orchestrate a full container launch.
///
/// This is the Rust equivalent of `main()` in `launch_container.sh`.
pub fn launch(config: &ZephyrConfig, entrypoint_name: &str, passthrough_args: &[String]) -> Result<()> {
    let entrypoint_name = normalize_entrypoint_name(entrypoint_name);
    eprintln!("[zephyr] Starting container launcher...");

    // 1. Pre-flight checks
    requirements::check_all()?;

    // 2. CUDA version validation
    cuda::validate_cuda_version(&config.required_cuda)?;

    // 3. Setup host directories
    dirs::setup_host_directories(config)?;

    // 4. Build/check Docker image
    image::build_image(config, false)?;

    // 5. Detect if Spack is baked into the image
    let spack_baked = image::read_image_label(&config.image, "sygaldry.spack.baked")
        .as_deref()
        == Some("true");

    // 6. Detect dispatch mode: Rust-native entrypoints vs legacy bash
    let use_rust_ep = image_has_rust_entrypoints(&config.image);

    // 7. Acquire lease
    let _lease_guard = lease::acquire(
        config.lease_mode,
        &config.layout.leases,
        "gpu-all",
        &config.project_id,
        Duration::from_secs(LEASE_TTL_SECS),
        &config.run_id,
    )?;

    // 8. Build docker args and compose final command
    let mut cmd_args = if use_rust_ep {
        eprintln!("[zephyr] docker run --entrypoint zephyr (rust-native entrypoints)");
        let mut args = docker_args::build_rust_mode(config, spack_baked)?;
        args.push(config.image.clone());
        args.push("entrypoint".into());
        args.push(entrypoint_name.to_string());
        args
    } else {
        // Legacy bash path: resolve and validate the entrypoint script
        let entrypoint_container_dir =
            resolve_entrypoint_dir(&config.image, spack_baked, entrypoint_name, config)?;
        eprintln!("[zephyr] docker run (entrypoint={entrypoint_name})");
        let mut args = docker_args::build(
            config,
            entrypoint_name,
            spack_baked,
            entrypoint_container_dir.as_deref(),
        )?;
        args.push(config.image.clone());
        args
    };

    cmd_args.extend(passthrough_args.iter().cloned());

    let status = std::process::Command::new("docker")
        .arg("run")
        .args(&cmd_args)
        .status()?;

    // 9. Lease is released via Drop of _lease_guard

    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
    Ok(())
}

/// Determine where entrypoint scripts live inside the container.
///
/// Returns `Some(dir)` if entrypoints are baked into the image,
/// or `None` if they should be mounted from the host.
fn resolve_entrypoint_dir(
    image: &str,
    spack_baked: bool,
    entrypoint_name: &str,
    config: &ZephyrConfig,
) -> Result<Option<String>> {
    let entrypoint_name = normalize_entrypoint_name(entrypoint_name);

    // Check if entrypoints are baked via image label
    if image::read_image_label(image, "sygaldry.entrypoints.baked").as_deref() == Some("true") {
        return Ok(Some(crate::paths::container_paths::ENTRYPOINT_DIR.to_string()));
    }

    // Spack-baked images have entrypoints in /opt/spack_env/entrypoints
    if spack_baked {
        return Ok(Some(crate::paths::container_paths::SPACK_BAKED_ENTRYPOINT_DIR.to_string()));
    }

    // Verify the entrypoint exists on the host
    let host_entrypoint = config
        .sygaldry_home
        .join(format!("container/entrypoints/{entrypoint_name}.sh"));
    if !host_entrypoint.exists() {
        return Err(ZephyrError::EntrypointNotFound(
            host_entrypoint.display().to_string(),
        ));
    }

    // Entrypoints will be accessed via the mounted sygaldry repo
    Ok(None)
}

fn normalize_entrypoint_name(entrypoint_name: &str) -> &str {
    entrypoint_name.strip_suffix(".sh").unwrap_or(entrypoint_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn image_has_rust_entrypoints_respects_env_var() {
        std::env::set_var("ZEPHYR_USE_RUST_ENTRYPOINTS", "1");
        assert!(image_has_rust_entrypoints("any-image"));
        std::env::remove_var("ZEPHYR_USE_RUST_ENTRYPOINTS");
    }

    #[test]
    fn image_has_rust_entrypoints_false_without_env_or_label() {
        std::env::remove_var("ZEPHYR_USE_RUST_ENTRYPOINTS");
        // Nonexistent image → read_image_label returns None for both labels → false
        assert!(!image_has_rust_entrypoints(
            "sygaldry/zephyr:definitely-not-real-for-rust-ep-test"
        ));
    }

    #[test]
    fn lease_ttl_secs_is_six_hours() {
        assert_eq!(LEASE_TTL_SECS, 21600);
        assert_eq!(LEASE_TTL_SECS, 6 * 60 * 60);
    }

    #[test]
    fn resolve_entrypoint_dir_spack_baked_returns_spack_dir() {
        // spack_baked=true, no image label match → returns SPACK_BAKED_ENTRYPOINT_DIR
        // We can't easily mock read_image_label, but we can test with a
        // nonexistent image (label check returns None) + spack_baked=true
        let config = crate::config::ZephyrConfig::from_env(&crate::config::CliOverrides::default());
        let result = resolve_entrypoint_dir(
            "sygaldry/zephyr:nonexistent-test-image",
            true,
            "default",
            &config,
        );
        assert!(result.is_ok());
        let dir = result.unwrap();
        assert_eq!(
            dir,
            Some(crate::paths::container_paths::SPACK_BAKED_ENTRYPOINT_DIR.to_string())
        );
    }

    #[test]
    fn resolve_entrypoint_dir_host_missing_errors() {
        let config = crate::config::ZephyrConfig::from_env(&crate::config::CliOverrides {
            project_id: Some("test".into()),
            ..Default::default()
        });
        // spack_baked=false, nonexistent image (label returns None),
        // entrypoint doesn't exist on host
        let result = resolve_entrypoint_dir(
            "sygaldry/zephyr:nonexistent-test-image",
            false,
            "totally-nonexistent-entrypoint",
            &config,
        );
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("totally-nonexistent-entrypoint"));
    }

    #[test]
    fn resolve_entrypoint_dir_host_exists_returns_none() {
        let tmp = tempfile::tempdir().unwrap();
        let entrypoints = tmp.path().join("container/entrypoints");
        std::fs::create_dir_all(&entrypoints).unwrap();
        std::fs::write(entrypoints.join("default.sh"), "#!/bin/bash\n").unwrap();

        let mut config = crate::config::ZephyrConfig::from_env(&crate::config::CliOverrides::default());
        config.sygaldry_home = tmp.path().to_path_buf();

        let result = resolve_entrypoint_dir(
            "sygaldry/zephyr:nonexistent-test-image",
            false,
            "default",
            &config,
        );
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), None);
    }

    #[test]
    fn normalize_entrypoint_name_strips_shell_suffix() {
        assert_eq!(normalize_entrypoint_name("run-job.sh"), "run-job");
        assert_eq!(normalize_entrypoint_name("verify-gpu"), "verify-gpu");
    }
}
