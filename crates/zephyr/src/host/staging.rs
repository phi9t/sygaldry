use crate::error::{Result, ZephyrError};
use crate::paths::container_paths;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Configuration for a staging run.
pub struct StageConfig {
    pub source_yaml: PathBuf,
    pub run_root: PathBuf,
    pub specs: Vec<String>,
    pub python_imports: Vec<String>,
    pub forbidden_names: Vec<String>,
    pub allow_deprecated: bool,
    pub gpu_verify: bool,
    pub verbose: bool,
    pub sygaldry_home: PathBuf,
}

/// Paths computed for a staging run.
struct StagePaths {
    src_env_dir: PathBuf,
    analyze_root: PathBuf,
    log_dir: PathBuf,
    analyze_report: PathBuf,
    new_req_txt: PathBuf,
    final_status: PathBuf,
    install_log: PathBuf,
    verify_zephyr_log: PathBuf,
    verify_gpu_log: PathBuf,
    verify_imports_log: PathBuf,
}

impl StagePaths {
    fn from_run_root(run_root: &Path) -> Self {
        let log_dir = run_root.join("logs");
        Self {
            src_env_dir: run_root.join("source_env"),
            analyze_root: run_root.join("analyze_stage"),
            log_dir: log_dir.clone(),
            analyze_report: log_dir.join("concretize_report.json"),
            new_req_txt: log_dir.join("new_requirements.txt"),
            final_status: log_dir.join("final_status.json"),
            install_log: log_dir.join("install.log"),
            verify_zephyr_log: log_dir.join("verify_pkg_zephyr.log"),
            verify_gpu_log: log_dir.join("verify_gpu.log"),
            verify_imports_log: log_dir.join("verify_imports.log"),
        }
    }
}

/// Result status for final_status.json.
#[derive(serde::Serialize)]
struct FinalStatus {
    run_root: String,
    source_yaml: String,
    specs_csv: String,
    forbidden_names_csv: String,
    stage_env: String,
    analyze_report: String,
    new_requirements: String,
    install_log: String,
    verify_pkg_zephyr_log: String,
    verify_gpu_log: String,
    verify_imports_log: String,
    status: String,
    failed_step: String,
    failure_message: String,
}

/// Exit codes matching the bash tool.
const EXIT_ANALYZE_FAILED: i32 = 2;
const EXIT_NEW_REQ_FAILED: i32 = 3;
const EXIT_FORBIDDEN: i32 = 10;
const EXIT_INSTALL_FAILED: i32 = 11;
const EXIT_VIEW_REGEN_FAILED: i32 = 12;
const EXIT_VERIFY_ZEPHYR_FAILED: i32 = 13;
const EXIT_VERIFY_GPU_FAILED: i32 = 14;
const EXIT_VERIFY_IMPORTS_FAILED: i32 = 15;

