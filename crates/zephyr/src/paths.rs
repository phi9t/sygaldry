use std::path::{Path, PathBuf};

use crate::error::IoResultExt;

/// Container-side path constants.
///
/// These are the canonical mount targets inside the container.
/// They MUST match what the launcher mounts and what entrypoints expect.
pub mod container_paths {
    pub const HOME: &str = "/home/kvothe";
    pub const CONFIG_HOME: &str = "/home/kvothe/.config";
    pub const LOCAL_SHARE: &str = "/home/kvothe/.local/share";
    pub const OUTPUT_ROOT: &str = "/workspace/outputs";
    pub const SPACK_STORE: &str = "/opt/spack_store";
    pub const SPACK_VIEW: &str = "/opt/spack_store/view";
    pub const SPACK_SRC: &str = "/opt/spack_src";
    pub const BAZEL_CACHE: &str = "/opt/bazel_cache";
    pub const HF_CACHE: &str = "/opt/hf_cache";
    pub const UV_CACHE: &str = "/opt/uv_cache";
    pub const TORCH_CACHE: &str = "/opt/torch_cache";
    pub const TRITON_CACHE: &str = "/opt/triton_cache";
    pub const NV_COMPUTE_CACHE: &str = "/opt/nv_compute_cache";
    pub const JAX_CACHE: &str = "/opt/jax_cache";
    pub const WORKSPACE: &str = "/workspace";
    pub const SYGALDRY: &str = "/opt/sygaldry";
    pub const ENTRYPOINT_DIR: &str = "/opt/container_entrypoints";
    pub const SPACK_ENV_DEFAULT: &str = "/opt/spack_env/default";
    pub const SPACK_ENV_ZEPHYR: &str = "/opt/spack_env/zephyr";
    pub const SPACK_BAKED_ENTRYPOINT_DIR: &str = "/opt/spack_env/entrypoints";
    pub const MLSYS_VENV_ROOT: &str = "/opt/mlsys-envs";
    pub const HF_DOWNLOAD_VENV: &str = "/opt/uv_cache/venvs/hf-download";
    pub const USER: &str = "kvothe";

    /// Fallback Python version when detection fails.
    /// Must match the Spack-built Python (currently 3.13.x).
    pub const SPACK_PYTHON_VERSION_FALLBACK: &str = "3.13";
}

/// Default host-side root for all Zephyr container state.
pub const DEFAULT_CACHE_ROOT: &str = "/mnt/data_infra/zephyr_container_infra";

/// Host-side directory layout derived from a project config.
///
/// All paths are absolute. Created lazily by the launcher.
#[derive(Debug, Clone)]
pub struct HostLayout {
    // Roots
    pub cache_root: PathBuf,
    pub shared_root: PathBuf,
    pub build_root: PathBuf,
    #[allow(dead_code)]
    pub projects_root: PathBuf,
    pub project_root: PathBuf,
    pub meta_root: PathBuf,

    // Per-project directories
    pub home: PathBuf,
    pub config: PathBuf,
    pub local_share: PathBuf,
    pub outputs: PathBuf,
    pub workspace: PathBuf,
    pub runs: PathBuf,
    pub leases: PathBuf,
    pub logs: PathBuf,

    // Shared caches
    pub spack_store: PathBuf,
    pub bazel_cache: PathBuf,
    pub hf_cache: PathBuf,
    pub uv_cache: PathBuf,
    pub torch_cache: PathBuf,
    pub triton_cache: PathBuf,
    pub nv_compute_cache: PathBuf,
    pub jax_cache: PathBuf,
}

impl HostLayout {
    /// All directories that must exist before launching a container.
    pub fn required_dirs(&self) -> Vec<&Path> {
        vec![
            &self.shared_root,
            &self.build_root,
            &self.project_root,
            &self.meta_root,
            &self.home,
            &self.config,
            &self.local_share,
            &self.outputs,
            &self.workspace,
            &self.runs,
            &self.leases,
            &self.logs,
            &self.spack_store,
            &self.bazel_cache,
            &self.hf_cache,
            &self.uv_cache,
            &self.torch_cache,
            &self.triton_cache,
            &self.nv_compute_cache,
            &self.jax_cache,
        ]
    }

    /// Create all required host directories. Idempotent.
    pub fn ensure_dirs(&self) -> crate::error::Result<()> {
        for dir in self.required_dirs() {
            std::fs::create_dir_all(dir).with_path(dir)?;
        }
        Ok(())
    }

    /// Write the layout version marker file.
    pub fn write_layout_version(&self) -> crate::error::Result<()> {
        let path = self.meta_root.join("layout_version.json");
        let content =
            r#"{"layout_version":2,"layout_name":"unified-shared-cache-project-isolation"}"#;
        std::fs::write(&path, content.as_bytes()).with_path(&path)?;
        Ok(())
    }
}

