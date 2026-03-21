use crate::config::{LaunchMode, ZephyrConfig};
use crate::paths::{container_paths, resolve_mount_path};
use std::path::PathBuf;

/// A volume mount specification.
#[derive(Debug, Clone)]
pub(crate) struct Mount {
    pub host: PathBuf,
    pub container: String,
    pub readonly: bool,
}

impl Mount {
    pub fn to_arg(&self) -> String {
        let ro = if self.readonly { ":ro" } else { "" };
        format!("--volume={}:{}{}", self.host.display(), self.container, ro)
    }
}

/// Resolve the entrypoint path inside the container.
pub(crate) fn resolve_entrypoint_path(
    entrypoint_name: &str,
    entrypoint_container_dir: Option<&str>,
    launch_mode: &LaunchMode,
) -> String {
    if let Some(dir) = entrypoint_container_dir {
        format!("{dir}/{entrypoint_name}.sh")
    } else {
        match launch_mode {
            LaunchMode::MultiRepo { .. } => {
                format!(
                    "{}/container/entrypoints/{entrypoint_name}.sh",
                    container_paths::SYGALDRY
                )
            }
            LaunchMode::Legacy => {
                format!(
                    "{}/container/entrypoints/{entrypoint_name}.sh",
                    container_paths::WORKSPACE
                )
            }
        }
    }
}

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

/// Resolve a host path and push its mount arg. Reduces boilerplate.
fn push_mount(
    args: &mut Vec<String>,
    host_path: &std::path::Path,
    container_path: &str,
    readonly: bool,
) -> crate::error::Result<()> {
    let resolved = resolve_mount_path(host_path)?;
    args.push(
        Mount {
            host: resolved,
            container: container_path.into(),
            readonly,
        }
        .to_arg(),
    );
    Ok(())
}

/// Build per-project and shared cache volume mounts.
fn build_volume_mounts(
    args: &mut Vec<String>,
    config: &ZephyrConfig,
    spack_baked: bool,
) -> crate::error::Result<()> {
    // Per-project directories
    push_mount(args, &config.layout.home, container_paths::HOME, false)?;
    push_mount(
        args,
        &config.layout.config,
        container_paths::CONFIG_HOME,
        false,
    )?;
    push_mount(
        args,
        &config.layout.local_share,
        container_paths::LOCAL_SHARE,
        false,
    )?;
    push_mount(
        args,
        &config.layout.outputs,
        container_paths::OUTPUT_ROOT,
        false,
    )?;

    // Shared caches
    push_mount(
        args,
        &config.layout.bazel_cache,
        container_paths::BAZEL_CACHE,
        false,
    )?;
    push_mount(
        args,
        &config.layout.hf_cache,
        container_paths::HF_CACHE,
        false,
    )?;
    push_mount(
        args,
        &config.layout.uv_cache,
        container_paths::UV_CACHE,
        false,
    )?;
    push_mount(
        args,
        &config.layout.torch_cache,
        container_paths::TORCH_CACHE,
        false,
    )?;
    push_mount(
        args,
        &config.layout.triton_cache,
        container_paths::TRITON_CACHE,
        false,
    )?;
    push_mount(
        args,
        &config.layout.nv_compute_cache,
        container_paths::NV_COMPUTE_CACHE,
        false,
    )?;
    push_mount(
        args,
        &config.layout.jax_cache,
        container_paths::JAX_CACHE,
        false,
    )?;

    // Spack store (skip if baked into image)
    if !spack_baked {
        push_mount(
            args,
            &config.layout.spack_store,
            container_paths::SPACK_STORE,
            false,
        )?;
    }

    // Compatibility overlay for lib helpers
    let lib_dir = config.sygaldry_home.join("container/lib");
    if lib_dir.is_dir() {
        let resolved_lib = resolve_mount_path(&lib_dir)?;
        args.push(
            Mount {
                host: resolved_lib.clone(),
                container: "/opt/lib".into(),
                readonly: true,
            }
            .to_arg(),
        );
        args.push(
            Mount {
                host: resolved_lib,
                container: "/opt/spack_env/lib".into(),
                readonly: true,
            }
            .to_arg(),
        );
    }

    Ok(())
}