/// Execute the full staging pipeline.
pub fn run_stage(config: &StageConfig) -> Result<()> {
    let paths = StagePaths::from_run_root(&config.run_root);

    // Setup directories
    std::fs::create_dir_all(&paths.src_env_dir)?;
    std::fs::create_dir_all(&paths.log_dir)?;

    // Copy source manifest
    if !config.source_yaml.exists() {
        return Err(ZephyrError::with_hint(
            format!("Source YAML not found: {}", config.source_yaml.display()),
            "Check --source-yaml path.",
        ));
    }
    std::fs::copy(&config.source_yaml, paths.src_env_dir.join("spack.yaml"))?;

    // Initialize Spack
    init_spack_for_staging()?;

    let specs_csv = config.specs.join(",");
    let forbidden_csv = config.forbidden_names.join(",");

    // Step 1: Concretization analysis
    let analyze_tool = config.sygaldry_home.join("tools/zephyr_concretize_analyze.sh");
    if !analyze_tool.exists() {
        return Err(ZephyrError::with_hint(
            format!("Analyze tool not found: {}", analyze_tool.display()),
            "Ensure SYGALDRY_HOME is set correctly.",
        ));
    }

    let mut analyze_args: Vec<String> = vec![
        "--source-env-dir".into(), paths.src_env_dir.display().to_string(),
        "--stage-root".into(), paths.analyze_root.display().to_string(),
        "--output-json".into(), paths.analyze_report.display().to_string(),
        "--keep-stage".into(),
    ];
    if config.verbose {
        analyze_args.push("--verbose".into());
    }
    if config.allow_deprecated {
        analyze_args.push("--allow-deprecated".into());
    } else {
        analyze_args.push("--no-allow-deprecated".into());
    }
    for spec in &config.specs {
        analyze_args.push("--spec".into());
        analyze_args.push(spec.clone());
    }

    run_step(
        &analyze_tool.display().to_string(),
        &analyze_args,
        "analyze",
        EXIT_ANALYZE_FAILED,
        &paths,
        config,
        &specs_csv,
        &forbidden_csv,
        "",
    )?;

    // Extract stage_env from analysis report
    let stage_env = extract_stage_dir(&paths.analyze_report)?;

    // Step 2: Generate new requirements list
    generate_new_requirements(&paths.analyze_report, &paths.new_req_txt).map_err(|e| {
        write_final_status(&paths, config, &specs_csv, &forbidden_csv, &stage_env, "failed", "new_requirements", &e.to_string());
        ZephyrError::CommandFailed { command: "generate new requirements".into(), code: EXIT_NEW_REQ_FAILED }
    })?;

    // Step 3: Check forbidden guard
    check_forbidden_guard(&paths.analyze_report, &config.forbidden_names, config.verbose).map_err(|e| {
        write_final_status(&paths, config, &specs_csv, &forbidden_csv, &stage_env, "failed", "core_guard", &e.to_string());
        ZephyrError::CommandFailed { command: "forbidden guard check".into(), code: EXIT_FORBIDDEN }
    })?;

    // Step 4: Install
    run_spack_cmd(
        &["install"],
        &stage_env,
        &paths.install_log,
        "install",
        EXIT_INSTALL_FAILED,
        &paths,
        config,
        &specs_csv,
        &forbidden_csv,
    )?;

    // Step 5: Regenerate view
    run_spack_cmd(
        &["env", "view", "regenerate"],
        &stage_env,
        &paths.install_log,
        "view_regenerate",
        EXIT_VIEW_REGEN_FAILED,
        &paths,
        config,
        &specs_csv,
        &forbidden_csv,
    )?;

    // Step 6: GPU verification
    if config.gpu_verify {
        let verify_script = config.sygaldry_home.join("pkg/zephyr/verify.sh");
        if verify_script.exists() {
            let status = Command::new(&verify_script)
                .arg("--require-gpu")
                .current_dir(&stage_env)
                .output();
            if let Ok(output) = &status {
                let _ = std::fs::write(&paths.verify_zephyr_log, &output.stdout);
                if !output.status.success() {
                    write_final_status(&paths, config, &specs_csv, &forbidden_csv, &stage_env, "failed", "verify_pkg_zephyr", "pkg/zephyr/verify.sh failed");
                    return Err(ZephyrError::CommandFailed { command: "verify.sh".into(), code: EXIT_VERIFY_ZEPHYR_FAILED });
                }
            }
        }

        let gpu_script = config.sygaldry_home.join("container/entrypoints/verify-gpu.sh");
        if gpu_script.exists() {
            let status = Command::new(&gpu_script)
                .env("SYGALDRY_SPACK_ENV", &stage_env)
                .output();
            if let Ok(output) = &status {
                let _ = std::fs::write(&paths.verify_gpu_log, &output.stdout);
                if !output.status.success() {
                    write_final_status(&paths, config, &specs_csv, &forbidden_csv, &stage_env, "failed", "verify_gpu", "verify-gpu.sh failed");
                    return Err(ZephyrError::CommandFailed { command: "verify-gpu.sh".into(), code: EXIT_VERIFY_GPU_FAILED });
                }
            }
        }
    }

    // Step 7: Python import verification
    if !config.python_imports.is_empty() {
        let imports_csv = config.python_imports.join(",");
        let verify_script = format!(
            r#"import importlib, os
mods = [m for m in os.environ.get('PYTHON_IMPORTS_CSV', '').split(',') if m]
for m in mods:
    mod = importlib.import_module(m)
    print(m, getattr(mod, '__version__', 'unknown'))
"#
        );
        let output = Command::new("bash")
            .args(["-lc", &format!(
                "eval \"$(spack -e {stage_env} env activate --sh)\"; python3 -c '{verify_script}'"
            )])
            .env("PYTHON_IMPORTS_CSV", &imports_csv)
            .output();
        if let Ok(out) = &output {
            let _ = std::fs::write(&paths.verify_imports_log, &out.stdout);
            if !out.status.success() {
                write_final_status(&paths, config, &specs_csv, &forbidden_csv, &stage_env, "failed", "verify_imports", "Python import verification failed");
                return Err(ZephyrError::CommandFailed { command: "verify imports".into(), code: EXIT_VERIFY_IMPORTS_FAILED });
            }
        }
    }

    // Success
    write_final_status(&paths, config, &specs_csv, &forbidden_csv, &stage_env, "ok", "", "");

    println!("RUN_ROOT={}", config.run_root.display());
    println!("STAGE_ENV={stage_env}");
    println!("ANALYZE_REPORT={}", paths.analyze_report.display());
    println!("NEW_REQUIREMENTS={}", paths.new_req_txt.display());
    println!("FINAL_STATUS={}", paths.final_status.display());

    Ok(())
}

