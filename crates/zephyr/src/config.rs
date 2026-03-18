use crate::paths::{HostLayout, DEFAULT_CACHE_ROOT};
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

/// Complete Zephyr configuration.
///
/// Built from environment variables, CLI flags, and defaults.
/// Field comments document the env var source(s).
#[derive(Debug, Clone)]
pub struct ZephyrConfig {
    // Identity
    pub project_id: String,
    pub run_id: String,
    pub sygaldry_home: PathBuf,

    // Container image
    pub image: String,
    pub net: String,
    pub ipc: String,
    pub build_policy: BuildPolicy,
    pub extra_docker_args: Vec<String>,
    pub required_cuda: String,

    // Modes
    pub lease_mode: LeaseMode,
    pub cache_profile: CacheProfile,
    pub launch_mode: LaunchMode,

    // Toolchain versions
    pub python_version: String,
    pub rust_version: String,
    pub go_version: String,
    pub bazel_version: String,

    // Host layout
    pub layout: HostLayout,
}

/// Read an env var with a chain of fallbacks.
///
/// Returns the value of the first env var that is set and non-empty,
/// or the default if none are set.
fn env_chain(vars: &[&str], default: &str) -> String {
    for var in vars {
        if let Ok(val) = std::env::var(var) {
            if !val.is_empty() {
                return val;
            }
        }
    }
    default.to_string()
}

fn env_or(var: &str, default: &str) -> String {
    std::env::var(var).unwrap_or_else(|_| default.to_string())
}

/// Log a deprecation warning if a legacy env var is set.
fn warn_legacy(old: &str, new: &str) {
    if std::env::var(old).is_ok() {
        eprintln!(
            "[zephyr] DEPRECATED: {old} set; prefer {new}",
        );
    }
}

impl ZephyrConfig {
    /// Load configuration from environment variables and CLI overrides.
    ///
    /// `cli_overrides` allows CLI flags to take precedence over env vars.
    pub fn from_env(cli_overrides: &CliOverrides) -> Self {
        warn_legacy("SYGALDRY_SPACK_STORE", "ZEPHYR_SHARED_SPACK_STORE");
        warn_legacy("SYGALDRY_HF_CACHE", "ZEPHYR_SHARED_HF_CACHE");
        warn_legacy("SYGALDRY_UV_CACHE", "ZEPHYR_SHARED_UV_CACHE");

        let sygaldry_home = resolve_sygaldry_home();
        let (project_id, run_id) = resolve_identity(cli_overrides);
        let layout = build_host_layout(&project_id);
        let launch_mode = resolve_launch_mode(cli_overrides);
        let (lease_mode, cache_profile, build_policy) = resolve_modes(cli_overrides);

        let extra_docker_args: Vec<String> = env_or("SYGALDRY_EXTRA_DOCKER_ARGS", "")
            .split_whitespace()
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect();

        ZephyrConfig {
            project_id,
            run_id,
            sygaldry_home,
            image: env_or("SYGALDRY_IMAGE", "sygaldry/zephyr:base"),
            net: env_or("SYGALDRY_NET", "host"),
            ipc: env_or("SYGALDRY_IPC", "host"),
            build_policy,
            extra_docker_args,
            required_cuda: env_or("SYGALDRY_REQUIRED_CUDA_VERSION", "12.9"),
            lease_mode,
            cache_profile,
            launch_mode,
            // Keep in sync with container/launch_container.sh PYTHON_VERSION default.
            python_version: env_or("PYTHON_VERSION", "3.13"),
            rust_version: env_or("RUST_VERSION", "1.79.0"),
            go_version: env_or("GO_VERSION", "1.21.5"),
            bazel_version: env_or("BAZEL_VERSION", "6.4.0"),
            layout,
        }
    }

}

/// Detect the sygaldry repo root from SYGALDRY_HOME or binary location.
fn resolve_sygaldry_home() -> PathBuf {
    std::env::var("SYGALDRY_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|p| p.to_path_buf()))
                .and_then(|p| p.parent().map(|p| p.to_path_buf()))
                .and_then(|p| p.parent().map(|p| p.to_path_buf()))
                .unwrap_or_else(|| PathBuf::from("."))
        })
}