/// Resolve a path: ensure parent exists, create the directory if needed, return realpath.
pub fn resolve_mount_path(path: &Path) -> crate::error::Result<PathBuf> {
    if let Some(parent) = path.parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent).with_path(parent)?;
        }
    }
    if !path.exists() {
        std::fs::create_dir_all(path).with_path(path)?;
    }
    std::fs::canonicalize(path).with_path(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- container_paths constants --

    #[test]
    fn all_container_paths_are_absolute() {
        let paths = [
            container_paths::HOME,
            container_paths::CONFIG_HOME,
            container_paths::LOCAL_SHARE,
            container_paths::OUTPUT_ROOT,
            container_paths::SPACK_STORE,
            container_paths::SPACK_VIEW,
            container_paths::SPACK_SRC,
            container_paths::BAZEL_CACHE,
            container_paths::HF_CACHE,
            container_paths::UV_CACHE,
            container_paths::TORCH_CACHE,
            container_paths::TRITON_CACHE,
            container_paths::NV_COMPUTE_CACHE,
            container_paths::JAX_CACHE,
            container_paths::WORKSPACE,
            container_paths::SYGALDRY,
            container_paths::ENTRYPOINT_DIR,
            container_paths::SPACK_ENV_DEFAULT,
            container_paths::SPACK_ENV_ZEPHYR,
            container_paths::SPACK_BAKED_ENTRYPOINT_DIR,
            container_paths::MLSYS_VENV_ROOT,
            container_paths::HF_DOWNLOAD_VENV,
        ];
        for p in paths {
            assert!(p.starts_with('/'), "path '{p}' is not absolute");
        }
    }

    #[test]
    fn container_user_is_kvothe() {
        assert_eq!(container_paths::USER, "kvothe");
    }

    #[test]
    fn spack_view_is_under_spack_store() {
        assert!(container_paths::SPACK_VIEW.starts_with(container_paths::SPACK_STORE));
    }

    #[test]
    fn config_home_is_under_home() {
        assert!(container_paths::CONFIG_HOME.starts_with(container_paths::HOME));
    }

    // -- DEFAULT_CACHE_ROOT --

    #[test]
    fn default_cache_root_is_absolute() {
        assert!(DEFAULT_CACHE_ROOT.starts_with('/'));
    }

    // -- resolve_mount_path --

    #[test]
    fn resolve_mount_path_creates_dirs() {
        let tmp = tempfile::tempdir().unwrap();
        let nested = tmp.path().join("a").join("b").join("c");
        let resolved = resolve_mount_path(&nested).unwrap();
        assert!(resolved.exists());
        assert!(resolved.is_absolute());
    }

    #[test]
    fn resolve_mount_path_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("x");
        let first = resolve_mount_path(&path).unwrap();
        let second = resolve_mount_path(&path).unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn resolve_mount_path_creates_parent_if_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let deep = tmp.path().join("level1").join("level2").join("target");
        assert!(!tmp.path().join("level1").exists());
        let resolved = resolve_mount_path(&deep).unwrap();
        assert!(resolved.exists());
        assert!(tmp.path().join("level1").join("level2").exists());
    }

    // -- HostLayout --

    fn test_layout(root: &Path) -> HostLayout {
        HostLayout {
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
        }
    }

    #[test]
    fn required_dirs_has_expected_count() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = test_layout(tmp.path());
        // 4 roots + 8 per-project + 8 shared caches = 20
        assert_eq!(layout.required_dirs().len(), 20);
    }

    #[test]
    fn ensure_dirs_creates_all() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = test_layout(tmp.path());
        layout.ensure_dirs().unwrap();
        for dir in layout.required_dirs() {
            assert!(dir.exists(), "dir not created: {}", dir.display());
        }
    }

    #[test]
    fn ensure_dirs_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = test_layout(tmp.path());
        layout.ensure_dirs().unwrap();
        layout.ensure_dirs().unwrap(); // should not fail
    }

    #[test]
    fn write_layout_version_creates_json() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = test_layout(tmp.path());
        layout.ensure_dirs().unwrap();
        layout.write_layout_version().unwrap();

        let path = layout.meta_root.join("layout_version.json");
        assert!(path.exists());
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("layout_version"));
        assert!(content.contains("unified-shared-cache-project-isolation"));

        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        assert_eq!(parsed["layout_version"], 2);
    }

    #[test]
    fn write_layout_version_overwrites_existing() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = test_layout(tmp.path());
        layout.ensure_dirs().unwrap();
        layout.write_layout_version().unwrap();
        layout.write_layout_version().unwrap(); // should overwrite cleanly
    }
}
