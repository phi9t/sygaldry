use crate::error::{Result, ZephyrError};
use crate::paths::container_paths;
use std::process::Command;

/// Download a HuggingFace model via huggingface_hub.
pub fn download_model(model_id: &str) -> Result<()> {
    ensure_hf_deps()?;
    run_python_script(&model_script(model_id))
}

/// Download a HuggingFace dataset.
pub fn download_dataset(dataset_id: &str, config: &str, split: &str) -> Result<()> {
    ensure_hf_deps()?;
    run_python_script(&dataset_script(dataset_id, config, split))
}

/// Generate the Python script for downloading a model.
fn model_script(model_id: &str) -> String {
    format!(
        r#"
from huggingface_hub import snapshot_download
import os
path = snapshot_download('{model_id}', cache_dir=os.environ.get('HF_HOME', '{hf_cache}'))
print(f'Downloaded {model_id} to {{path}}')
"#,
        hf_cache = container_paths::HF_CACHE,
    )
}

/// Generate the Python script for downloading a dataset.
fn dataset_script(dataset_id: &str, config: &str, split: &str) -> String {
    format!(
        r#"
from datasets import load_dataset
import os
ds = load_dataset('{dataset_id}', '{config}', split='{split}', cache_dir=os.environ.get('HF_HOME', '{hf_cache}'))
print(f'Downloaded {{len(ds)}} rows from {dataset_id}')
"#,
        hf_cache = container_paths::HF_CACHE,
    )
}

/// Ensure datasets and huggingface_hub are installed.
fn ensure_hf_deps() -> Result<()> {
    let venv_dir = std::env::var("HF_VENV_DIR")
        .unwrap_or_else(|_| container_paths::HF_DOWNLOAD_VENV.to_string());

    let check = Command::new(format!("{venv_dir}/bin/python"))
        .args(["-c", "import datasets, huggingface_hub"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    if let Ok(s) = check {
        if s.success() {
            return Ok(());
        }
    }

    // Create venv and install deps
    let uv = which::which("uv").map_err(|_| {
        ZephyrError::with_hint("uv not found", "uv is required for HF downloads")
    })?;

    std::fs::create_dir_all(&venv_dir)?;

    let status = Command::new(&uv).args(["venv", &venv_dir]).status()?;
    if !status.success() {
        return Err(ZephyrError::CommandFailed {
            command: "uv venv".to_string(),
            code: status.code().unwrap_or(1),
        });
    }

    let status = Command::new(&uv)
        .args([
            "pip",
            "install",
            "--python",
            &format!("{venv_dir}/bin/python"),
            "datasets",
            "huggingface-hub",
        ])
        .status()?;
    if !status.success() {
        return Err(ZephyrError::CommandFailed {
            command: "uv pip install datasets huggingface-hub".to_string(),
            code: status.code().unwrap_or(1),
        });
    }

    Ok(())
}

fn run_python_script(script: &str) -> Result<()> {
    let venv_dir = std::env::var("HF_VENV_DIR")
        .unwrap_or_else(|_| container_paths::HF_DOWNLOAD_VENV.to_string());
    let python = format!("{venv_dir}/bin/python");

    let status = Command::new(&python).args(["-c", script]).status()?;
    if !status.success() {
        return Err(ZephyrError::CommandFailed {
            command: "hf-download".to_string(),
            code: status.code().unwrap_or(1),
        });
    }
    Ok(())
}

/// Resolve the HF venv directory from env or default.
#[cfg(test)]
fn resolve_venv_dir() -> String {
    std::env::var("HF_VENV_DIR")
        .unwrap_or_else(|_| container_paths::HF_DOWNLOAD_VENV.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    // -- model_script --

    #[test]
    fn model_script_contains_model_id() {
        let script = model_script("Qwen/Qwen3-0.6B-Base");
        assert!(script.contains("Qwen/Qwen3-0.6B-Base"));
    }

    #[test]
    fn model_script_contains_hf_cache() {
        let script = model_script("test/model");
        assert!(script.contains(container_paths::HF_CACHE));
    }

    #[test]
    fn model_script_contains_snapshot_download() {
        let script = model_script("test/model");
        assert!(script.contains("snapshot_download"));
    }

    #[test]
    fn model_script_is_valid_python_structure() {
        let script = model_script("test/model");
        assert!(script.contains("import"));
        assert!(script.contains("from huggingface_hub"));
    }

    // -- dataset_script --

    #[test]
    fn dataset_script_contains_dataset_params() {
        let script = dataset_script("wikitext", "wikitext-2-v1", "train[:100]");
        assert!(script.contains("wikitext"));
        assert!(script.contains("wikitext-2-v1"));
        assert!(script.contains("train[:100]"));
    }

    #[test]
    fn dataset_script_contains_hf_cache() {
        let script = dataset_script("test/ds", "default", "train");
        assert!(script.contains(container_paths::HF_CACHE));
    }

    #[test]
    fn dataset_script_contains_load_dataset() {
        let script = dataset_script("test/ds", "default", "train");
        assert!(script.contains("load_dataset"));
    }

    // -- resolve_venv_dir --

    #[test]
    #[serial]
    fn resolve_venv_dir_uses_env_override() {
        std::env::set_var("HF_VENV_DIR", "/custom/venv");
        assert_eq!(resolve_venv_dir(), "/custom/venv");
        std::env::remove_var("HF_VENV_DIR");
    }

    #[test]
    #[serial]
    fn resolve_venv_dir_uses_default_when_unset() {
        std::env::remove_var("HF_VENV_DIR");
        assert_eq!(resolve_venv_dir(), container_paths::HF_DOWNLOAD_VENV);
    }

    // -- python path construction --

    #[test]
    #[serial]
    fn run_python_script_uses_venv_python() {
        std::env::set_var("HF_VENV_DIR", "/opt/test-venv");
        let venv_dir = resolve_venv_dir();
        let python = format!("{venv_dir}/bin/python");
        assert_eq!(python, "/opt/test-venv/bin/python");
        std::env::remove_var("HF_VENV_DIR");
    }
}