/// Resolve project ID and run ID from CLI overrides and env vars.
fn resolve_identity(cli_overrides: &CliOverrides) -> (String, String) {
    let project_id = cli_overrides
        .project_id
        .clone()
        .unwrap_or_else(|| {
            env_or(
                "SYGALDRY_PROJECT_ID",
                &std::env::current_dir()
                    .ok()
                    .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
                    .unwrap_or_else(|| "unknown".to_string()),
            )
        });

    let run_id = cli_overrides
        .run_id
        .clone()
        .unwrap_or_else(|| env_or("SYGALDRY_RUN_ID", ""));
    let run_id = if run_id.is_empty() {
        format!(
            "run-{}-{}",
            chrono::Local::now().format("%Y%m%d-%H%M%S"),
            std::process::id()
        )
    } else {
        run_id
    };

    (project_id, run_id)
}

/// Build the complete host directory layout from env vars.
fn build_host_layout(project_id: &str) -> HostLayout {
    let cache_root = PathBuf::from(env_or("ZEPHYR_CACHE_ROOT", DEFAULT_CACHE_ROOT));
    let shared_root =
        PathBuf::from(env_or("ZEPHYR_SHARED_ROOT", &cache_root.join("shared").display().to_string()));
    let build_root =
        PathBuf::from(env_or("ZEPHYR_BUILD_ROOT", &cache_root.join("sygaldry").display().to_string()));
    let projects_root =
        PathBuf::from(env_or("ZEPHYR_PROJECTS_ROOT", &cache_root.join("projects").display().to_string()));
    let project_root = PathBuf::from(env_or(
        "ZEPHYR_PROJECT_ROOT",
        &projects_root.join(project_id).display().to_string(),
    ));
    let meta_root = PathBuf::from(env_or("ZEPHYR_META_ROOT", &cache_root.join("meta").display().to_string()));

    let shared_caches = build_shared_caches(&build_root, &shared_root);

    HostLayout {
        cache_root,
        shared_root,
        build_root,
        projects_root,
        project_root: project_root.clone(),
        meta_root,
        home: project_root.join("home"),
        config: project_root.join("config"),
        local_share: project_root.join("local_share"),
        outputs: project_root.join("outputs"),
        workspace: project_root.join("workspace"),
        runs: project_root.join("runs"),
        leases: project_root.join("leases"),
        logs: project_root.join("logs"),
        spack_store: shared_caches.0,
        bazel_cache: shared_caches.1,
        hf_cache: shared_caches.2,
        uv_cache: shared_caches.3,
        torch_cache: shared_caches.4,
        triton_cache: shared_caches.5,
        nv_compute_cache: shared_caches.6,
        jax_cache: shared_caches.7,
    }
}

/// Resolve shared cache paths with legacy env var fallbacks.
fn build_shared_caches(
    build_root: &PathBuf,
    shared_root: &PathBuf,
) -> (PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf) {
    let spack_store = PathBuf::from(env_chain(
        &["ZEPHYR_SHARED_SPACK_STORE", "SYGALDRY_SPACK_STORE"],
        &build_root.join("spack_store").display().to_string(),
    ));
    let bazel_cache = PathBuf::from(env_chain(
        &["ZEPHYR_SHARED_BAZEL_CACHE", "SYGALDRY_BAZEL_CACHE"],
        &shared_root.join("bazel_cache").display().to_string(),
    ));
    let hf_cache = PathBuf::from(env_chain(
        &["ZEPHYR_SHARED_HF_CACHE", "SYGALDRY_HF_CACHE"],
        &shared_root.join("hf_cache").display().to_string(),
    ));
    let uv_cache = PathBuf::from(env_chain(
        &["ZEPHYR_SHARED_UV_CACHE", "SYGALDRY_UV_CACHE"],
        &shared_root.join("uv_cache").display().to_string(),
    ));
    let torch_cache = PathBuf::from(env_or(
        "ZEPHYR_SHARED_TORCH_CACHE",
        &shared_root.join("torch_cache").display().to_string(),
    ));
    let triton_cache = PathBuf::from(env_or(
        "ZEPHYR_SHARED_TRITON_CACHE",
        &shared_root.join("triton_cache").display().to_string(),
    ));
    let nv_compute_cache = PathBuf::from(env_or(
        "ZEPHYR_SHARED_NV_COMPUTE_CACHE",
        &shared_root.join("nv_compute_cache").display().to_string(),
    ));
    let jax_cache = PathBuf::from(env_or(
        "ZEPHYR_SHARED_JAX_CACHE",
        &shared_root.join("jax_cache").display().to_string(),
    ));

    (spack_store, bazel_cache, hf_cache, uv_cache, torch_cache, triton_cache, nv_compute_cache, jax_cache)
}

