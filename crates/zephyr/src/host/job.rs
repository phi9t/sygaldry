use crate::cli::JobAction;
use crate::config::{CliOverrides, ZephyrConfig};
use crate::error::{Result, ZephyrError};
use std::path::Path;

fn resolve_run_id(projects_root: &Path, project_id: &str, job_name: &str, explicit: &Option<String>) -> Result<String> {
    if let Some(id) = explicit {
        return Ok(id.clone());
    }
    let latest = projects_root
        .join(project_id)
        .join("runs")
        .join(format!("latest-{job_name}"));
    let target = std::fs::read_link(&latest)
        .map_err(|_| ZephyrError::JobNotFound {
            project_id: project_id.to_string(),
            job_name: job_name.to_string(),
        })?;
    target
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .ok_or_else(|| ZephyrError::JobNotFound {
            project_id: project_id.to_string(),
            job_name: job_name.to_string(),
        })
}

/// Dispatch a job subcommand.
pub fn dispatch_job(action: &JobAction, projects_root: &Path) -> Result<()> {
    match action {
        JobAction::Run {
            project_id,
            job,
            run_id,
            command,
        } => run_job(projects_root, project_id, job, run_id.as_deref(), command),

        JobAction::Status {
            project_id,
            job,
            run_id,
        } => show_status(projects_root, project_id, job, run_id),

        JobAction::Tail {
            project_id,
            job,
            run_id,
            lines,
        } => tail_logs(projects_root, project_id, job, run_id, *lines),

        JobAction::Stop { project_id, job } => stop_job(projects_root, project_id, job),

        JobAction::Health {
            project_id,
            job,
            run_id,
        } => show_health(projects_root, project_id, job, run_id),
    }
}

fn run_job(projects_root: &Path, project_id: &str, job_name: &str, run_id: Option<&str>, command: &[String]) -> Result<()> {
    if command.is_empty() {
        return Err(ZephyrError::with_hint(
            "Missing command after --",
            "Usage: zephyr job run --project-id <id> --job <name> -- <command>",
        ));
    }

    let run_id = run_id
        .map(String::from)
        .unwrap_or_else(|| {
            format!(
                "run-{}-{}",
                chrono::Local::now().format("%Y%m%d-%H%M%S"),
                std::process::id()
            )
        });

    let project_path = projects_root.join(project_id);
    let raw_log_dir = project_path.join("runs").join(&run_id).join("raw");
    let metadata_dir = project_path.join("outputs/.run-metadata").join(&run_id);

    std::fs::create_dir_all(&raw_log_dir)?;
    std::fs::create_dir_all(&metadata_dir)?;
    std::fs::create_dir_all(project_path.join("runs"))?;

    let ts = chrono::Local::now().format("%Y%m%d-%H%M%S");
    let raw_log_file = raw_log_dir.join(format!("{job_name}-{ts}.log"));
    let jsonl_file = metadata_dir.join(format!("{job_name}-{ts}.jsonl"));
    let status_file = metadata_dir.join(format!("{job_name}.status"));

    let log_handle = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&raw_log_file)?;
    let log_handle_stderr = log_handle.try_clone()?;

    // Build docker args using the Rust infrastructure (self-contained, no bash delegation)
    let overrides = CliOverrides {
        project_id: Some(project_id.to_string()),
        run_id: Some(run_id.clone()),
        ..Default::default()
    };
    let config = ZephyrConfig::from_env(&overrides);

    let spack_baked = super::image::read_image_label(&config.image, "sygaldry.spack.baked")
        .as_deref()
        == Some("true");

    let entrypoint_container_dir = if spack_baked {
        Some(crate::paths::container_paths::SPACK_BAKED_ENTRYPOINT_DIR.to_string())
    } else {
        None
    };

    let docker_args = super::docker_args::build(
        &config,
        "run-job",
        spack_baked,
        entrypoint_container_dir.as_deref(),
    )?;

    // Container-side paths for JSONL and status files (mapped through output volume)
    let container_jsonl = format!(
        "{}/{job_name}-{ts}.jsonl",
        crate::paths::container_paths::OUTPUT_ROOT.trim_end_matches('/').to_string()
            + "/.run-metadata/" + &run_id
    );
    let container_status = format!(
        "{}/{job_name}.status",
        crate::paths::container_paths::OUTPUT_ROOT.trim_end_matches('/').to_string()
            + "/.run-metadata/" + &run_id
    );

    // Build the wrapper command: zephyr job-wrapper --name <name> --log-file <path> --status-file <path> -- <command>
    let mut cmd_args = docker_args;
    cmd_args.push(config.image.clone());
    cmd_args.extend([
        "zephyr".to_string(),
        "job-wrapper".to_string(),
        "--name".to_string(),
        job_name.to_string(),
        "--log-file".to_string(),
        container_jsonl,
        "--status-file".to_string(),
        container_status,
        "--".to_string(),
    ]);
    cmd_args.extend(command.iter().cloned());

    let child = std::process::Command::new("nohup")
        .arg("docker")
        .arg("run")
        .args(&cmd_args)
        .stdout(log_handle)
        .stderr(log_handle_stderr)
        .spawn()?;

    let pid = child.id();
    let pid_file = project_path.join("runs").join(format!("{job_name}.pid"));
    std::fs::write(&pid_file, pid.to_string())?;

    // Create latest-<job> symlink
    let latest_link = project_path.join("runs").join(format!("latest-{job_name}"));
    let _ = std::fs::remove_file(&latest_link);
    std::os::unix::fs::symlink(
        project_path.join("runs").join(&run_id),
        &latest_link,
    )?;

    println!("Started job: {job_name}");
    println!("Project ID:  {project_id}");
    println!("Run ID:      {run_id}");
    println!("PID:         {pid}");
    println!("JSONL:       {}", jsonl_file.display());
    println!("Raw log:     {}", raw_log_file.display());
    println!("Status file: {}", status_file.display());

    Ok(())
}