fn init_spack_for_staging() -> Result<()> {
    let setup = Path::new(container_paths::SPACK_SRC).join("share/spack/setup-env.sh");
    if setup.exists() {
        // Add spack bin to PATH
        let spack_bin = format!("{}/bin", container_paths::SPACK_SRC);
        if let Ok(path) = std::env::var("PATH") {
            if !path.contains(&spack_bin) {
                std::env::set_var("PATH", format!("{spack_bin}:{path}"));
            }
        }
        Ok(())
    } else if which::which("spack").is_ok() {
        eprintln!("WARNING: {}/share/spack/setup-env.sh missing; using spack from PATH", container_paths::SPACK_SRC);
        Ok(())
    } else {
        Err(ZephyrError::with_hint(
            "Spack not found",
            "Ensure you're inside the container with Spack available.",
        ))
    }
}

fn extract_stage_dir(report_path: &Path) -> Result<String> {
    let content = std::fs::read_to_string(report_path)?;
    let report: serde_json::Value = serde_json::from_str(&content).map_err(|e| {
        ZephyrError::with_hint(
            format!("Failed to parse analyze report: {e}"),
            "Check concretize_report.json for valid JSON.",
        )
    })?;
    report["stage_dir"]
        .as_str()
        .map(String::from)
        .ok_or_else(|| ZephyrError::with_hint(
            "Missing stage_dir in analyze report",
            "The concretization analysis may have failed.",
        ))
}

fn generate_new_requirements(report_path: &Path, output_path: &Path) -> Result<()> {
    let content = std::fs::read_to_string(report_path)?;
    let report: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| ZephyrError::with_hint(format!("JSON parse error: {e}"), "Check report file"))?;
    let mut lines = Vec::new();
    if let Some(missing) = report["missing"].as_array() {
        for item in missing {
            let name = item["name"].as_str().unwrap_or("");
            let version = item["version"].as_str().unwrap_or("");
            let hash = item["hash"].as_str().unwrap_or("");
            lines.push(format!("- {name}@{version} /{hash}"));
        }
    }
    std::fs::write(output_path, lines.join("\n"))?;
    Ok(())
}

fn check_forbidden_guard(report_path: &Path, forbidden_names: &[String], verbose: bool) -> Result<()> {
    let content = std::fs::read_to_string(report_path)?;
    let report: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| ZephyrError::with_hint(format!("JSON parse error: {e}"), "Check report file"))?;

    let forbidden_set: std::collections::HashSet<&str> = forbidden_names.iter().map(|s| s.as_str()).collect();

    let missing = report["missing"].as_array().unwrap_or(&Vec::new()).clone();
    let forbidden_missing: Vec<_> = missing
        .iter()
        .filter(|m| {
            m["name"].as_str().map_or(false, |n| forbidden_set.contains(n))
        })
        .collect();

    if verbose {
        println!("REPORT={}", report_path.display());
        println!("TOTAL_MISSING={}", missing.len());
        println!("FORBIDDEN_MISSING={}", forbidden_missing.len());
    }

    if !forbidden_missing.is_empty() {
        eprintln!("Forbidden missing specs detected:");
        for m in &forbidden_missing {
            let name = m["name"].as_str().unwrap_or("");
            let version = m["version"].as_str().unwrap_or("");
            let hash = m["hash"].as_str().unwrap_or("");
            eprintln!("  - {name}@{version} /{hash}");
        }
        return Err(ZephyrError::with_hint(
            format!("{} forbidden packages found in missing set", forbidden_missing.len()),
            "These core packages must come from the existing Spack store.",
        ));
    }

    Ok(())
}