/// Resolve launch mode from CLI and env vars.
fn resolve_launch_mode(cli_overrides: &CliOverrides) -> LaunchMode {
    if let Some(ref repo) = cli_overrides.repo {
        LaunchMode::MultiRepo {
            repo_path: PathBuf::from(repo),
        }
    } else if let Ok(repo) = std::env::var("SYGALDRY_REPO") {
        if !repo.is_empty() {
            LaunchMode::MultiRepo {
                repo_path: PathBuf::from(repo),
            }
        } else {
            LaunchMode::Legacy
        }
    } else {
        LaunchMode::Legacy
    }
}

/// Resolve lease mode, cache profile, and build policy from CLI and env vars.
fn resolve_modes(cli_overrides: &CliOverrides) -> (LeaseMode, CacheProfile, BuildPolicy) {
    let lease_mode_default = env_or("ZEPHYR_LEASE_MODE", "warn");
    let lease_mode_str = cli_overrides
        .lease_mode
        .as_deref()
        .unwrap_or(&lease_mode_default);
    let lease_mode = LeaseMode::parse(lease_mode_str).unwrap_or(LeaseMode::Warn);

    let cache_profile_default = env_or("ZEPHYR_CACHE_PROFILE", "shared");
    let cache_profile_str = cli_overrides
        .cache_profile
        .as_deref()
        .unwrap_or(&cache_profile_default);
    let cache_profile = CacheProfile::parse(cache_profile_str).unwrap_or(CacheProfile::Shared);

    let build_policy_str = env_or("SYGALDRY_BUILD_IMAGE", "auto");
    let build_policy = BuildPolicy::parse(&build_policy_str).unwrap_or(BuildPolicy::Auto);

    (lease_mode, cache_profile, build_policy)
}

impl ZephyrConfig {
    /// Print the effective configuration to stderr (matches bash --print-effective-config).
    pub fn print_effective(&self) {
        let mode = match &self.launch_mode {
            LaunchMode::Legacy => "legacy",
            LaunchMode::MultiRepo { .. } => "multi-repo",
        };
        eprintln!("[zephyr] Effective config:");
        eprintln!("[zephyr]   Mode: {mode}");
        eprintln!("[zephyr]   Project ID: {}", self.project_id);
        eprintln!("[zephyr]   Run ID: {}", self.run_id);
        eprintln!("[zephyr]   Lease mode: {:?}", self.lease_mode);
        eprintln!("[zephyr]   Cache profile: {:?}", self.cache_profile);
        eprintln!("[zephyr]   Cache root: {}", self.layout.cache_root.display());
        eprintln!("[zephyr]   Shared root: {}", self.layout.shared_root.display());
        eprintln!("[zephyr]   Build root: {}", self.layout.build_root.display());
        eprintln!("[zephyr]   Project root: {}", self.layout.project_root.display());
        eprintln!(
            "[zephyr]   Shared caches: hf={} uv={} bazel={}",
            self.layout.hf_cache.display(),
            self.layout.uv_cache.display(),
            self.layout.bazel_cache.display()
        );
        eprintln!(
            "[zephyr]   Spack store: host={} -> container={}",
            self.layout.spack_store.display(),
            crate::paths::container_paths::SPACK_STORE
        );
    }
}