fn show_status(projects_root: &Path, project_id: &str, job_name: &str, run_id: &Option<String>) -> Result<()> {
    let run_id = resolve_run_id(projects_root, project_id, job_name, run_id)?;
    let status_file = projects_root
        .join(project_id)
        .join("outputs/.run-metadata")
        .join(&run_id)
        .join(format!("{job_name}.status"));

    if !status_file.exists() {
        return Err(ZephyrError::with_hint(
            format!("Status file not found: {}", status_file.display()),
            "Has the job been started?",
        ));
    }

    let content = std::fs::read_to_string(&status_file)?;
    if let Some(last_line) = content.lines().last() {
        println!("{last_line}");
    }
    Ok(())
}

fn tail_logs(projects_root: &Path, project_id: &str, job_name: &str, run_id: &Option<String>, lines: usize) -> Result<()> {
    let run_id = resolve_run_id(projects_root, project_id, job_name, run_id)?;
    let metadata_dir = projects_root
        .join(project_id)
        .join("outputs/.run-metadata")
        .join(&run_id);

    // Find the most recent JSONL file for this job
    let pattern = format!("{job_name}-");
    let mut candidates: Vec<_> = std::fs::read_dir(&metadata_dir)?
        .filter_map(|e| e.ok())
        .filter(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            name.starts_with(&pattern) && name.ends_with(".jsonl")
        })
        .collect();
    candidates.sort_by_key(|e| std::cmp::Reverse(e.file_name()));

    let log_file = candidates
        .first()
        .map(|e| e.path())
        .ok_or_else(|| ZephyrError::JobNotFound {
            project_id: project_id.to_string(),
            job_name: job_name.to_string(),
        })?;

    let content = std::fs::read_to_string(&log_file)?;
    let all_lines: Vec<&str> = content.lines().collect();
    let start = all_lines.len().saturating_sub(lines);
    for line in &all_lines[start..] {
        println!("{line}");
    }
    Ok(())
}

fn stop_job(projects_root: &Path, project_id: &str, job_name: &str) -> Result<()> {
    let pid_file = projects_root
        .join(project_id)
        .join("runs")
        .join(format!("{job_name}.pid"));

    if !pid_file.exists() {
        return Err(ZephyrError::with_hint(
            "PID file not found",
            "Is the job running?",
        ));
    }

    let pid_str = std::fs::read_to_string(&pid_file)?;
    let pid = parse_pid(&pid_str)
        .ok_or_else(|| ZephyrError::with_hint("Invalid PID file", "Delete the PID file and retry"))?;

    let result = unsafe { libc::kill(pid, libc::SIGTERM) };
    if result == 0 {
        println!("Stopped PID {pid}");
        Ok(())
    } else {
        Err(ZephyrError::with_hint(
            format!("PID {pid} not running"),
            "The job may have already finished.",
        ))
    }
}

/// Parse a PID from a PID file's contents.
pub(crate) fn parse_pid(content: &str) -> Option<i32> {
    content.trim().parse().ok()
}

