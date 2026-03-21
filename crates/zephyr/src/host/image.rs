use crate::config::{BuildPolicy, ZephyrConfig};
use crate::error::{Result, ZephyrError};
use std::process::Command;

/// Check if a Docker image exists locally.
fn image_exists(image: &str) -> bool {
    Command::new("docker")
        .args(["image", "inspect", image])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Get the creation timestamp of a Docker image (epoch seconds).
fn image_created_epoch(image: &str) -> Option<i64> {
    let output = Command::new("docker")
        .args(["image", "inspect", image, "--format={{.Created}}"])
        .output()
        .ok()?;
    let created = String::from_utf8_lossy(&output.stdout);
    let created = created.trim();
    chrono::DateTime::parse_from_rfc3339(created)
        .ok()
        .map(|dt| dt.timestamp())
}

/// Read a Docker image label.
pub fn read_image_label(image: &str, label: &str) -> Option<String> {
    let format = format!("{{{{index .Config.Labels \"{label}\"}}}}");
    let output = Command::new("docker")
        .args(["inspect", "--format", &format, image])
        .output()
        .ok()?;
    let val = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if val.is_empty() || val == "<no value>" {
        None
    } else {
        Some(val)
    }
}

/// Determine if we should build the image (pure logic, no side effects).
///
/// Returns `Ok(true)` to build, `Ok(false)` to skip, `Err` if Never policy + missing image.
fn should_build_decision(
    policy: BuildPolicy,
    img_exists: bool,
    df_mtime: Option<i64>,
    img_epoch: Option<i64>,
) -> Result<bool> {
    match policy {
        BuildPolicy::Never => {
            if !img_exists {
                return Err(ZephyrError::ImageNotFound {
                    image: "(policy=never)".to_string(),
                });
            }
            Ok(false)
        }
        BuildPolicy::Always => Ok(true),
        BuildPolicy::Auto => {
            if !img_exists {
                Ok(true)
            } else if let Some(df_mt) = df_mtime {
                let img_ts = img_epoch.unwrap_or(0);
                Ok(df_mt > img_ts)
            } else {
                Ok(false)
            }
        }
    }
}

/// Build the Docker image according to the configured policy.
pub fn build_image(config: &ZephyrConfig, force: bool) -> Result<()> {
    let policy = if force {
        BuildPolicy::Always
    } else {
        config.build_policy
    };

    let dockerfile = config
        .sygaldry_home
        .join("container/dev_container.dockerfile");
    let exists = image_exists(&config.image);
    let df_mtime = if dockerfile.exists() {
        std::fs::metadata(&dockerfile)
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
    } else {
        None
    };
    let img_epoch = if exists {
        image_created_epoch(&config.image)
    } else {
        None
    };

    if matches!(policy, BuildPolicy::Auto) && exists && df_mtime.is_some() && img_epoch.is_none() {
        eprintln!(
            "[zephyr] warning: could not determine image creation time for '{}'; assuming rebuild may be needed",
            config.image
        );
    }

    let should_build =
        should_build_decision(policy, exists, df_mtime, img_epoch).map_err(|err| match err {
            ZephyrError::ImageNotFound { .. } => ZephyrError::ImageNotFound {
                image: config.image.clone(),
            },
            other => other,
        })?;

    if !should_build {
        return Ok(());
    }

    if !dockerfile.exists() {
        return Err(ZephyrError::with_hint(
            format!("Dockerfile not found at {}", dockerfile.display()),
            "Ensure you're running from the sygaldry repository root.",
        ));
    }

    eprintln!("[zephyr] Building Docker image {}...", config.image);

    // SAFETY: getuid(2) and getgid(2) have no preconditions, dereference no
    // pointers, and are safe to call from any process context.
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };

    let status = Command::new("docker")
        .args([
            "build",
            "--file",
            &dockerfile.display().to_string(),
            "--tag",
            &config.image,
            "--build-arg",
            &format!("BAZEL_VERSION={}", config.bazel_version),
            "--build-arg",
            &format!("PYTHON_VERSION={}", config.python_version),
            "--build-arg",
            &format!("RUST_VERSION={}", config.rust_version),
            "--build-arg",
            &format!("GO_VERSION={}", config.go_version),
            "--build-arg",
            &format!("HOST_UID={uid}"),
            "--build-arg",
            &format!("HOST_GID={gid}"),
            &config.sygaldry_home.display().to_string(),
        ])
        .status()
        .map_err(ZephyrError::ImageBuildFailed)?;

    if !status.success() {
        return Err(ZephyrError::with_hint(
            "Docker image build failed",
            "Check the build output above for errors.",
        ));
    }

    eprintln!("[zephyr] Image {} built successfully.", config.image);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- read_image_label format string --

    #[test]
    fn label_format_string_uses_go_template() {
        let label = "sygaldry.spack.baked";
        let format = format!("{{{{index .Config.Labels \"{label}\"}}}}");
        assert!(format.contains("{{index .Config.Labels"));
        assert!(format.contains("sygaldry.spack.baked"));
    }

    // -- should_build_decision (pure logic) --

    #[test]
    fn should_build_never_no_image_returns_error() {
        let result = should_build_decision(BuildPolicy::Never, false, None, None);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("not found"));
    }

    #[test]
    fn should_build_never_with_image_returns_false() {
        let result = should_build_decision(BuildPolicy::Never, true, None, None);
        assert_eq!(result.unwrap(), false);
    }

    #[test]
    fn should_build_always_returns_true() {
        assert_eq!(
            should_build_decision(BuildPolicy::Always, true, None, None).unwrap(),
            true
        );
        assert_eq!(
            should_build_decision(BuildPolicy::Always, false, None, None).unwrap(),
            true
        );
    }

    #[test]
    fn should_build_auto_no_image_returns_true() {
        let result = should_build_decision(BuildPolicy::Auto, false, Some(100), Some(50));
        assert_eq!(result.unwrap(), true);
    }

    #[test]
    fn should_build_auto_image_exists_no_dockerfile_returns_false() {
        let result = should_build_decision(BuildPolicy::Auto, true, None, Some(100));
        assert_eq!(result.unwrap(), false);
    }

    #[test]
    fn should_build_auto_dockerfile_newer_returns_true() {
        let result = should_build_decision(BuildPolicy::Auto, true, Some(200), Some(100));
        assert_eq!(result.unwrap(), true);
    }

    #[test]
    fn should_build_auto_dockerfile_older_returns_false() {
        let result = should_build_decision(BuildPolicy::Auto, true, Some(50), Some(100));
        assert_eq!(result.unwrap(), false);
    }

    #[test]
    fn should_build_auto_same_timestamp_returns_false() {
        let result = should_build_decision(BuildPolicy::Auto, true, Some(100), Some(100));
        assert_eq!(result.unwrap(), false);
    }

    #[test]
    fn should_build_auto_missing_image_timestamp_falls_back_to_rebuild() {
        let result = should_build_decision(BuildPolicy::Auto, true, Some(100), None);
        assert_eq!(result.unwrap(), true);
    }

    // -- image_exists adaptive --

    #[test]
    fn image_exists_returns_false_for_nonexistent() {
        // Adaptive: works whether or not Docker daemon is available
        let result = image_exists("sygaldry/zephyr:definitely-not-real-abc123xyz");
        assert!(!result);
    }
}