/// CLI flags that override env vars.
#[derive(Debug, Default)]
pub struct CliOverrides {
    pub project_id: Option<String>,
    pub run_id: Option<String>,
    pub repo: Option<String>,
    pub lease_mode: Option<String>,
    pub cache_profile: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    const CONFIG_ENV_VARS: &[&str] = &[
        "SYGALDRY_HOME", "SYGALDRY_PROJECT_ID", "SYGALDRY_RUN_ID",
        "SYGALDRY_IMAGE", "SYGALDRY_NET", "SYGALDRY_IPC",
        "SYGALDRY_BUILD_IMAGE", "SYGALDRY_EXTRA_DOCKER_ARGS",
        "SYGALDRY_REQUIRED_CUDA_VERSION", "SYGALDRY_REPO",
        "SYGALDRY_SPACK_STORE", "SYGALDRY_HF_CACHE", "SYGALDRY_UV_CACHE",
        "SYGALDRY_BAZEL_CACHE",
        "ZEPHYR_CACHE_ROOT", "ZEPHYR_SHARED_ROOT", "ZEPHYR_BUILD_ROOT",
        "ZEPHYR_PROJECTS_ROOT", "ZEPHYR_PROJECT_ROOT", "ZEPHYR_META_ROOT",
        "ZEPHYR_SHARED_SPACK_STORE", "ZEPHYR_SHARED_HF_CACHE",
        "ZEPHYR_SHARED_UV_CACHE", "ZEPHYR_SHARED_BAZEL_CACHE",
        "ZEPHYR_SHARED_TORCH_CACHE", "ZEPHYR_SHARED_TRITON_CACHE",
        "ZEPHYR_SHARED_NV_COMPUTE_CACHE", "ZEPHYR_SHARED_JAX_CACHE",
        "ZEPHYR_LEASE_MODE", "ZEPHYR_CACHE_PROFILE",
        "PYTHON_VERSION", "RUST_VERSION", "GO_VERSION", "BAZEL_VERSION",
    ];

    fn clear_config_env() {
        for var in CONFIG_ENV_VARS {
            std::env::remove_var(var);
        }
    }

    // -- enum parse tests --

    #[test]
    fn build_policy_parse_valid() {
        assert_eq!(BuildPolicy::parse("auto"), Some(BuildPolicy::Auto));
        assert_eq!(BuildPolicy::parse("always"), Some(BuildPolicy::Always));
        assert_eq!(BuildPolicy::parse("never"), Some(BuildPolicy::Never));
    }

    #[test]
    fn build_policy_parse_invalid() {
        assert_eq!(BuildPolicy::parse("bogus"), None);
        assert_eq!(BuildPolicy::parse(""), None);
        assert_eq!(BuildPolicy::parse("Auto"), None); // case sensitive
    }

    #[test]
    fn lease_mode_parse_valid() {
        assert_eq!(LeaseMode::parse("off"), Some(LeaseMode::Off));
        assert_eq!(LeaseMode::parse("warn"), Some(LeaseMode::Warn));
        assert_eq!(LeaseMode::parse("enforce"), Some(LeaseMode::Enforce));
    }

    #[test]
    fn lease_mode_parse_invalid() {
        assert_eq!(LeaseMode::parse("bogus"), None);
        assert_eq!(LeaseMode::parse("OFF"), None);
    }

    #[test]
    fn cache_profile_parse_valid() {
        assert_eq!(CacheProfile::parse("shared"), Some(CacheProfile::Shared));
        assert_eq!(CacheProfile::parse("isolated"), Some(CacheProfile::Isolated));
        assert_eq!(CacheProfile::parse("hybrid"), Some(CacheProfile::Hybrid));
    }

    #[test]
    fn cache_profile_parse_invalid() {
        assert_eq!(CacheProfile::parse("bogus"), None);
        assert_eq!(CacheProfile::parse("SHARED"), None);
    }

    // -- env_chain / env_or tests --

    #[test]
    fn env_chain_returns_default_when_unset() {
        let val = env_chain(&["__ZEPHYR_TEST_NONEXISTENT__"], "fallback");
        assert_eq!(val, "fallback");
    }

    #[test]
    fn env_chain_returns_first_set_var() {
        std::env::set_var("__ZEPHYR_TEST_CHAIN_A__", "alpha");
        std::env::set_var("__ZEPHYR_TEST_CHAIN_B__", "beta");
        let val = env_chain(
            &["__ZEPHYR_TEST_CHAIN_A__", "__ZEPHYR_TEST_CHAIN_B__"],
            "default",
        );
        assert_eq!(val, "alpha");
        std::env::remove_var("__ZEPHYR_TEST_CHAIN_A__");
        std::env::remove_var("__ZEPHYR_TEST_CHAIN_B__");
    }

    #[test]
    fn env_chain_skips_empty_vars() {
        std::env::set_var("__ZEPHYR_TEST_EMPTY__", "");
        std::env::set_var("__ZEPHYR_TEST_FULL__", "value");
        let val = env_chain(
            &["__ZEPHYR_TEST_EMPTY__", "__ZEPHYR_TEST_FULL__"],
            "default",
        );
        assert_eq!(val, "value");
        std::env::remove_var("__ZEPHYR_TEST_EMPTY__");
        std::env::remove_var("__ZEPHYR_TEST_FULL__");
    }