/// Build mode-specific mounts and workdir. Returns the sygaldry root path inside the container.
fn build_mode_mounts(
    args: &mut Vec<String>,
    config: &ZephyrConfig,
    entrypoint_container_dir: Option<&str>,
) -> crate::error::Result<String> {
    match &config.launch_mode {
        LaunchMode::MultiRepo { repo_path } => {
            let repo_path = std::fs::canonicalize(repo_path)?;
            let repo_name = repo_path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "repo".to_string());

            if entrypoint_container_dir.is_none() {
                push_mount(args, &config.sygaldry_home, container_paths::SYGALDRY, true)?;
            }

            push_mount(
                args,
                &config.layout.workspace,
                container_paths::WORKSPACE,
                false,
            )?;
            args.push(
                Mount {
                    host: repo_path,
                    container: format!("{}/{repo_name}", container_paths::WORKSPACE),
                    readonly: false,
                }
                .to_arg(),
            );

            let workdir = format!("{}/{repo_name}", container_paths::WORKSPACE);
            args.push(format!("--workdir={workdir}"));
            Ok(workdir)
        }
        LaunchMode::Legacy => {
            let project_source = std::env::var("SYGALDRY_WORKSPACE_SOURCE")
                .map(PathBuf::from)
                .unwrap_or_else(|_| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
            push_mount(args, &project_source, container_paths::WORKSPACE, false)?;
            args.push(format!("--workdir={}", container_paths::WORKSPACE));
            Ok(container_paths::WORKSPACE.to_string())
        }
    }
}

/// Build the complete `docker run` argument list.
///
/// This is the most complex function in the codebase, directly replacing
/// `build_docker_args()` from `launch_container.sh`.
pub fn build(
    config: &ZephyrConfig,
    entrypoint_name: &str,
    spack_baked: bool,
    entrypoint_container_dir: Option<&str>,
) -> crate::error::Result<Vec<String>> {
    let mut args: Vec<String> = Vec::with_capacity(64);

    // Basic flags
    args.extend(["--rm".into(), "--init".into()]);

    // Interactive if stdin is a TTY
    if atty_stdin() {
        args.extend(["--interactive".into(), "--tty".into()]);
    }

    // Network and IPC
    args.push(format!("--network={}", config.net));
    args.push(format!("--ipc={}", config.ipc));
    args.push(format!("--shm-size={}", config.shm_size));
    if let Some(memory_limit) = &config.memory_limit {
        args.push(format!("--memory={memory_limit}"));
    }
    if let Some(cpu_limit) = &config.cpu_limit {
        args.push(format!("--cpus={cpu_limit}"));
    }
    if let Some(memory_swap) = &config.memory_swap {
        args.push(format!("--memory-swap={memory_swap}"));
    }
    args.push(format!("--pids-limit={}", config.pids_limit));

    // User mapping
    let user_spec = detect_user_spec(config.rootless_override);
    args.push(format!("--user={user_spec}"));

    // Host identity mount (optional)
    if std::env::var("SYGALDRY_MOUNT_HOST_IDENTITY").as_deref() == Ok("1") {
        args.push("--volume=/etc/passwd:/etc/passwd:ro".into());
        args.push("--volume=/etc/group:/etc/group:ro".into());
    }

    // Volume mounts (per-project + shared caches)
    build_volume_mounts(&mut args, config, spack_baked)?;

    // Mode-specific mounts and workdir
    let sygaldry_root_in_container =
        build_mode_mounts(&mut args, config, entrypoint_container_dir)?;

    // Resolve entrypoint path
    let entrypoint_path = resolve_entrypoint_path(
        entrypoint_name,
        entrypoint_container_dir,
        &config.launch_mode,
    );
    args.push(format!("--entrypoint={entrypoint_path}"));

    // GPU flags
    args.extend(["--runtime=nvidia".into(), "--gpus=all".into()]);

    // Environment variables
    args.extend(build_env_args(config, &sygaldry_root_in_container));

    // Extra docker args from env
    args.extend(config.extra_docker_args.iter().cloned());

    Ok(args)
}

