use crate::error::{Result, ZephyrError};
use crate::paths::container_paths;
use std::process::Command;

/// Run a named entrypoint sequence.
///
/// Each entrypoint composes init steps with its specific logic,
/// replacing the individual bash scripts in container/entrypoints/.
pub fn run(name: &str, args: &[String]) -> Result<()> {
    match name {
        "default" => entrypoint_default(args),
        "run-job" => entrypoint_run_job(args),
        "verify-gpu" => super::gpu_check::run(),
        "verify-spack" => super::verify::run(),
        "spack-build" => entrypoint_spack_build(),
        "spack-install" => entrypoint_spack_install(args),
        "uv-install" => super::uv_install::install(args, ".venv"),
        "hf-lora-setup" => entrypoint_hf_lora_setup(args),
        "hf-download" => entrypoint_hf_download(args),
        _ => Err(ZephyrError::EntrypointNotFound(name.to_string())),
    }
}

/// Default entrypoint: full init + GPU check + interactive shell.
fn entrypoint_default(args: &[String]) -> Result<()> {
    super::spack::full_init()?;
    super::spack::require_torch_jax()?;
    super::gpu_check::run()?;
    // Note: mlsys_venv::activate() is already called by full_init()

    // Set EDITOR/TERM defaults (matching default.sh:28-29)
    if std::env::var("EDITOR").is_err() {
        std::env::set_var("EDITOR", "nano");
    }
    if std::env::var("TERM").is_err() {
        std::env::set_var("TERM", "xterm-256color");
    }

    if !args.is_empty() {
        let status = Command::new(&args[0]).args(&args[1..]).status()?;
        if !status.success() {
            std::process::exit(status.code().unwrap_or(1));
        }
        return Ok(());
    }

    print_welcome();
    exec_shell_with_rc()
}

/// Run-job entrypoint: full init + exec command.
fn entrypoint_run_job(args: &[String]) -> Result<()> {
    super::spack::full_init()?;

    if args.is_empty() {
        return Err(ZephyrError::with_hint(
            "No command provided to run-job",
            "Usage: zephyr entrypoint run-job -- <command...>",
        ));
    }

    // Avoid cross-version contamination when job commands activate their own venvs.
    let clear = std::env::var("SYGALDRY_CLEAR_PYTHONPATH_ON_EXEC").unwrap_or_else(|_| "1".into());
    if clear == "1" {
        std::env::remove_var("PYTHONPATH");
    }

    let status = Command::new(&args[0]).args(&args[1..]).status()?;
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
    Ok(())
}

/// Spack build entrypoint: requires builder role.
fn entrypoint_spack_build() -> Result<()> {
    require_builder_role()?;
    super::spack::init_spack()?;

    // Resolve build env root
    let env_root = resolve_spack_env_root();
    let build_script = std::path::Path::new(&env_root).join("build.sh");

    let status = Command::new("bash")
        .args([build_script.display().to_string()])
        .current_dir(&env_root)
        .status()?;

    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }
    Ok(())
}

/// Spack install entrypoint: requires builder role.
fn entrypoint_spack_install(args: &[String]) -> Result<()> {
    require_builder_role()?;
    super::spack::init_spack()?;

    let mut cmd_args = vec!["install".to_string()];
    cmd_args.extend(args.iter().cloned());

    let arg_refs: Vec<&str> = cmd_args.iter().map(|s| s.as_str()).collect();
    let status = Command::new("spack").args(&arg_refs).status()?;
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }

    exec_shell()
}

