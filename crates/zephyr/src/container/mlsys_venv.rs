use crate::paths::container_paths;
use std::path::Path;

/// Auto-activate baked MLSys venvs.
///
/// No-op if SYGALDRY_MLSYS_ENV is unset or the venv root doesn't exist.
pub fn activate() {
    let venv_root = std::env::var("SYGALDRY_MLSYS_VENV_ROOT")
        .unwrap_or_else(|_| container_paths::MLSYS_VENV_ROOT.to_string());
    let env_name = match std::env::var("SYGALDRY_MLSYS_ENV") {
        Ok(name) if !name.is_empty() => name,
        _ => return,
    };

    let root = Path::new(&venv_root);
    if !root.is_dir() {
        return;
    }

    let target = std::env::var("SYGALDRY_MLSYS_TARGET").unwrap_or_default();

    // Try target-specific venv
    let env_dir = root.join(&env_name);
    let venv_dir = if !target.is_empty() && env_dir.join(&target).join("bin/activate").exists() {
        Some(env_dir.join(&target))
    } else if env_dir.join("bin/activate").exists() {
        Some(env_dir.clone())
    } else {
        // Find first sub-venv
        find_first_venv(&env_dir)
    };

    if let Some(venv) = venv_dir {
        if venv.join("bin/activate").exists() {
            // Set VIRTUAL_ENV and update PATH (equivalent of sourcing activate)
            std::env::set_var("VIRTUAL_ENV", &venv);
            let venv_bin = venv.join("bin");
            let path = std::env::var("PATH").unwrap_or_default();
            std::env::set_var("PATH", format!("{}:{path}", venv_bin.display()));
            eprintln!("[zephyr] MLSys venv activated: {}", venv.display());
        }
    }
}

pub(crate) fn find_first_venv(dir: &Path) -> Option<std::path::PathBuf> {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().join("bin/activate").exists())
        .collect();
    entries.sort_by_key(|e| e.file_name());
    entries.first().map(|e| e.path())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    // -- find_first_venv --

    #[test]
    fn find_first_venv_returns_none_for_empty_dir() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(find_first_venv(tmp.path()), None);
    }

    #[test]
    fn find_first_venv_returns_none_for_nonexistent() {
        assert_eq!(find_first_venv(Path::new("/nonexistent/path")), None);
    }

    #[test]
    fn find_first_venv_finds_venv_with_activate() {
        let tmp = tempfile::tempdir().unwrap();
        let venv = tmp.path().join("my-venv").join("bin");
        std::fs::create_dir_all(&venv).unwrap();
        std::fs::write(venv.join("activate"), "# activate script").unwrap();

        let result = find_first_venv(tmp.path());
        assert!(result.is_some());
        assert!(result.unwrap().ends_with("my-venv"));
    }

    #[test]
    fn find_first_venv_picks_alphabetically_first() {
        let tmp = tempfile::tempdir().unwrap();
        for name in &["zeta-env", "alpha-env", "beta-env"] {
            let venv = tmp.path().join(name).join("bin");
            std::fs::create_dir_all(&venv).unwrap();
            std::fs::write(venv.join("activate"), "# activate").unwrap();
        }

        let result = find_first_venv(tmp.path());
        assert!(result.is_some());
        let result_name = result.unwrap();
        assert!(result_name.ends_with("alpha-env"), "should pick alpha-env first");
    }

    #[test]
    fn find_first_venv_ignores_dirs_without_activate() {
        let tmp = tempfile::tempdir().unwrap();
        // dir without activate
        std::fs::create_dir_all(tmp.path().join("no-activate").join("bin")).unwrap();
        // dir with activate
        let venv = tmp.path().join("real-env").join("bin");
        std::fs::create_dir_all(&venv).unwrap();
        std::fs::write(venv.join("activate"), "# activate").unwrap();

        let result = find_first_venv(tmp.path());
        assert!(result.is_some());
        assert!(result.unwrap().ends_with("real-env"));
    }

    // -- activate --

    #[test]
    #[serial]
    fn activate_noop_when_env_unset() {
        std::env::remove_var("SYGALDRY_MLSYS_ENV");
        activate(); // should not panic
    }

    #[test]
    #[serial]
    fn activate_noop_when_env_empty() {
        std::env::set_var("SYGALDRY_MLSYS_ENV", "");
        activate(); // should not panic
        std::env::remove_var("SYGALDRY_MLSYS_ENV");
    }

    #[test]
    #[serial]
    fn activate_sets_virtual_env_when_found() {
        let tmp = tempfile::tempdir().unwrap();
        let env_dir = tmp.path().join("torch-nightly").join("bin");
        std::fs::create_dir_all(&env_dir).unwrap();
        std::fs::write(env_dir.join("activate"), "# activate").unwrap();

        std::env::set_var("SYGALDRY_MLSYS_VENV_ROOT", tmp.path().display().to_string());
        std::env::set_var("SYGALDRY_MLSYS_ENV", "torch-nightly");
        std::env::remove_var("SYGALDRY_MLSYS_TARGET");

        activate();

        let virtual_env = std::env::var("VIRTUAL_ENV").unwrap_or_default();
        assert!(
            virtual_env.contains("torch-nightly"),
            "VIRTUAL_ENV should point to torch-nightly venv, got: {virtual_env}"
        );

        std::env::remove_var("SYGALDRY_MLSYS_ENV");
        std::env::remove_var("SYGALDRY_MLSYS_VENV_ROOT");
        std::env::remove_var("VIRTUAL_ENV");
    }

    #[test]
    #[serial]
    fn activate_with_target_uses_target_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let target_dir = tmp.path().join("torch-nightly").join("cuda12").join("bin");
        std::fs::create_dir_all(&target_dir).unwrap();
        std::fs::write(target_dir.join("activate"), "# activate").unwrap();

        std::env::set_var("SYGALDRY_MLSYS_VENV_ROOT", tmp.path().display().to_string());
        std::env::set_var("SYGALDRY_MLSYS_ENV", "torch-nightly");
        std::env::set_var("SYGALDRY_MLSYS_TARGET", "cuda12");

        activate();

        let virtual_env = std::env::var("VIRTUAL_ENV").unwrap_or_default();
        assert!(
            virtual_env.contains("cuda12"),
            "VIRTUAL_ENV should use target dir, got: {virtual_env}"
        );

        std::env::remove_var("SYGALDRY_MLSYS_ENV");
        std::env::remove_var("SYGALDRY_MLSYS_VENV_ROOT");
        std::env::remove_var("SYGALDRY_MLSYS_TARGET");
        std::env::remove_var("VIRTUAL_ENV");
    }
}
