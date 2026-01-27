use crate::error::{Result, ZephyrError};
use std::process::Command;

/// Verify that Docker and NVIDIA runtime are available on the host.
pub fn check_all() -> Result<()> {
    check_docker_installed()?;
    check_docker_daemon()?;
    check_nvidia_runtime()?;
    Ok(())
}

fn check_docker_installed() -> Result<()> {
    which::which("docker").map_err(|_| ZephyrError::DockerUnavailable)?;
    Ok(())
}

fn check_docker_daemon() -> Result<()> {
    let status = Command::new("docker")
        .args(["info"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|_| ZephyrError::DockerDaemonDown)?;

    if !status.success() {
        return Err(ZephyrError::DockerDaemonDown);
    }
    Ok(())
}

fn check_nvidia_runtime() -> Result<()> {
    let output = Command::new("docker")
        .args(["info"])
        .output()
        .map_err(|_| ZephyrError::DockerDaemonDown)?;

    let info = String::from_utf8_lossy(&output.stdout);
    if !info.contains("nvidia") {
        return Err(ZephyrError::NoNvidiaRuntime);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_docker_installed_uses_which() {
        let result = check_docker_installed();
        // Adaptive: succeeds if docker is installed, fails with DockerUnavailable if not
        match result {
            Ok(()) => {} // docker found
            Err(ZephyrError::DockerUnavailable) => {} // docker not found, correct error
            Err(e) => panic!("unexpected error variant: {e}"),
        }
    }

    #[test]
    fn check_all_returns_structured_error_when_docker_missing() {
        // If docker isn't installed, check_all should fail with DockerUnavailable
        // If docker is installed but daemon down, DockerDaemonDown
        // If everything works, Ok
        let result = check_all();
        match result {
            Ok(()) => {}
            Err(ZephyrError::DockerUnavailable) => {}
            Err(ZephyrError::DockerDaemonDown) => {}
            Err(ZephyrError::NoNvidiaRuntime) => {}
            Err(e) => panic!("unexpected error variant: {e}"),
        }
    }

    #[test]
    fn check_docker_daemon_returns_correct_error_type() {
        let result = check_docker_daemon();
        match result {
            Ok(()) => {}
            Err(ZephyrError::DockerDaemonDown) => {}
            Err(e) => panic!("expected DockerDaemonDown, got: {e}"),
        }
    }

    #[test]
    fn check_nvidia_runtime_returns_correct_error_type() {
        let result = check_nvidia_runtime();
        match result {
            Ok(()) => {}
            Err(ZephyrError::DockerDaemonDown) => {} // docker not running
            Err(ZephyrError::NoNvidiaRuntime) => {}  // docker running, no nvidia
            Err(e) => panic!("unexpected error variant: {e}"),
        }
    }
}