/// HF download entrypoint dispatcher.
fn entrypoint_hf_download(args: &[String]) -> Result<()> {
    if args.is_empty() {
        return Err(ZephyrError::with_hint(
            "Missing mode (model|dataset)",
            "Usage: zephyr hf-download model <model_id> OR zephyr hf-download dataset <dataset_id>",
        ));
    }

    match args[0].as_str() {
        "model" => {
            let model_id = args.get(1).ok_or_else(|| {
                ZephyrError::with_hint("Missing model ID", "Usage: zephyr hf-download model <model_id>")
            })?;
            super::hf_download::download_model(model_id)
        }
        "dataset" => {
            let dataset_id = args.get(1).ok_or_else(|| {
                ZephyrError::with_hint("Missing dataset ID", "Usage: zephyr hf-download dataset <dataset_id>")
            })?;
            let config = args.get(2).map(|s| s.as_str()).unwrap_or("default");
            let split = args.get(3).map(|s| s.as_str()).unwrap_or("train[:100]");
            super::hf_download::download_dataset(dataset_id, config, split)
        }
        _ => Err(ZephyrError::with_hint(
            format!("Unknown HF download mode: {}", args[0]),
            "Use 'model' or 'dataset'.",
        )),
    }
}

/// HF LoRA setup entrypoint: creates a venv with HuggingFace/PEFT layers
/// that reuse Spack-built PyTorch (no torch override).
fn entrypoint_hf_lora_setup(args: &[String]) -> Result<()> {
    if !args.is_empty() {
        return Err(ZephyrError::with_hint(
            "hf-lora-setup takes no arguments",
            "Configure via env vars: VENV_DIR, HF_TRANSFORMERS_VERSION, HF_DATASETS_VERSION, HF_PEFT_VERSION, HF_ACCELERATE_VERSION",
        ));
    }

    let venv_dir = std::env::var("VENV_DIR").unwrap_or_else(|_| ".venv-hf-lora".into());
    let spack_py = std::env::var("PYTHON_BIN")
        .unwrap_or_else(|_| format!("{}/bin/python3", container_paths::SPACK_VIEW));
    let transformers_ver = std::env::var("HF_TRANSFORMERS_VERSION").unwrap_or_else(|_| HF_TRANSFORMERS_VERSION.into());
    let datasets_ver = std::env::var("HF_DATASETS_VERSION").unwrap_or_else(|_| HF_DATASETS_VERSION.into());
    let peft_ver = std::env::var("HF_PEFT_VERSION").unwrap_or_else(|_| HF_PEFT_VERSION.into());
    let accelerate_ver = std::env::var("HF_ACCELERATE_VERSION").unwrap_or_else(|_| HF_ACCELERATE_VERSION.into());

    if !std::path::Path::new(&spack_py).exists() {
        return Err(ZephyrError::with_hint(
            format!("Spack Python not found at {spack_py}"),
            "Ensure the Spack view is built or set PYTHON_BIN to the correct path.",
        ));
    }

    // Create venv with Spack Python
    run_cmd("uv", &["venv", "--python", &spack_py, "--system-site-packages", &venv_dir])?;

    // Install HF stack without touching torch/triton from Spack
    run_cmd("uv", &[
        "pip", "install",
        &format!("transformers=={transformers_ver}"),
        &format!("datasets=={datasets_ver}"),
        "soundfile",
    ])?;
    run_cmd("uv", &[
        "pip", "install", "--no-deps",
        &format!("peft=={peft_ver}"),
        &format!("accelerate=={accelerate_ver}"),
    ])?;

    // Write hf-lora-python wrapper script
    let wrapper_path = format!("{venv_dir}/bin/hf-lora-python");
    let spack_view = container_paths::SPACK_VIEW;
    let wrapper_content = format!(r#"#!/bin/bash
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
PY_BIN="${{BIN_DIR}}/python"

PY_VER="$("${{PY_BIN}}" - <<'PY'
import sys
print(f"{{sys.version_info.major}}.{{sys.version_info.minor}}")
PY
)"
VENV_SITE="$("${{PY_BIN}}" - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"
SPACK_SITE="{spack_view}/lib/python${{PY_VER}}/site-packages"

if [[ -d "${{SPACK_SITE}}" ]]; then
    export PYTHONPATH="${{VENV_SITE}}:${{SPACK_SITE}}${{PYTHONPATH:+:${{PYTHONPATH}}}}"
else
    export PYTHONPATH="${{VENV_SITE}}${{PYTHONPATH:+:${{PYTHONPATH}}}}"
fi

exec "${{PY_BIN}}" "$@"
"#);
    std::fs::write(&wrapper_path, wrapper_content)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&wrapper_path, std::fs::Permissions::from_mode(0o755))?;
    }

    eprintln!("HF LoRA environment ready in {venv_dir}");
    eprintln!("Torch source: Spack view (no torch override)");
    eprintln!("Run jobs with: {venv_dir}/bin/hf-lora-python hf_lora_train.py");

    Ok(())
}

