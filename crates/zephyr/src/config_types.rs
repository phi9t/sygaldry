use std::path::PathBuf;

/// Docker image build policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildPolicy {
    Auto,
    Always,
    Never,
}

impl BuildPolicy {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(Self::Auto),
            "always" => Some(Self::Always),
            "never" => Some(Self::Never),
            _ => None,
        }
    }
}

/// Lease conflict resolution mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeaseMode {
    Off,
    Warn,
    Enforce,
}

impl LeaseMode {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "off" => Some(Self::Off),
            "warn" => Some(Self::Warn),
            "enforce" => Some(Self::Enforce),
            _ => None,
        }
    }
}

/// Cache isolation profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CacheProfile {
    Shared,
    Isolated,
    Hybrid,
}

impl CacheProfile {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "shared" => Some(Self::Shared),
            "isolated" => Some(Self::Isolated),
            "hybrid" => Some(Self::Hybrid),
            _ => None,
        }
    }
}

/// Launch mode: legacy (sygaldry at /workspace) vs multi-repo.
#[derive(Debug, Clone)]
pub enum LaunchMode {
    Legacy,
    MultiRepo { repo_path: PathBuf },
}

pub(crate) struct SharedCaches {
    pub spack_store: PathBuf,
    pub bazel_cache: PathBuf,
    pub hf_cache: PathBuf,
    pub uv_cache: PathBuf,
    pub torch_cache: PathBuf,
    pub triton_cache: PathBuf,
    pub nv_compute_cache: PathBuf,
    pub jax_cache: PathBuf,
}