    #[test]
    fn env_or_returns_default_when_unset() {
        let val = env_or("__ZEPHYR_NONEXISTENT__", "fallback");
        assert_eq!(val, "fallback");
    }

    #[test]
    fn env_or_returns_value_when_set() {
        std::env::set_var("__ZEPHYR_TEST_OR__", "hello");
        let val = env_or("__ZEPHYR_TEST_OR__", "fallback");
        assert_eq!(val, "hello");
        std::env::remove_var("__ZEPHYR_TEST_OR__");
    }

    // -- ZephyrConfig::from_env tests --
    // These must be serialized: they mutate shared process env vars.

    #[test]
    #[serial]
    fn config_defaults_with_no_env() {
        clear_config_env();
        let overrides = CliOverrides::default();
        let config = ZephyrConfig::from_env(&overrides);

        assert_eq!(config.image, "sygaldry/zephyr:base");
        assert_eq!(config.net, "host");
        assert_eq!(config.ipc, "host");
        assert_eq!(config.build_policy, BuildPolicy::Auto);
        assert_eq!(config.required_cuda, "12.9");
        assert_eq!(config.lease_mode, LeaseMode::Warn);
        assert_eq!(config.cache_profile, CacheProfile::Shared);
        assert_eq!(config.python_version, "3.13");
        assert_eq!(config.rust_version, "1.79.0");
        assert_eq!(config.go_version, "1.21.5");
        assert_eq!(config.bazel_version, "6.4.0");
        assert!(config.extra_docker_args.is_empty());
        assert!(config.run_id.starts_with("run-"));
        assert!(matches!(config.launch_mode, LaunchMode::Legacy));
    }