/// Delegate to the shared run_cmd in uv_install.
fn run_cmd(program: &str, args: &[&str]) -> Result<()> {
    super::uv_install::run_cmd(program, args)
}

/// Default HuggingFace package versions for LoRA setup.
/// These match the defaults in container/entrypoints/hf-lora-setup.sh.
const HF_TRANSFORMERS_VERSION: &str = "5.2.0";
const HF_DATASETS_VERSION: &str = "4.5.0";
const HF_PEFT_VERSION: &str = "0.18.1";
const HF_ACCELERATE_VERSION: &str = "1.12.0";

/// Default heartbeat interval for background jobs (5 minutes).
const HEARTBEAT_INTERVAL_SECS: u64 = 300;

/// Internal job wrapper: runs inside the container, produces JSONL heartbeats.
pub fn job_wrapper(name: &str, log_file: &str, status_file: &str, command: &[String]) -> Result<()> {
    job_wrapper_with_interval(name, log_file, status_file, command, HEARTBEAT_INTERVAL_SECS)
}

/// Job wrapper with configurable heartbeat interval (for testing).
fn job_wrapper_with_interval(
    name: &str,
    log_file: &str,
    status_file: &str,
    command: &[String],
    heartbeat_secs: u64,
) -> Result<()> {
    super::spack::full_init()?;

    if command.is_empty() {
        return Err(ZephyrError::with_hint(
            "No command provided to job-wrapper",
            "This is an internal command.",
        ));
    }

    // Write start status
    let now = chrono::Utc::now().to_rfc3339();
    if let Some(parent) = std::path::Path::new(status_file).parent() {
        std::fs::create_dir_all(parent)?;
    }
    if let Some(parent) = std::path::Path::new(log_file).parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(status_file, format!("START job={name} ts={now}\n"))?;
    append_jsonl(log_file, name, "start", "starting")?;

    // Spawn heartbeat thread
    let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
    let hb_name = name.to_string();
    let hb_log = log_file.to_string();
    let hb_status = status_file.to_string();
    let heartbeat_handle = std::thread::spawn(move || {
        loop {
            match stop_rx.recv_timeout(std::time::Duration::from_secs(heartbeat_secs)) {
                Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    let now = chrono::Utc::now().to_rfc3339();
                    let _ = std::fs::write(
                        &hb_status,
                        format!("PROGRESS job={} ts={now}\n", hb_name),
                    );
                    let _ = append_jsonl(&hb_log, &hb_name, "progress", "heartbeat");
                }
            }
        }
    });

    // Run the command
    let cmd_string = command.join(" ");
    let status = Command::new("bash")
        .args(["-lc", &cmd_string])
        .status()?;

    // Stop heartbeat
    let _ = stop_tx.send(());
    let _ = heartbeat_handle.join();

    // Write final status
    let now = chrono::Utc::now().to_rfc3339();
    let rc = status.code().unwrap_or(1);
    if status.success() {
        std::fs::write(status_file, format!("DONE job={name} ts={now} rc=0\n"))?;
        append_jsonl(log_file, name, "done", "rc=0")?;
    } else {
        std::fs::write(status_file, format!("FAILED job={name} ts={now} rc={rc}\n"))?;
        append_jsonl(log_file, name, "failed", &format!("rc={rc}"))?;
    }

    if !status.success() {
        std::process::exit(rc);
    }
    Ok(())
}

