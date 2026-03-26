use crate::config::{LaunchMode, ZephyrConfig};
use crate::error::Result;
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

/// Resolve a host path and push its mount arg. Reduces boilerplate.
fn push_mount(
    args: &mut Vec<String>,
    host_path: &std::path::Path,
    container_path: &str,
    readonly: bool,
) -> Result<()> {
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
pub(crate) fn build_volume_mounts(
    args: &mut Vec<String>,
    config: &ZephyrConfig,
    spack_baked: bool,
) -> Result<()> {
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
pub(crate) fn build_mode_mounts(
    args: &mut Vec<String>,
    config: &ZephyrConfig,
    entrypoint_container_dir: Option<&str>,
) -> Result<String> {
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
    fn build_volume_mounts_contain_home() {
        let tmp = tempfile::tempdir().unwrap();
        let mut config = test_config_in(tmp.path());
        config.layout.ensure_dirs().unwrap();
        config.sygaldry_home = tmp.path().join("sygaldry");
        std::fs::create_dir_all(&config.sygaldry_home).unwrap();

        let mut args = Vec::new();
        build_volume_mounts(&mut args, &config, false).unwrap();
        assert!(
            args.iter()
                .any(|a| a.contains(container_paths::HOME) && a.starts_with("--volume=")),
            "should mount HOME"
        );
    }
}