fn show_health(projects_root: &Path, project_id: &str, job_name: &str, run_id: &Option<String>) -> Result<()> {
    let pid_file = projects_root
        .join(project_id)
        .join("runs")
        .join(format!("{job_name}.pid"));

    if pid_file.exists() {
        let pid_str = std::fs::read_to_string(&pid_file)?;
        if let Some(pid) = parse_pid(&pid_str) {
            let alive = unsafe { libc::kill(pid, 0) } == 0;
            if alive {
                println!("running pid={pid}");
            } else {
                println!("stale pid={pid}");
            }
        }
    } else {
        println!("pid=unknown");
    }

    match resolve_run_id(projects_root, project_id, job_name, run_id) {
        Ok(rid) => {
            let status_file = projects_root
                .join(project_id)
                .join("outputs/.run-metadata")
                .join(&rid)
                .join(format!("{job_name}.status"));
            if status_file.exists() {
                let content = std::fs::read_to_string(&status_file)?;
                if let Some(last_line) = content.lines().last() {
                    println!("{last_line}");
                }
            } else {
                println!("status=missing");
            }
        }
        Err(_) => {
            println!("status=missing");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- parse_pid --

    #[test]
    fn parse_pid_valid() {
        assert_eq!(parse_pid("12345"), Some(12345));
        assert_eq!(parse_pid("  42  \n"), Some(42));
    }

    #[test]
    fn parse_pid_invalid() {
        assert_eq!(parse_pid("not-a-pid"), None);
        assert_eq!(parse_pid(""), None);
    }

    // -- resolve_run_id --

    #[test]
    fn resolve_run_id_explicit() {
        let tmp = tempfile::tempdir().unwrap();
        let result = resolve_run_id(tmp.path(), "proj", "train", &Some("my-run-id".into()));
        assert_eq!(result.unwrap(), "my-run-id");
    }

    #[test]
    fn resolve_run_id_from_symlink() {
        let tmp = tempfile::tempdir().unwrap();
        let runs_dir = tmp.path().join(".").join("runs");
        std::fs::create_dir_all(&runs_dir).unwrap();
        let target_dir = runs_dir.join("run-20260101-120000-42");
        std::fs::create_dir_all(&target_dir).unwrap();
        let latest = runs_dir.join("latest-train");
        std::os::unix::fs::symlink(&target_dir, &latest).unwrap();

        let result = resolve_run_id(tmp.path(), ".", "train", &None);
        assert!(result.is_ok());
        assert!(result.unwrap().contains("run-20260101-120000-42"));
    }

    #[test]
    fn resolve_run_id_missing_symlink() {
        let tmp = tempfile::tempdir().unwrap();
        let result = resolve_run_id(tmp.path(), "nonexistent-proj", "train", &None);
        assert!(result.is_err());
    }

    // -- show_status --

    #[test]
    fn show_status_missing_file() {
        let tmp = tempfile::tempdir().unwrap();
        let result = show_status(tmp.path(), "proj", "train", &Some("run-test".into()));
        assert!(result.is_err());
    }

    #[test]
    fn show_status_reads_last_line() {
        let tmp = tempfile::tempdir().unwrap();
        let status_dir = tmp
            .path()
            .join("proj")
            .join("outputs/.run-metadata")
            .join("run-1");
        std::fs::create_dir_all(&status_dir).unwrap();
        std::fs::write(
            status_dir.join("train.status"),
            "START ts=2025-01-01\nDONE ts=2025-01-02 rc=0\n",
        )
        .unwrap();

        let result = show_status(tmp.path(), "proj", "train", &Some("run-1".into()));
        assert!(result.is_ok());
    }

    // -- tail_logs --

    #[test]
    fn tail_logs_returns_last_n_lines() {
        let tmp = tempfile::tempdir().unwrap();
        let metadata_dir = tmp
            .path()
            .join("proj")
            .join("outputs/.run-metadata")
            .join("run-1");
        std::fs::create_dir_all(&metadata_dir).unwrap();
        std::fs::write(
            metadata_dir.join("train-20260101.jsonl"),
            "line1\nline2\nline3\nline4\nline5\n",
        )
        .unwrap();

        let result = tail_logs(tmp.path(), "proj", "train", &Some("run-1".into()), 3);
        assert!(result.is_ok());
    }

    #[test]
    fn tail_logs_no_log_files() {
        let tmp = tempfile::tempdir().unwrap();
        let metadata_dir = tmp
            .path()
            .join("proj")
            .join("outputs/.run-metadata")
            .join("run-1");
        std::fs::create_dir_all(&metadata_dir).unwrap();

        let result = tail_logs(tmp.path(), "proj", "train", &Some("run-1".into()), 10);
        assert!(result.is_err());
    }

    // -- run_job validation --

    #[test]
    fn run_job_empty_command_errors() {
        let tmp = tempfile::tempdir().unwrap();
        let result = run_job(tmp.path(), "proj", "train", None, &[]);
        assert!(result.is_err());
    }

    // -- wrapper command construction --

    #[test]
    fn wrapper_command_structure() {
        // Verify the job-wrapper command format is correct
        let name = "train";
        let log_file = "/workspace/outputs/.run-metadata/run-1/train-20260101.jsonl";
        let status_file = "/workspace/outputs/.run-metadata/run-1/train.status";
        let command = vec!["python".to_string(), "train.py".to_string()];

        let mut wrapper_args = vec![
            "zephyr".to_string(),
            "job-wrapper".to_string(),
            "--name".to_string(),
            name.to_string(),
            "--log-file".to_string(),
            log_file.to_string(),
            "--status-file".to_string(),
            status_file.to_string(),
            "--".to_string(),
        ];
        wrapper_args.extend(command.iter().cloned());

        assert_eq!(wrapper_args[0], "zephyr");
        assert_eq!(wrapper_args[1], "job-wrapper");
        assert_eq!(wrapper_args[2], "--name");
        assert_eq!(wrapper_args[3], "train");
        assert_eq!(wrapper_args[8], "--");
        assert_eq!(wrapper_args[9], "python");
        assert_eq!(wrapper_args[10], "train.py");
    }

    // -- stop_job --

    #[test]
    fn stop_job_missing_pid_file() {
        let tmp = tempfile::tempdir().unwrap();
        let result = stop_job(tmp.path(), "proj", "train");
        assert!(result.is_err());
    }
}