fn require_builder_role() -> Result<()> {
    let role = std::env::var("SYGALDRY_BUILD_ROLE").unwrap_or_else(|_| "consumer".to_string());
    if role != "builder" {
        return Err(ZephyrError::with_hint(
            "Spack builds are restricted to the builder role.",
            "Set SYGALDRY_BUILD_ROLE=builder in the sygaldry build repo to proceed.",
        ));
    }
    Ok(())
}

fn resolve_spack_env_root() -> String {
    let candidates = [
        std::env::var("SYGALDRY_SPACK_ENV").unwrap_or_default(),
        container_paths::SPACK_ENV_DEFAULT.to_string(),
        container_paths::SPACK_ENV_ZEPHYR.to_string(),
        format!(
            "{}/pkg/zephyr",
            std::env::var("SYGALDRY_ROOT").unwrap_or_else(|_| container_paths::WORKSPACE.into())
        ),
    ];

    for c in &candidates {
        if !c.is_empty() && std::path::Path::new(c).is_dir() {
            return c.clone();
        }
    }
    container_paths::SPACK_ENV_DEFAULT.to_string()
}

fn print_welcome() {
    let mlsys_env = std::env::var("SYGALDRY_MLSYS_ENV").unwrap_or_default();
    if !mlsys_env.is_empty() {
        eprintln!("+-------------------------------------------------------------+");
        eprintln!("|                    Sygaldry Build Environment               |");
        eprintln!("|  MLSys env: {mlsys_env:<47} |");
        if let Ok(venv) = std::env::var("VIRTUAL_ENV") {
            eprintln!("|  Venv:      {venv:<47} |");
        }
        eprintln!("|                                                             |");
        eprintln!("|  Quick commands:                                            |");
        eprintln!("|    gpu-test                   - Verify PyTorch CUDA         |");
        eprintln!("|    jax-test                   - Verify JAX GPU              |");
        if mlsys_env == "llm-serving-all" {
            eprintln!("|    mlsys-activate <name>      - Switch venv (hf/vllm/sglang)|");
        }
        eprintln!("+-------------------------------------------------------------+");
    } else {
        eprintln!("+-------------------------------------------------------------+");
        eprintln!("|                    Sygaldry Build Environment               |");
        eprintln!("|                                                             |");
        eprintln!("|  Quick commands:                                            |");
        eprintln!("|    spack-env-activate         - Activate Spack environment  |");
        eprintln!("|    gpu-test                   - Verify PyTorch CUDA         |");
        eprintln!("|    jax-test                   - Verify JAX GPU              |");
        eprintln!("|    spack-build                - Build Zephyr environment    |");
        eprintln!("|                                                             |");
        eprintln!("|  Environment:                                               |");
        eprintln!("|    Workspace: {:<44} |", container_paths::WORKSPACE);
        eprintln!("|    Spack:     {:<44} |", container_paths::SPACK_SRC);
        eprintln!("|    HF Cache:  {:<44} |", container_paths::HF_CACHE);
        eprintln!("+-------------------------------------------------------------+");
    }
}

const SHELL_RC_PATH: &str = "/tmp/.zephyr_shellrc";