    #[test]
    #[serial]
    fn config_picks_up_project_id_from_env() {
        clear_config_env();
        std::env::set_var("SYGALDRY_PROJECT_ID", "test-project");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.project_id, "test-project");
        std::env::remove_var("SYGALDRY_PROJECT_ID");
    }

    #[test]
    #[serial]
    fn config_cli_override_wins_over_env() {
        clear_config_env();
        std::env::set_var("SYGALDRY_PROJECT_ID", "from-env");
        let overrides = CliOverrides {
            project_id: Some("from-cli".to_string()),
            ..Default::default()
        };
        let config = ZephyrConfig::from_env(&overrides);
        assert_eq!(config.project_id, "from-cli");
        std::env::remove_var("SYGALDRY_PROJECT_ID");
    }

    #[test]
    #[serial]
    fn config_explicit_run_id() {
        clear_config_env();
        let overrides = CliOverrides {
            run_id: Some("my-run-42".to_string()),
            ..Default::default()
        };
        let config = ZephyrConfig::from_env(&overrides);
        assert_eq!(config.run_id, "my-run-42");
    }

    #[test]
    #[serial]
    fn config_multi_repo_from_cli() {
        clear_config_env();
        let overrides = CliOverrides {
            repo: Some("/tmp/my-repo".to_string()),
            ..Default::default()
        };
        let config = ZephyrConfig::from_env(&overrides);
        match &config.launch_mode {
            LaunchMode::MultiRepo { repo_path } => {
                assert_eq!(repo_path.display().to_string(), "/tmp/my-repo");
            }
            LaunchMode::Legacy => panic!("expected MultiRepo mode"),
        }
    }

    #[test]
    #[serial]
    fn config_multi_repo_from_env() {
        clear_config_env();
        std::env::set_var("SYGALDRY_REPO", "/tmp/env-repo");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        match &config.launch_mode {
            LaunchMode::MultiRepo { repo_path } => {
                assert_eq!(repo_path.display().to_string(), "/tmp/env-repo");
            }
            LaunchMode::Legacy => panic!("expected MultiRepo mode"),
        }
        std::env::remove_var("SYGALDRY_REPO");
    }

    #[test]
    #[serial]
    fn config_empty_repo_env_stays_legacy() {
        clear_config_env();
        std::env::set_var("SYGALDRY_REPO", "");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert!(matches!(config.launch_mode, LaunchMode::Legacy));
        std::env::remove_var("SYGALDRY_REPO");
    }

    #[test]
    #[serial]
    fn config_lease_mode_from_cli_override() {
        clear_config_env();
        let overrides = CliOverrides {
            lease_mode: Some("enforce".to_string()),
            ..Default::default()
        };
        let config = ZephyrConfig::from_env(&overrides);
        assert_eq!(config.lease_mode, LeaseMode::Enforce);
    }

    #[test]
    #[serial]
    fn config_cache_profile_from_cli_override() {
        clear_config_env();
        let overrides = CliOverrides {
            cache_profile: Some("isolated".to_string()),
            ..Default::default()
        };
        let config = ZephyrConfig::from_env(&overrides);
        assert_eq!(config.cache_profile, CacheProfile::Isolated);
    }

    #[test]
    #[serial]
    fn config_custom_image() {
        clear_config_env();
        std::env::set_var("SYGALDRY_IMAGE", "my-registry/custom:v2");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.image, "my-registry/custom:v2");
        std::env::remove_var("SYGALDRY_IMAGE");
    }

    #[test]
    #[serial]
    fn config_extra_docker_args_splits_whitespace() {
        clear_config_env();
        std::env::set_var("SYGALDRY_EXTRA_DOCKER_ARGS", "--shm-size=8g --ulimit memlock=-1");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.extra_docker_args, vec!["--shm-size=8g", "--ulimit", "memlock=-1"]);
        std::env::remove_var("SYGALDRY_EXTRA_DOCKER_ARGS");
    }

    #[test]
    #[serial]
    fn config_cache_root_propagates_to_layout() {
        clear_config_env();
        std::env::set_var("ZEPHYR_CACHE_ROOT", "/tmp/test-cache");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.layout.cache_root, PathBuf::from("/tmp/test-cache"));
        assert_eq!(config.layout.shared_root, PathBuf::from("/tmp/test-cache/shared"));
        assert_eq!(config.layout.build_root, PathBuf::from("/tmp/test-cache/sygaldry"));
        assert_eq!(config.layout.meta_root, PathBuf::from("/tmp/test-cache/meta"));
        std::env::remove_var("ZEPHYR_CACHE_ROOT");
    }

    #[test]
    #[serial]
    fn config_legacy_spack_store_fallback() {
        clear_config_env();
        std::env::set_var("SYGALDRY_SPACK_STORE", "/legacy/spack");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.layout.spack_store, PathBuf::from("/legacy/spack"));
        std::env::remove_var("SYGALDRY_SPACK_STORE");
    }

    #[test]
    #[serial]
    fn config_new_env_wins_over_legacy() {
        clear_config_env();
        std::env::set_var("SYGALDRY_SPACK_STORE", "/legacy/spack");
        std::env::set_var("ZEPHYR_SHARED_SPACK_STORE", "/new/spack");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.layout.spack_store, PathBuf::from("/new/spack"));
        std::env::remove_var("SYGALDRY_SPACK_STORE");
        std::env::remove_var("ZEPHYR_SHARED_SPACK_STORE");
    }

    #[test]
    #[serial]
    fn config_per_project_dirs_derived_from_project_root() {
        clear_config_env();
        std::env::set_var("ZEPHYR_PROJECT_ROOT", "/tmp/proj");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.layout.home, PathBuf::from("/tmp/proj/home"));
        assert_eq!(config.layout.config, PathBuf::from("/tmp/proj/config"));
        assert_eq!(config.layout.outputs, PathBuf::from("/tmp/proj/outputs"));
        assert_eq!(config.layout.workspace, PathBuf::from("/tmp/proj/workspace"));
        assert_eq!(config.layout.runs, PathBuf::from("/tmp/proj/runs"));
        assert_eq!(config.layout.leases, PathBuf::from("/tmp/proj/leases"));
        assert_eq!(config.layout.logs, PathBuf::from("/tmp/proj/logs"));
        std::env::remove_var("ZEPHYR_PROJECT_ROOT");
    }

    #[test]
    #[serial]
    fn config_build_policy_from_env() {
        clear_config_env();
        std::env::set_var("SYGALDRY_BUILD_IMAGE", "never");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.build_policy, BuildPolicy::Never);
        std::env::remove_var("SYGALDRY_BUILD_IMAGE");
    }

    #[test]
    #[serial]
    fn config_invalid_build_policy_defaults_to_auto() {
        clear_config_env();
        std::env::set_var("SYGALDRY_BUILD_IMAGE", "invalid_value");
        let config = ZephyrConfig::from_env(&CliOverrides::default());
        assert_eq!(config.build_policy, BuildPolicy::Auto);
        std::env::remove_var("SYGALDRY_BUILD_IMAGE");
    }
}