/// Detect user spec for --user flag.
fn detect_user_spec(rootless_override: Option<bool>) -> String {
    // SAFETY: getuid(2) and getgid(2) have no preconditions, dereference no
    // pointers, and are safe to call from any process context.
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };

    let is_rootless = rootless_override.unwrap_or_else(|| {
        std::process::Command::new("docker")
            .args(["info"])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("rootless"))
            .unwrap_or(false)
    });

    if is_rootless {
        "0:0".to_string()
    } else {
        format!("{uid}:{gid}")
    }
}

/// Check if stdin is a terminal (for -it flags).
fn atty_stdin() -> bool {
    // SAFETY: isatty(3) only inspects the file descriptor number and has no
    // aliasing or lifetime requirements. File descriptor 0 is always valid to
    // query even when it is not attached to a terminal.
    unsafe { libc::isatty(0) != 0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::*;
    use crate::paths::HostLayout;

    // -- Mount tests --

    #[test]
    fn mount_rw_format() {
        let m = Mount {
            host: PathBuf::from("/host/data"),
            container: "/container/data".into(),
            readonly: false,
        };
        assert_eq!(m.to_arg(), "--volume=/host/data:/container/data");
    }

    #[test]
    fn mount_ro_format() {
        let m = Mount {
            host: PathBuf::from("/host/lib"),
            container: "/opt/lib".into(),
            readonly: true,
        };
        assert_eq!(m.to_arg(), "--volume=/host/lib:/opt/lib:ro");
    }

    #[test]
    fn mount_with_spaces_in_path() {
        let m = Mount {
            host: PathBuf::from("/host/my data"),
            container: "/container/data".into(),
            readonly: false,
        };
        assert!(m.to_arg().contains("/host/my data"));
    }

    // -- resolve_entrypoint_path tests --

    #[test]
    fn entrypoint_path_legacy_default() {
        let path = resolve_entrypoint_path("default", None, &LaunchMode::Legacy);
        assert_eq!(
            path,
            format!(
                "{}/container/entrypoints/default.sh",
                container_paths::WORKSPACE
            )
        );
    }

    #[test]
    fn entrypoint_path_legacy_custom_name() {
        let path = resolve_entrypoint_path("run-job", None, &LaunchMode::Legacy);
        assert!(path.contains("run-job.sh"));
        assert!(path.starts_with(container_paths::WORKSPACE));
    }

    #[test]
    fn entrypoint_path_multirepo_default() {
        let mode = LaunchMode::MultiRepo {
            repo_path: PathBuf::from("/tmp/repo"),
        };
        let path = resolve_entrypoint_path("default", None, &mode);
        assert!(path.starts_with(container_paths::SYGALDRY));
        assert!(path.ends_with("default.sh"));
    }

    #[test]
    fn entrypoint_path_custom_dir() {
        let path = resolve_entrypoint_path("verify-gpu", Some("/opt/custom"), &LaunchMode::Legacy);
        assert_eq!(path, "/opt/custom/verify-gpu.sh");
    }

    #[test]
    fn entrypoint_path_custom_dir_multirepo() {
        let mode = LaunchMode::MultiRepo {
            repo_path: PathBuf::from("/tmp/repo"),
        };
        let path = resolve_entrypoint_path("run-job", Some("/baked"), &mode);
        assert_eq!(path, "/baked/run-job.sh");
    }

    // -- build_env_args tests --

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

    #[test]
    fn detect_user_spec_honors_rootless_override_true() {
        assert_eq!(detect_user_spec(Some(true)), "0:0");
    }

    #[test]
    fn detect_user_spec_honors_rootless_override_false() {
        // SAFETY: getuid(2) and getgid(2) have no preconditions and only return
        // the current process identity.
        let expected = format!("{}:{}", unsafe { libc::getuid() }, unsafe {
            libc::getgid()
        });
        assert_eq!(detect_user_spec(Some(false)), expected);
    }

    // -- full build() tests --

    #[test]
    fn build_legacy_contains_basic_flags() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        std::env::remove_var("SYGALDRY_MOUNT_HOST_IDENTITY");
        let args = build(&config, "default", false, None).unwrap();

        assert!(args.contains(&"--rm".to_string()));
        assert!(args.contains(&"--init".to_string()));
        assert!(args.contains(&"--network=bridge".to_string()));
        assert!(args.contains(&"--ipc=shareable".to_string()));
        assert!(args.contains(&"--shm-size=16g".to_string()));
        assert!(args.contains(&"--pids-limit=4096".to_string()));
        assert!(args.contains(&"--runtime=nvidia".to_string()));
        assert!(args.contains(&"--gpus=all".to_string()));
    }

    #[test]
    fn build_includes_optional_resource_limits() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        config.memory_limit = Some("64g".into());
        config.cpu_limit = Some("8".into());
        config.memory_swap = Some("80g".into());
        config.pids_limit = "2048".into();
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let args = build(&config, "default", false, None).unwrap();

        assert!(args.contains(&"--memory=64g".to_string()));
        assert!(args.contains(&"--cpus=8".to_string()));
        assert!(args.contains(&"--memory-swap=80g".to_string()));
        assert!(args.contains(&"--pids-limit=2048".to_string()));
    }

    #[test]
    fn build_allows_host_network_override() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        config.net = "host".into();
        config.ipc = "host".into();
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let args = build(&config, "default", false, None).unwrap();

        assert!(args.contains(&"--network=host".to_string()));
        assert!(args.contains(&"--ipc=host".to_string()));
    }

    #[test]
    fn build_legacy_workdir_is_workspace() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let args = build(&config, "default", false, None).unwrap();
        assert!(args.contains(&format!("--workdir={}", container_paths::WORKSPACE)));
    }

    #[test]
    fn build_legacy_has_entrypoint() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let args = build(&config, "run-job", false, None).unwrap();
        let ep = args
            .iter()
            .find(|a| a.starts_with("--entrypoint="))
            .unwrap();
        assert!(ep.contains("run-job.sh"));
    }

    #[test]
    fn build_spack_baked_skips_spack_mount() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let args_baked = build(&config, "default", true, None).unwrap();
        let args_unbaked = build(&config, "default", false, None).unwrap();

        let has_spack_mount = |args: &[String]| {
            args.iter()
                .any(|a| a.contains(container_paths::SPACK_STORE))
        };

        assert!(
            !has_spack_mount(&args_baked),
            "baked should skip spack mount"
        );
        assert!(
            has_spack_mount(&args_unbaked),
            "unbaked should have spack mount"
        );
    }

    #[test]
    fn build_extra_docker_args_appended() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();
        config.extra_docker_args = vec!["--shm-size=8g".into(), "--ulimit".into()];

        let args = build(&config, "default", false, None).unwrap();
        assert!(args.contains(&"--shm-size=8g".to_string()));
        assert!(args.contains(&"--ulimit".to_string()));
    }

    #[test]
    fn build_multirepo_has_workdir_with_repo_name() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_dir = tmp.path().join("my-ml-project");
        std::fs::create_dir_all(&repo_dir).unwrap();

        let mut config = test_config_in(tmp.path());
        config.launch_mode = LaunchMode::MultiRepo {
            repo_path: repo_dir,
        };
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let args = build(&config, "default", false, None).unwrap();
        assert!(
            args.contains(&format!(
                "--workdir={}/my-ml-project",
                container_paths::WORKSPACE
            )),
            "multi-repo workdir should include repo name"
        );
    }

    #[test]
    fn build_user_flag_present() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let args = build(&config, "default", false, None).unwrap();
        assert!(
            args.iter().any(|a| a.starts_with("--user=")),
            "missing --user flag"
        );
    }

    #[test]
    fn build_volume_mounts_contain_home() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let args = build(&config, "default", false, None).unwrap();
        assert!(
            args.iter()
                .any(|a| a.contains(container_paths::HOME) && a.starts_with("--volume=")),
            "should mount HOME"
        );
    }
}
