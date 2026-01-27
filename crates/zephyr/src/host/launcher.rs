use crate::config::ZephyrConfig;
use crate::error::{Result, ZephyrError};
use crate::host::{cuda, dirs, docker_args, image, lease, requirements};
use std::time::Duration;

/// Default lease TTL (6 hours).
const LEASE_TTL_SECS: u64 = 21600;

/// Orchestrate a full container launch.
///
/// This is the Rust equivalent of `main()` in `launch_container.sh`.
pub fn launch(config: &ZephyrConfig, entrypoint_name: &str, passthrough_args: &[String]) -> Result<()> {
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

    // 6. Resolve entrypoint container directory
    let entrypoint_container_dir = resolve_entrypoint_dir(&config.image, spack_baked, entrypoint_name, config)?;

    // 7. Acquire lease
    let _lease_guard = lease::acquire(
        config.lease_mode,
        &config.layout.leases,
        "gpu-all",
        &config.project_id,
        Duration::from_secs(LEASE_TTL_SECS),
        &config.run_id,
    )?;

    // 8. Build docker args
    let docker_args = docker_args::build(
        config,
        entrypoint_name,
        spack_baked,
        entrypoint_container_dir.as_deref(),
    )?;

    // 9. Execute docker run
    let mut cmd_args = docker_args;
    cmd_args.push(config.image.clone());
    cmd_args.extend(passthrough_args.iter().cloned());

    eprintln!("[zephyr] docker run (entrypoint={entrypoint_name})");

    let status = std::process::Command::new("docker")
        .arg("run")
        .args(&cmd_args)
        .status()?;

    // 10. Lease is released via Drop of _lease_guard

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

#[cfg(test)]
mod tests {
    use super::*;

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
}