fn run_step(
    program: &str,
    args: &[String],
    step_name: &str,
    exit_code: i32,
    paths: &StagePaths,
    config: &StageConfig,
    specs_csv: &str,
    forbidden_csv: &str,
    stage_env: &str,
) -> Result<()> {
    let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    let status = Command::new(program).args(&arg_refs).status()?;
    if !status.success() {
        let msg = format!("{step_name} failed");
        write_final_status(paths, config, specs_csv, forbidden_csv, stage_env, "failed", step_name, &msg);
        return Err(ZephyrError::CommandFailed { command: step_name.into(), code: exit_code });
    }
    Ok(())
}

fn run_spack_cmd(
    spack_args: &[&str],
    stage_env: &str,
    log_file: &Path,
    step_name: &str,
    exit_code: i32,
    paths: &StagePaths,
    config: &StageConfig,
    specs_csv: &str,
    forbidden_csv: &str,
) -> Result<()> {
    let mut args = vec!["-e", stage_env];
    args.extend(spack_args);
    let output = Command::new("spack").args(&args).output()?;

    // Append to log file
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_file)?;
    file.write_all(&output.stdout)?;
    file.write_all(&output.stderr)?;

    if !output.status.success() {
        let msg = format!("{step_name} failed");
        write_final_status(paths, config, specs_csv, forbidden_csv, stage_env, "failed", step_name, &msg);
        return Err(ZephyrError::CommandFailed { command: step_name.into(), code: exit_code });
    }
    Ok(())
}