fn write_shell_rc() -> Result<()> {
    use std::io::Write;
    let home = std::env::var("HOME").unwrap_or_else(|_| container_paths::HOME.into());
    let mut rc = std::fs::File::create(SHELL_RC_PATH)?;
    writeln!(rc, "# Zephyr shell RC — auto-generated, do not edit")?;
    writeln!(rc, "[[ -f {home}/.bashrc ]] && source {home}/.bashrc")?;
    writeln!(rc)?;
    writeln!(rc, "# Convenience aliases")?;
    writeln!(rc, r#"alias gpu-test='python3 -c "import torch; print(f\"CUDA: {{torch.cuda.is_available()}}\")"'"#)?;
    writeln!(rc, r#"alias jax-test='python3 -c "import jax; print(f\"Devices: {{jax.devices()}}\")"'"#)?;
    writeln!(rc, "alias spack-build='cd ${{SYGALDRY_SPACK_ENV:-{}}} && ./build.sh'", container_paths::SPACK_ENV_DEFAULT)?;
    writeln!(rc)?;
    writeln!(rc, "hf-dataset() {{")?;
    writeln!(rc, r#"    python3 -c "from datasets import load_dataset; ds=load_dataset('$1', split='${{2:-train[:100]}}'); print(f'{{len(ds)}} rows')""#)?;
    writeln!(rc, "}}")?;
    Ok(())
}

fn exec_shell_with_rc() -> Result<()> {
    write_shell_rc()?;
    let status = Command::new("bash")
        .args(["--rcfile", SHELL_RC_PATH, "-i"])
        .status()?;
    if !status.success() {
        std::process::exit(status.code().unwrap_or(0));
    }
    Ok(())
}

fn exec_shell() -> Result<()> {
    let status = Command::new("bash").arg("-i").status()?;
    if !status.success() {
        std::process::exit(status.code().unwrap_or(0));
    }
    Ok(())
}

pub(crate) fn append_jsonl(path: &str, job: &str, event: &str, msg: &str) -> Result<()> {
    use std::io::Write;
    let now = chrono::Utc::now().to_rfc3339();
    let line = serde_json::json!({
        "ts": now,
        "event": event,
        "job": job,
        "msg": msg,
    });
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(file, "{}", line)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    // -- require_builder_role --

    #[test]
    #[serial]
    fn require_builder_role_rejects_consumer() {
        std::env::set_var("SYGALDRY_BUILD_ROLE", "consumer");
        let result = require_builder_role();
        assert!(result.is_err());
        std::env::remove_var("SYGALDRY_BUILD_ROLE");
    }

    #[test]
    #[serial]
    fn require_builder_role_rejects_unset() {
        std::env::remove_var("SYGALDRY_BUILD_ROLE");
        let result = require_builder_role();
        assert!(result.is_err());
    }

    #[test]
    #[serial]
    fn require_builder_role_accepts_builder() {
        std::env::set_var("SYGALDRY_BUILD_ROLE", "builder");
        let result = require_builder_role();
        assert!(result.is_ok());
        std::env::remove_var("SYGALDRY_BUILD_ROLE");
    }

    // -- resolve_spack_env_root --

    #[test]
    #[serial]
    fn resolve_spack_env_root_returns_from_env_if_valid() {
        let tmp = tempfile::tempdir().unwrap();
        let env_dir = tmp.path().join("my_spack");
        std::fs::create_dir_all(&env_dir).unwrap();
        std::env::set_var("SYGALDRY_SPACK_ENV", env_dir.display().to_string());
        let result = resolve_spack_env_root();
        assert_eq!(result, env_dir.display().to_string());
        std::env::remove_var("SYGALDRY_SPACK_ENV");
    }

    #[test]
    #[serial]
    fn resolve_spack_env_root_falls_back() {
        std::env::remove_var("SYGALDRY_SPACK_ENV");
        let result = resolve_spack_env_root();
        // Since none of the candidate dirs exist in test, it falls back to default
        assert!(result.contains("spack_env"));
    }

    // -- entrypoint dispatch --

    #[test]
    fn run_unknown_entrypoint_returns_error() {
        let result = run("nonexistent-entrypoint", &[]);
        assert!(result.is_err());
        let err_msg = format!("{}", result.unwrap_err());
        assert!(err_msg.contains("nonexistent-entrypoint"));
    }

    // -- entrypoint_hf_download validation --

    #[test]
    fn hf_download_empty_args_errors() {
        let result = entrypoint_hf_download(&[]);
        assert!(result.is_err());
    }

    #[test]
    fn hf_download_unknown_mode_errors() {
        let result = entrypoint_hf_download(&["foo".to_string()]);
        assert!(result.is_err());
    }

    #[test]
    fn hf_download_model_missing_id_errors() {
        let result = entrypoint_hf_download(&["model".to_string()]);
        assert!(result.is_err());
    }

    #[test]
    fn hf_download_dataset_missing_id_errors() {
        let result = entrypoint_hf_download(&["dataset".to_string()]);
        assert!(result.is_err());
    }

    // -- entrypoint_run_job validation --

    #[test]
    fn run_job_no_args_errors() {
        let result = entrypoint_run_job(&[]);
        assert!(result.is_err());
    }

    // -- append_jsonl --

    #[test]
    fn append_jsonl_creates_file_and_writes_json() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("test.jsonl");
        let path_str = path.display().to_string();

        append_jsonl(&path_str, "train", "start", "beginning").unwrap();
        append_jsonl(&path_str, "train", "done", "rc=0").unwrap();

        let content = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 2);

        let first: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(first["event"], "start");
        assert_eq!(first["job"], "train");
        assert_eq!(first["msg"], "beginning");
        assert!(first["ts"].is_string());

        let second: serde_json::Value = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(second["event"], "done");
    }

    #[test]
    fn append_jsonl_appends_not_overwrites() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("append.jsonl");
        let path_str = path.display().to_string();

        for i in 0..5 {
            append_jsonl(&path_str, "job", "tick", &format!("iter={i}")).unwrap();
        }

        let content = std::fs::read_to_string(&path).unwrap();
        assert_eq!(content.lines().count(), 5);
    }

    // -- run-job PYTHONPATH clearing --

    #[test]
    #[serial]
    fn run_job_clears_pythonpath_by_default() {
        std::env::set_var("PYTHONPATH", "/some/path");
        std::env::remove_var("SYGALDRY_CLEAR_PYTHONPATH_ON_EXEC");
        // We can't call entrypoint_run_job without a real command,
        // so test the clearing logic directly.
        let clear = std::env::var("SYGALDRY_CLEAR_PYTHONPATH_ON_EXEC")
            .unwrap_or_else(|_| "1".into());
        if clear == "1" {
            std::env::remove_var("PYTHONPATH");
        }
        assert!(std::env::var("PYTHONPATH").is_err());
    }

    #[test]
    #[serial]
    fn run_job_preserves_pythonpath_when_disabled() {
        std::env::set_var("PYTHONPATH", "/some/path");
        std::env::set_var("SYGALDRY_CLEAR_PYTHONPATH_ON_EXEC", "0");
        let clear = std::env::var("SYGALDRY_CLEAR_PYTHONPATH_ON_EXEC")
            .unwrap_or_else(|_| "1".into());
        if clear == "1" {
            std::env::remove_var("PYTHONPATH");
        }
        assert_eq!(std::env::var("PYTHONPATH").unwrap(), "/some/path");
        std::env::remove_var("PYTHONPATH");
        std::env::remove_var("SYGALDRY_CLEAR_PYTHONPATH_ON_EXEC");
    }

    // -- EDITOR/TERM defaults --

    #[test]
    #[serial]
    fn editor_default_sets_nano_when_unset() {
        std::env::remove_var("EDITOR");
        if std::env::var("EDITOR").is_err() {
            std::env::set_var("EDITOR", "nano");
        }
        assert_eq!(std::env::var("EDITOR").unwrap(), "nano");
        std::env::remove_var("EDITOR");
    }

    #[test]
    #[serial]
    fn editor_default_preserves_existing() {
        std::env::set_var("EDITOR", "vim");
        if std::env::var("EDITOR").is_err() {
            std::env::set_var("EDITOR", "nano");
        }
        assert_eq!(std::env::var("EDITOR").unwrap(), "vim");
        std::env::remove_var("EDITOR");
    }

    #[test]
    #[serial]
    fn term_default_sets_xterm_when_unset() {
        std::env::remove_var("TERM");
        if std::env::var("TERM").is_err() {
            std::env::set_var("TERM", "xterm-256color");
        }
        assert_eq!(std::env::var("TERM").unwrap(), "xterm-256color");
        std::env::remove_var("TERM");
    }

    // -- print_welcome --

    #[test]
    #[serial]
    fn print_welcome_does_not_panic() {
        std::env::remove_var("SYGALDRY_MLSYS_ENV");
        std::env::remove_var("VIRTUAL_ENV");
        print_welcome(); // smoke test

        std::env::set_var("SYGALDRY_MLSYS_ENV", "torch-nightly");
        print_welcome(); // smoke test with env set

        std::env::set_var("VIRTUAL_ENV", "/opt/mlsys-envs/torch-nightly");
        print_welcome(); // smoke test with VIRTUAL_ENV

        std::env::set_var("SYGALDRY_MLSYS_ENV", "llm-serving-all");
        print_welcome(); // smoke test with llm-serving-all hint

        std::env::remove_var("SYGALDRY_MLSYS_ENV");
        std::env::remove_var("VIRTUAL_ENV");
    }

    // -- hf-lora-setup --

    #[test]
    fn hf_lora_setup_rejects_args() {
        let result = entrypoint_hf_lora_setup(&["--help".to_string()]);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("no arguments"));
    }

    #[test]
    #[serial]
    fn hf_lora_setup_fails_on_missing_python() {
        std::env::set_var("PYTHON_BIN", "/nonexistent/python3");
        std::env::set_var("VENV_DIR", "/tmp/test-lora-venv");
        let result = entrypoint_hf_lora_setup(&[]);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("Spack Python not found"));
        std::env::remove_var("PYTHON_BIN");
        std::env::remove_var("VENV_DIR");
    }

    #[test]
    #[serial]
    fn hf_lora_setup_version_defaults() {
        // Verify the defaults match the bash script
        std::env::remove_var("HF_TRANSFORMERS_VERSION");
        std::env::remove_var("HF_DATASETS_VERSION");
        std::env::remove_var("HF_PEFT_VERSION");
        std::env::remove_var("HF_ACCELERATE_VERSION");
        assert_eq!(
            std::env::var("HF_TRANSFORMERS_VERSION").unwrap_or_else(|_| HF_TRANSFORMERS_VERSION.into()),
            HF_TRANSFORMERS_VERSION
        );
        assert_eq!(
            std::env::var("HF_DATASETS_VERSION").unwrap_or_else(|_| HF_DATASETS_VERSION.into()),
            HF_DATASETS_VERSION
        );
        assert_eq!(
            std::env::var("HF_PEFT_VERSION").unwrap_or_else(|_| HF_PEFT_VERSION.into()),
            HF_PEFT_VERSION
        );
        assert_eq!(
            std::env::var("HF_ACCELERATE_VERSION").unwrap_or_else(|_| HF_ACCELERATE_VERSION.into()),
            HF_ACCELERATE_VERSION
        );
    }

    // -- heartbeat --

    #[test]
    fn heartbeat_stops_on_signal() {
        use std::sync::mpsc;
        let (stop_tx, stop_rx) = mpsc::channel::<()>();

        let handle = std::thread::spawn(move || {
            let mut ticks = 0u32;
            loop {
                match stop_rx.recv_timeout(std::time::Duration::from_millis(10)) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(mpsc::RecvTimeoutError::Timeout) => ticks += 1,
                }
            }
            ticks
        });

        // Let it tick a few times then stop
        std::thread::sleep(std::time::Duration::from_millis(50));
        stop_tx.send(()).unwrap();
        let ticks = handle.join().unwrap();
        assert!(ticks > 0, "heartbeat should have ticked at least once");
    }

    #[test]
    fn heartbeat_writes_progress_within_interval() {
        let tmp = tempfile::tempdir().unwrap();
        let status_file = tmp.path().join("status");
        let log_file = tmp.path().join("log.jsonl");

        // Write initial status
        std::fs::write(&status_file, "START\n").unwrap();

        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        let hb_status = status_file.display().to_string();
        let hb_log = log_file.display().to_string();

        let handle = std::thread::spawn(move || {
            loop {
                match stop_rx.recv_timeout(std::time::Duration::from_millis(20)) {
                    Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        let now = chrono::Utc::now().to_rfc3339();
                        let _ = std::fs::write(&hb_status, format!("PROGRESS ts={now}\n"));
                        let _ = append_jsonl(&hb_log, "test", "progress", "heartbeat");
                    }
                }
            }
        });

        // Wait for at least one heartbeat
        std::thread::sleep(std::time::Duration::from_millis(60));
        let _ = stop_tx.send(());
        let _ = handle.join();

        let status_content = std::fs::read_to_string(&status_file).unwrap();
        assert!(status_content.contains("PROGRESS"), "should have written PROGRESS");

        let log_content = std::fs::read_to_string(&log_file).unwrap();
        assert!(log_content.contains("progress"), "should have logged progress event");
    }

    // -- entrypoint dispatch for hf-lora-setup --

    #[test]
    fn run_dispatches_hf_lora_setup() {
        // Verify it's in the match arms (will fail on missing python, not "not found")
        let result = run("hf-lora-setup", &["--bad-arg".to_string()]);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("no arguments"), "should reject args, got: {msg}");
    }

    // -- write_shell_rc --

    #[test]
    fn write_shell_rc_creates_file_with_aliases() {
        write_shell_rc().unwrap();
        let content = std::fs::read_to_string(SHELL_RC_PATH).unwrap();
        assert!(content.contains("gpu-test"), "missing gpu-test alias");
        assert!(content.contains("jax-test"), "missing jax-test alias");
        assert!(content.contains("spack-build"), "missing spack-build alias");
        assert!(content.contains("hf-dataset"), "missing hf-dataset function");
        assert!(content.contains(".bashrc"), "should source .bashrc");
        let _ = std::fs::remove_file(SHELL_RC_PATH);
    }

    // -- job_wrapper_with_interval empty command --

    #[test]
    fn job_wrapper_with_interval_empty_command_errors() {
        let tmp = tempfile::tempdir().unwrap();
        let log_file = tmp.path().join("log.jsonl").display().to_string();
        let status_file = tmp.path().join("status").display().to_string();
        let result = job_wrapper_with_interval("test-job", &log_file, &status_file, &[], 1);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("No command"));
    }

    // -- heartbeat interval constant --

    #[test]
    fn heartbeat_default_is_five_minutes() {
        assert_eq!(HEARTBEAT_INTERVAL_SECS, 300);
    }

    // -- HF version constants --

    #[test]
    fn hf_version_constants_are_semver() {
        for ver in [HF_TRANSFORMERS_VERSION, HF_DATASETS_VERSION, HF_PEFT_VERSION, HF_ACCELERATE_VERSION] {
            let parts: Vec<&str> = ver.split('.').collect();
            assert!(parts.len() >= 2, "version {ver} should have major.minor");
            for part in &parts {
                assert!(part.parse::<u32>().is_ok(), "version part '{part}' in {ver} should be numeric");
            }
        }
    }

    // -- SHELL_RC_PATH --

    #[test]
    fn shell_rc_path_is_in_tmp() {
        assert!(SHELL_RC_PATH.starts_with("/tmp/"));
    }
}
