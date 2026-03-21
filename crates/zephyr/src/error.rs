use std::path::PathBuf;

/// Unified error type for all Zephyr operations.
///
/// Each variant carries enough context for actionable error messages.
/// The `WithHint` variant supports remediation guidance.
#[derive(thiserror::Error, Debug)]
pub enum ZephyrError {
    #[error("Docker is not installed or not in PATH")]
    DockerUnavailable,

    #[error("Docker daemon is not running or not accessible")]
    DockerDaemonDown,

    #[error("NVIDIA Docker runtime not detected (GPU-only infrastructure)")]
    NoNvidiaRuntime,

    #[error("Host CUDA {host} < required {required}")]
    CudaVersionTooOld { host: String, required: String },

    #[error("Docker image '{image}' not found and build policy is 'never'")]
    ImageNotFound { image: String },

    #[error("Docker image build failed")]
    ImageBuildFailed(#[source] std::io::Error),

    #[error("Lease conflict on resource '{resource}' at {lease_file}")]
    LeaseConflict {
        resource: String,
        lease_file: PathBuf,
    },

    #[error("Entrypoint not found: {0}")]
    EntrypointNotFound(String),

    #[error("Spack environment activation failed")]
    SpackActivationFailed,

    #[error("GPU validation failed: {0}")]
    GpuValidationFailed(String),

    #[error("Command failed with exit code {code}: {command}")]
    CommandFailed { command: String, code: i32 },

    #[error("Job not found: project={project_id} job={job_name}")]
    JobNotFound {
        project_id: String,
        job_name: String,
    },

    #[error("{message}\nHINT: {hint}")]
    WithHint { message: String, hint: String },

    #[error("{context}: {source}")]
    PathIo {
        context: String,
        source: std::io::Error,
    },

    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, ZephyrError>;

impl ZephyrError {
    /// Wrap any error with a remediation hint.
    pub fn with_hint(message: impl Into<String>, hint: impl Into<String>) -> Self {
        Self::WithHint {
            message: message.into(),
            hint: hint.into(),
        }
    }

    /// Wrap an IO error with path context.
    pub fn path_io(path: impl AsRef<std::path::Path>, source: std::io::Error) -> Self {
        Self::PathIo {
            context: format!("{}", path.as_ref().display()),
            source,
        }
    }
}

/// Extension trait for adding path context to `std::io::Result`.
pub trait IoResultExt<T> {
    /// Add path context to an IO error.
    fn with_path(self, path: impl AsRef<std::path::Path>) -> Result<T>;
}

impl<T> IoResultExt<T> for std::io::Result<T> {
    fn with_path(self, path: impl AsRef<std::path::Path>) -> Result<T> {
        self.map_err(|e| ZephyrError::path_io(path, e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_hint_formats_correctly() {
        let err = ZephyrError::with_hint("something broke", "try fixing it");
        let msg = format!("{err}");
        assert!(msg.contains("something broke"));
        assert!(msg.contains("HINT: try fixing it"));
    }

    #[test]
    fn docker_unavailable_display() {
        let err = ZephyrError::DockerUnavailable;
        assert_eq!(format!("{err}"), "Docker is not installed or not in PATH");
    }

    #[test]
    fn cuda_version_too_old_display() {
        let err = ZephyrError::CudaVersionTooOld {
            host: "11.8".into(),
            required: "12.9".into(),
        };
        let msg = format!("{err}");
        assert!(msg.contains("11.8"));
        assert!(msg.contains("12.9"));
    }

    #[test]
    fn image_not_found_display() {
        let err = ZephyrError::ImageNotFound {
            image: "sygaldry/zephyr:base".into(),
        };
        let msg = format!("{err}");
        assert!(msg.contains("sygaldry/zephyr:base"));
        assert!(msg.contains("never"));
    }

    #[test]
    fn lease_conflict_display() {
        let err = ZephyrError::LeaseConflict {
            resource: "gpu-all".into(),
            lease_file: PathBuf::from("/tmp/leases/gpu-all.lease"),
        };
        let msg = format!("{err}");
        assert!(msg.contains("gpu-all"));
        assert!(msg.contains("/tmp/leases/gpu-all.lease"));
    }

    #[test]
    fn entrypoint_not_found_display() {
        let err = ZephyrError::EntrypointNotFound("nonexistent".into());
        assert!(format!("{err}").contains("nonexistent"));
    }

    #[test]
    fn command_failed_display() {
        let err = ZephyrError::CommandFailed {
            command: "uv pip install foo".into(),
            code: 127,
        };
        let msg = format!("{err}");
        assert!(msg.contains("127"));
        assert!(msg.contains("uv pip install foo"));
    }

    #[test]
    fn job_not_found_display() {
        let err = ZephyrError::JobNotFound {
            project_id: "proj-1".into(),
            job_name: "train".into(),
        };
        let msg = format!("{err}");
        assert!(msg.contains("proj-1"));
        assert!(msg.contains("train"));
    }

    #[test]
    fn io_error_transparent() {
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "file gone");
        let err: ZephyrError = io_err.into();
        assert!(format!("{err}").contains("file gone"));
    }

    #[test]
    fn path_io_includes_path_and_cause() {
        let io_err = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "access denied");
        let err = ZephyrError::path_io("/opt/spack_store/view", io_err);
        let msg = format!("{err}");
        assert!(msg.contains("/opt/spack_store/view"), "missing path in: {msg}");
        assert!(msg.contains("access denied"), "missing cause in: {msg}");
    }

    #[test]
    fn with_path_extension_trait() {
        let result: std::io::Result<()> = Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "no such file",
        ));
        let err = result.with_path("/tmp/missing.txt").unwrap_err();
        let msg = format!("{err}");
        assert!(msg.contains("/tmp/missing.txt"), "missing path in: {msg}");
        assert!(msg.contains("no such file"), "missing cause in: {msg}");
    }

    #[test]
    fn with_path_ok_passes_through() {
        let result: std::io::Result<i32> = Ok(42);
        assert_eq!(result.with_path("/tmp/foo").unwrap(), 42);
    }

    #[test]
    fn result_type_alias_works() {
        fn ok_fn() -> Result<i32> { Ok(42) }
        fn err_fn() -> Result<i32> { Err(ZephyrError::DockerUnavailable) }
        assert_eq!(ok_fn().unwrap(), 42);
        assert!(err_fn().is_err());
    }
}