fn write_final_status(
    paths: &StagePaths,
    config: &StageConfig,
    specs_csv: &str,
    forbidden_csv: &str,
    stage_env: &str,
    status: &str,
    failed_step: &str,
    failure_message: &str,
) {
    let payload = FinalStatus {
        run_root: config.run_root.display().to_string(),
        source_yaml: config.source_yaml.display().to_string(),
        specs_csv: specs_csv.to_string(),
        forbidden_names_csv: forbidden_csv.to_string(),
        stage_env: stage_env.to_string(),
        analyze_report: paths.analyze_report.display().to_string(),
        new_requirements: paths.new_req_txt.display().to_string(),
        install_log: paths.install_log.display().to_string(),
        verify_pkg_zephyr_log: paths.verify_zephyr_log.display().to_string(),
        verify_gpu_log: paths.verify_gpu_log.display().to_string(),
        verify_imports_log: paths.verify_imports_log.display().to_string(),
        status: status.to_string(),
        failed_step: failed_step.to_string(),
        failure_message: failure_message.to_string(),
    };
    if let Ok(json) = serde_json::to_string_pretty(&payload) {
        let _ = std::fs::write(&paths.final_status, format!("{json}\n"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stage_paths_from_run_root() {
        let paths = StagePaths::from_run_root(Path::new("/tmp/stage/run-1"));
        assert_eq!(paths.src_env_dir, PathBuf::from("/tmp/stage/run-1/source_env"));
        assert_eq!(paths.analyze_root, PathBuf::from("/tmp/stage/run-1/analyze_stage"));
        assert_eq!(paths.log_dir, PathBuf::from("/tmp/stage/run-1/logs"));
        assert_eq!(paths.analyze_report, PathBuf::from("/tmp/stage/run-1/logs/concretize_report.json"));
        assert_eq!(paths.final_status, PathBuf::from("/tmp/stage/run-1/logs/final_status.json"));
    }

    #[test]
    fn generate_new_requirements_from_report() {
        let tmp = tempfile::tempdir().unwrap();
        let report_path = tmp.path().join("report.json");
        let output_path = tmp.path().join("requirements.txt");

        let report = serde_json::json!({
            "stage_dir": "/tmp/stage",
            "missing": [
                {"name": "py-soundfile", "version": "0.10.3", "hash": "abc123"},
                {"name": "sox", "version": "14.4.2", "hash": "def456"},
            ]
        });
        std::fs::write(&report_path, serde_json::to_string(&report).unwrap()).unwrap();

        generate_new_requirements(&report_path, &output_path).unwrap();
        let content = std::fs::read_to_string(&output_path).unwrap();
        assert!(content.contains("py-soundfile@0.10.3"));
        assert!(content.contains("sox@14.4.2"));
    }

    #[test]
    fn check_forbidden_guard_passes_with_no_forbidden() {
        let tmp = tempfile::tempdir().unwrap();
        let report_path = tmp.path().join("report.json");

        let report = serde_json::json!({
            "stage_dir": "/tmp/stage",
            "missing": [
                {"name": "py-soundfile", "version": "0.10.3", "hash": "abc123"},
            ]
        });
        std::fs::write(&report_path, serde_json::to_string(&report).unwrap()).unwrap();

        let forbidden = vec!["py-torch".to_string(), "py-jax".to_string()];
        let result = check_forbidden_guard(&report_path, &forbidden, false);
        assert!(result.is_ok());
    }

    #[test]
    fn check_forbidden_guard_fails_with_forbidden_match() {
        let tmp = tempfile::tempdir().unwrap();
        let report_path = tmp.path().join("report.json");

        let report = serde_json::json!({
            "stage_dir": "/tmp/stage",
            "missing": [
                {"name": "py-torch", "version": "2.9.0", "hash": "bad123"},
                {"name": "py-soundfile", "version": "0.10.3", "hash": "abc123"},
            ]
        });
        std::fs::write(&report_path, serde_json::to_string(&report).unwrap()).unwrap();

        let forbidden = vec!["py-torch".to_string(), "py-jax".to_string()];
        let result = check_forbidden_guard(&report_path, &forbidden, false);
        assert!(result.is_err());
    }

    #[test]
    fn extract_stage_dir_from_report() {
        let tmp = tempfile::tempdir().unwrap();
        let report_path = tmp.path().join("report.json");

        let report = serde_json::json!({
            "stage_dir": "/tmp/stage/run-abc123",
            "missing": []
        });
        std::fs::write(&report_path, serde_json::to_string(&report).unwrap()).unwrap();

        let stage_dir = extract_stage_dir(&report_path).unwrap();
        assert_eq!(stage_dir, "/tmp/stage/run-abc123");
    }

    #[test]
    fn extract_stage_dir_fails_missing_key() {
        let tmp = tempfile::tempdir().unwrap();
        let report_path = tmp.path().join("report.json");
        std::fs::write(&report_path, r#"{"missing": []}"#).unwrap();

        let result = extract_stage_dir(&report_path);
        assert!(result.is_err());
    }

    #[test]
    fn write_final_status_creates_json() {
        let tmp = tempfile::tempdir().unwrap();
        let paths = StagePaths::from_run_root(tmp.path());
        std::fs::create_dir_all(&paths.log_dir).unwrap();

        let config = StageConfig {
            source_yaml: PathBuf::from("/tmp/test.yaml"),
            run_root: tmp.path().to_path_buf(),
            specs: vec![],
            python_imports: vec![],
            forbidden_names: vec![],
            allow_deprecated: true,
            gpu_verify: true,
            verbose: false,
            sygaldry_home: PathBuf::from("/opt/sygaldry"),
        };

        write_final_status(&paths, &config, "", "", "", "ok", "", "");

        let content = std::fs::read_to_string(&paths.final_status).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        assert_eq!(parsed["status"], "ok");
        assert_eq!(parsed["failed_step"], "");
    }

    #[test]
    fn write_final_status_records_failure() {
        let tmp = tempfile::tempdir().unwrap();
        let paths = StagePaths::from_run_root(tmp.path());
        std::fs::create_dir_all(&paths.log_dir).unwrap();

        let config = StageConfig {
            source_yaml: PathBuf::from("/tmp/test.yaml"),
            run_root: tmp.path().to_path_buf(),
            specs: vec![],
            python_imports: vec![],
            forbidden_names: vec![],
            allow_deprecated: true,
            gpu_verify: true,
            verbose: false,
            sygaldry_home: PathBuf::from("/opt/sygaldry"),
        };

        write_final_status(&paths, &config, "py-soundfile", "py-torch,py-jax", "/tmp/stage", "failed", "core_guard", "forbidden packages found");

        let content = std::fs::read_to_string(&paths.final_status).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        assert_eq!(parsed["status"], "failed");
        assert_eq!(parsed["failed_step"], "core_guard");
        assert!(parsed["failure_message"].as_str().unwrap().contains("forbidden"));
    }

    #[test]
    fn run_stage_fails_on_missing_source_yaml() {
        let tmp = tempfile::tempdir().unwrap();
        let config = StageConfig {
            source_yaml: PathBuf::from("/nonexistent/spack_src.yaml"),
            run_root: tmp.path().join("run-test"),
            specs: vec![],
            python_imports: vec![],
            forbidden_names: vec![],
            allow_deprecated: true,
            gpu_verify: false,
            verbose: false,
            sygaldry_home: PathBuf::from("/opt/sygaldry"),
        };
        let result = run_stage(&config);
        assert!(result.is_err());
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("Source YAML not found"));
    }

    // -- init_spack_for_staging --

    #[test]
    fn init_spack_for_staging_returns_result() {
        // Outside container: SPACK_SRC doesn't exist, should fallback or error
        let result = init_spack_for_staging();
        match result {
            Ok(()) => {} // spack is in PATH
            Err(e) => {
                let msg = format!("{e}");
                assert!(msg.contains("Spack not found"), "unexpected: {msg}");
            }
        }
    }

    // -- StagePaths completeness --

    #[test]
    fn stage_paths_all_under_run_root() {
        let run_root = Path::new("/tmp/stage/run-42");
        let paths = StagePaths::from_run_root(run_root);
        let run_root_str = run_root.display().to_string();
        assert!(paths.src_env_dir.display().to_string().starts_with(&run_root_str));
        assert!(paths.analyze_root.display().to_string().starts_with(&run_root_str));
        assert!(paths.log_dir.display().to_string().starts_with(&run_root_str));
        assert!(paths.analyze_report.display().to_string().starts_with(&run_root_str));
        assert!(paths.new_req_txt.display().to_string().starts_with(&run_root_str));
        assert!(paths.final_status.display().to_string().starts_with(&run_root_str));
        assert!(paths.install_log.display().to_string().starts_with(&run_root_str));
        assert!(paths.verify_zephyr_log.display().to_string().starts_with(&run_root_str));
        assert!(paths.verify_gpu_log.display().to_string().starts_with(&run_root_str));
        assert!(paths.verify_imports_log.display().to_string().starts_with(&run_root_str));
    }

    // -- exit codes --

    #[test]
    fn exit_codes_are_distinct() {
        let codes = [
            EXIT_ANALYZE_FAILED,
            EXIT_NEW_REQ_FAILED,
            EXIT_FORBIDDEN,
            EXIT_INSTALL_FAILED,
            EXIT_VIEW_REGEN_FAILED,
            EXIT_VERIFY_ZEPHYR_FAILED,
            EXIT_VERIFY_GPU_FAILED,
            EXIT_VERIFY_IMPORTS_FAILED,
        ];
        let mut seen = std::collections::HashSet::new();
        for code in &codes {
            assert!(seen.insert(code), "duplicate exit code: {code}");
        }
    }

    #[test]
    fn exit_codes_are_in_expected_range() {
        // Codes 2-15 per the design
        let codes = [
            EXIT_ANALYZE_FAILED,
            EXIT_NEW_REQ_FAILED,
            EXIT_FORBIDDEN,
            EXIT_INSTALL_FAILED,
            EXIT_VIEW_REGEN_FAILED,
            EXIT_VERIFY_ZEPHYR_FAILED,
            EXIT_VERIFY_GPU_FAILED,
            EXIT_VERIFY_IMPORTS_FAILED,
        ];
        for code in &codes {
            assert!(*code >= 2 && *code <= 15, "exit code {code} outside range 2-15");
        }
    }

    // -- generate_new_requirements empty --

    #[test]
    fn generate_new_requirements_empty_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let report_path = tmp.path().join("report.json");
        let output_path = tmp.path().join("requirements.txt");

        let report = serde_json::json!({
            "stage_dir": "/tmp/stage",
            "missing": []
        });
        std::fs::write(&report_path, serde_json::to_string(&report).unwrap()).unwrap();

        generate_new_requirements(&report_path, &output_path).unwrap();
        let content = std::fs::read_to_string(&output_path).unwrap();
        assert!(content.is_empty());
    }

    // -- check_forbidden_guard verbose --

    #[test]
    fn check_forbidden_guard_verbose_output() {
        let tmp = tempfile::tempdir().unwrap();
        let report_path = tmp.path().join("report.json");

        let report = serde_json::json!({
            "stage_dir": "/tmp/stage",
            "missing": [
                {"name": "py-soundfile", "version": "0.10.3", "hash": "abc123"},
            ]
        });
        std::fs::write(&report_path, serde_json::to_string(&report).unwrap()).unwrap();

        // verbose=true, no forbidden matches → Ok
        let result = check_forbidden_guard(&report_path, &["py-torch".to_string()], true);
        assert!(result.is_ok());
    }

    // -- extract_stage_dir bad json --

    #[test]
    fn extract_stage_dir_fails_on_invalid_json() {
        let tmp = tempfile::tempdir().unwrap();
        let report_path = tmp.path().join("report.json");
        std::fs::write(&report_path, "not valid json").unwrap();

        let result = extract_stage_dir(&report_path);
        assert!(result.is_err());
    }
}
