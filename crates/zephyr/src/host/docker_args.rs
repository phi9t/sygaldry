use crate::config::ZephyrConfig;
use super::docker_env::build_env_args;
use super::docker_mounts::{build_mode_mounts, build_volume_mounts, resolve_entrypoint_path};

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
    let user_spec = if dev_sudo_enabled() {
        "0:0".to_string()
    } else {
        detect_user_spec(config.rootless_override)
    };
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

/// Build docker args for Rust-native entrypoint dispatch.
///
/// Identical to [`build`] but uses `--entrypoint zephyr` instead of a bash
/// script path.  The caller is responsible for appending the image name,
/// `"entrypoint"`, the entrypoint name, and any passthrough args.
pub fn build_rust_mode(
    config: &ZephyrConfig,
    spack_baked: bool,
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
    let user_spec = if dev_sudo_enabled() {
        "0:0".to_string()
    } else {
        detect_user_spec(config.rootless_override)
    };
    args.push(format!("--user={user_spec}"));

    // Host identity mount (optional)
    if std::env::var("SYGALDRY_MOUNT_HOST_IDENTITY").as_deref() == Ok("1") {
        args.push("--volume=/etc/passwd:/etc/passwd:ro".into());
        args.push("--volume=/etc/group:/etc/group:ro".into());
    }

    // Volume mounts (per-project + shared caches)
    build_volume_mounts(&mut args, config, spack_baked)?;

    // Mode-specific mounts and workdir (no entrypoint_container_dir needed in rust mode)
    let sygaldry_root_in_container = build_mode_mounts(&mut args, config, Some("rust-mode"))?;

    // Rust-native entrypoint: override with the in-container `zephyr` binary
    args.push("--entrypoint".into());
    args.push("zephyr".into());

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

fn dev_sudo_enabled() -> bool {
    matches!(
        std::env::var("ZEPHYR_DEV_SUDO").as_deref(),
        Ok("1") | Ok("true") | Ok("TRUE")
    )
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
    use crate::paths::{container_paths, HostLayout};

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
    fn build_dev_sudo_uses_root_user() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        std::env::set_var("ZEPHYR_DEV_SUDO", "1");
        let args = build(&config, "default", false, None).unwrap();
        std::env::remove_var("ZEPHYR_DEV_SUDO");

        assert!(args.iter().any(|a| a == "--user=0:0"));
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

    // -- build_rust_mode tests --

    #[test]
    fn rust_mode_args_contain_entrypoint_zephyr() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        std::env::remove_var("SYGALDRY_MOUNT_HOST_IDENTITY");
        let args = build_rust_mode(&config, false).unwrap();

        // Must contain --entrypoint followed by zephyr as separate args
        let ep_idx = args.iter().position(|a| a == "--entrypoint");
        assert!(ep_idx.is_some(), "missing --entrypoint flag");
        let ep_idx = ep_idx.unwrap();
        assert_eq!(
            args.get(ep_idx + 1).map(String::as_str),
            Some("zephyr"),
            "--entrypoint must be followed by 'zephyr'"
        );
    }

    #[test]
    fn rust_mode_args_do_not_contain_bash_entrypoint_path() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        std::env::remove_var("SYGALDRY_MOUNT_HOST_IDENTITY");
        let args = build_rust_mode(&config, false).unwrap();

        // No --entrypoint=<path> style arg (bash mode uses --entrypoint=/path/to/script.sh)
        assert!(
            !args.iter().any(|a| a.starts_with("--entrypoint=/")),
            "rust mode must not contain a bash entrypoint path"
        );
    }

    #[test]
    fn rust_mode_args_contain_basic_flags() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        std::env::remove_var("SYGALDRY_MOUNT_HOST_IDENTITY");
        let args = build_rust_mode(&config, false).unwrap();

        assert!(args.contains(&"--rm".to_string()));
        assert!(args.contains(&"--init".to_string()));
        assert!(args.contains(&"--runtime=nvidia".to_string()));
        assert!(args.contains(&"--gpus=all".to_string()));
        assert!(args.contains(&"--network=bridge".to_string()));
    }
}
