use crate::config::ZephyrConfig;
use crate::paths::container_paths;

/// Build the set of environment variables to pass into the container.
pub(crate) fn build_env_args(
    config: &ZephyrConfig,
    sygaldry_root_in_container: &str,
) -> Vec<String> {
    let mut args = Vec::new();

    let env_vars: Vec<(&str, String)> = vec![
        ("SYGALDRY_IN_CONTAINER", "1".into()),
        ("SYGALDRY_ROOT", sygaldry_root_in_container.to_string()),
        ("SYGALDRY_PROJECT_ID", config.project_id.clone()),
        ("SYGALDRY_RUN_ID", config.run_id.clone()),
        (
            "ZEPHYR_LEASE_MODE",
            format!("{:?}", config.lease_mode).to_lowercase(),
        ),
        (
            "ZEPHYR_CACHE_PROFILE",
            format!("{:?}", config.cache_profile).to_lowercase(),
        ),
        ("USER", container_paths::USER.into()),
        ("HOME", container_paths::HOME.into()),
        ("XDG_CONFIG_HOME", container_paths::CONFIG_HOME.into()),
        ("XDG_DATA_HOME", container_paths::LOCAL_SHARE.into()),
        ("XDG_CACHE_HOME", container_paths::UV_CACHE.into()),
        ("HF_HOME", container_paths::HF_CACHE.into()),
        ("UV_CACHE_DIR", container_paths::UV_CACHE.into()),
        ("TORCH_HOME", container_paths::TORCH_CACHE.into()),
        ("TRITON_CACHE_DIR", container_paths::TRITON_CACHE.into()),
        ("CUDA_CACHE_PATH", container_paths::NV_COMPUTE_CACHE.into()),
        (
            "JAX_COMPILATION_CACHE_DIR",
            container_paths::JAX_CACHE.into(),
        ),
    ];

    for (key, val) in &env_vars {
        args.push(format!("--env={key}={val}"));
    }

    let passthru = [
        "TERM",
        "LANG",
        "LC_ALL",
        "BAZEL_VERSION",
        "ZEPHYR_DEV_SUDO",
        "SYGALDRY_BUILD_ROLE",
        "SYGALDRY_SPACK_ENV",
        "SYGALDRY_MLSYS_ENV",
        "SYGALDRY_MLSYS_VENV_ROOT",
        "SYGALDRY_MLSYS_TARGET",
    ];
    for var in &passthru {
        if let Ok(val) = std::env::var(var) {
            if !val.is_empty() {
                args.push(format!("--env={var}={val}"));
            }
        }
    }

    args
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::*;
    use crate::paths::HostLayout;

    fn test_config_in(root: &std::path::Path) -> ZephyrConfig {
        let layout = HostLayout {
            cache_root: root.join("cache"),
            shared_root: root.join("shared"),
            build_root: root.join("build"),
            projects_root: root.join("projects"),
            project_root: root.join("project"),
            meta_root: root.join("meta"),
            home: root.join("project/home"),
            config: root.join("project/config"),
            local_share: root.join("project/local_share"),
            outputs: root.join("project/outputs"),
            workspace: root.join("project/workspace"),
            runs: root.join("project/runs"),
            leases: root.join("project/leases"),
            logs: root.join("project/logs"),
            spack_store: root.join("shared/spack_store"),
            bazel_cache: root.join("shared/bazel_cache"),
            hf_cache: root.join("shared/hf_cache"),
            uv_cache: root.join("shared/uv_cache"),
            torch_cache: root.join("shared/torch_cache"),
            triton_cache: root.join("shared/triton_cache"),
            nv_compute_cache: root.join("shared/nv_compute_cache"),
            jax_cache: root.join("shared/jax_cache"),
        };

        ZephyrConfig {
            project_id: "test-proj".into(),
            run_id: "run-001".into(),
            sygaldry_home: root.join("sygaldry"),
            image: "sygaldry/zephyr:test".into(),
            net: "bridge".into(),
            ipc: "shareable".into(),
            shm_size: "16g".into(),
            memory_limit: None,
            cpu_limit: None,
            memory_swap: None,
            pids_limit: "4096".into(),
            build_policy: BuildPolicy::Never,
            rootless_override: None,
            extra_docker_args: vec![],
            required_cuda: "12.9".into(),
            lease_mode: LeaseMode::Warn,
            cache_profile: CacheProfile::Shared,
            launch_mode: LaunchMode::Legacy,
            python_version: "3.13".into(),
            rust_version: "1.79.0".into(),
            go_version: "1.21.5".into(),
            bazel_version: "6.4.0".into(),
            layout,
        }
    }

    #[test]
    fn env_args_contain_required_vars() {
        let tmp = tempfile::tempdir().unwrap();
        let config = test_config_in(tmp.path());
        let env_args = build_env_args(&config, "/workspace");

        let has = |key: &str| {
            env_args
                .iter()
                .any(|a| a.starts_with(&format!("--env={key}=")))
        };

        assert!(
            has("SYGALDRY_IN_CONTAINER"),
            "missing SYGALDRY_IN_CONTAINER"
        );
        assert!(has("SYGALDRY_ROOT"), "missing SYGALDRY_ROOT");
        assert!(has("SYGALDRY_PROJECT_ID"), "missing SYGALDRY_PROJECT_ID");
        assert!(has("SYGALDRY_RUN_ID"), "missing SYGALDRY_RUN_ID");
        assert!(has("ZEPHYR_LEASE_MODE"), "missing ZEPHYR_LEASE_MODE");
        assert!(has("ZEPHYR_CACHE_PROFILE"), "missing ZEPHYR_CACHE_PROFILE");
        assert!(has("USER"), "missing USER");
        assert!(has("HOME"), "missing HOME");
        assert!(has("HF_HOME"), "missing HF_HOME");
        assert!(has("UV_CACHE_DIR"), "missing UV_CACHE_DIR");
        assert!(has("TORCH_HOME"), "missing TORCH_HOME");
    }

    #[test]
    fn env_args_set_container_flag() {
        let tmp = tempfile::tempdir().unwrap();
        let config = test_config_in(tmp.path());
        let env_args = build_env_args(&config, "/workspace");
        assert!(env_args.contains(&"--env=SYGALDRY_IN_CONTAINER=1".to_string()));
    }

    #[test]
    fn env_args_passthrough_dev_sudo() {
        let tmp = tempfile::tempdir().unwrap();
        let config = test_config_in(tmp.path());
        std::env::set_var("ZEPHYR_DEV_SUDO", "1");
        let env_args = build_env_args(&config, "/workspace");
        std::env::remove_var("ZEPHYR_DEV_SUDO");
        assert!(env_args.contains(&"--env=ZEPHYR_DEV_SUDO=1".to_string()));
    }

    #[test]
    fn env_args_project_id_matches_config() {
        let tmp = tempfile::tempdir().unwrap();
        let config = test_config_in(tmp.path());
        let env_args = build_env_args(&config, "/workspace");
        assert!(env_args.contains(&"--env=SYGALDRY_PROJECT_ID=test-proj".to_string()));
    }

    #[test]
    fn env_args_lease_mode_lowercase() {
        let tmp = tempfile::tempdir().unwrap();
        let config = test_config_in(tmp.path());
        let env_args = build_env_args(&config, "/workspace");
        assert!(env_args.contains(&"--env=ZEPHYR_LEASE_MODE=warn".to_string()));
    }
}
