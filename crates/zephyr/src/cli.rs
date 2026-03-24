use clap::{Parser, Subcommand};

/// Sygaldry container infrastructure CLI.
///
/// Single binary for host-side container orchestration and in-container
/// environment initialization. Mode is auto-detected from SYGALDRY_IN_CONTAINER.
#[derive(Parser, Debug)]
#[command(name = "zephyr", version, about)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Enable multi-repo mode: mount an external repo into the container.
    #[arg(long, global = true)]
    pub repo: Option<String>,

    /// Select container entrypoint (default: default).
    #[arg(long, short = 'e', global = true)]
    pub entrypoint: Option<String>,

    /// Run ID for tracing and lease management.
    #[arg(long, global = true)]
    pub run_id: Option<String>,

    /// Lease conflict resolution mode.
    #[arg(long, global = true)]
    pub lease_mode: Option<String>,

    /// Cache isolation profile.
    #[arg(long, global = true)]
    pub cache_profile: Option<String>,

    /// Print effective configuration and exit.
    #[arg(long, global = true)]
    pub print_effective_config: bool,

    /// Arguments passed through to the container command (after --).
    #[arg(last = true)]
    pub passthrough: Vec<String>,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    // ── Host-side subcommands ──
    /// Launch an interactive container shell.
    Shell {
        /// Print the docker run command and exit without starting the container.
        #[arg(long)]
        dry_run: bool,

        /// Arguments passed through to the shell.
        #[arg(last = true)]
        args: Vec<String>,
    },

    /// Run a command inside the container.
    Run {
        /// Arguments passed through (the command to execute).
        #[arg(last = true)]
        args: Vec<String>,
    },

    /// Manage background container jobs.
    Job {
        #[command(subcommand)]
        action: JobAction,
    },

    /// Build or rebuild the Docker image.
    Build {
        /// Force rebuild (ignore cache).
        #[arg(long)]
        force: bool,
    },

    /// Show effective configuration.
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },

    /// Stage Spack environment changes safely.
    Stage {
        /// Source manifest YAML to stage
        #[arg(long, default_value = "pkg/zephyr/spack_src.yaml")]
        source_yaml: String,

        /// Run root directory (auto-generated under outputs/spack_stage if omitted)
        #[arg(long)]
        run_root: Option<String>,

        /// Spec(s) to add and analyze (repeatable)
        #[arg(long = "spec", num_args = 1)]
        specs: Vec<String>,

        /// Python module(s) to verify after install (repeatable)
        #[arg(long = "python-import", num_args = 1)]
        python_imports: Vec<String>,

        /// Comma-separated package names forbidden from being newly required
        #[arg(long, default_value = "py-torch,py-jax,py-jaxlib,torch,jax,jaxlib,llvm")]
        forbidden_names: String,

        /// Allow concretizer to select deprecated versions
        #[arg(long, default_value_t = true)]
        allow_deprecated: bool,

        /// Require GPU verification after install
        #[arg(long, default_value_t = true)]
        gpu_verify: bool,

        /// Enable verbose output
        #[arg(long)]
        verbose: bool,
    },

    /// Run the validation suite.
    Validate {
        /// Skip shellcheck.
        #[arg(long)]
        quick: bool,

        /// Quick Spack/GPU verification only.
        #[arg(long)]
        verify_only: bool,
    },

    /// Show version information.
    Version,

    // ── Container-side subcommands ──
    /// Initialize Spack + CUDA environment (container-side).
    Init {
        /// Only initialize Spack (skip CUDA, MLSys venv).
        #[arg(long)]
        spack_only: bool,

        /// Only set up CUDA environment variables.
        #[arg(long)]
        cuda_only: bool,

        /// Command to execute after initialization.
        #[arg(last = true)]
        exec_args: Vec<String>,
    },

    /// Validate GPU availability (Torch + JAX).
    GpuCheck,

    /// Verify Spack packages are installed and functional.
    VerifySpack,

    /// Install Python packages with uv (respecting Spack constraints).
    UvInstall {
        /// Packages to install.
        #[arg(required = true)]
        packages: Vec<String>,

        /// Venv directory (default: .venv).
        #[arg(long, default_value = ".venv")]
        venv_dir: String,
    },

    /// Download HuggingFace models or datasets.
    HfDownload {
        #[command(subcommand)]
        action: HfAction,
    },

    /// Run a named entrypoint sequence (container-side).
    Entrypoint {
        /// Entrypoint name (default, run-job, verify-gpu, etc.).
        name: String,

        /// Arguments passed to the entrypoint.
        #[arg(last = true)]
        args: Vec<String>,
    },

    /// Internal: job wrapper that runs inside the container.
    #[command(hide = true)]
    JobWrapper {
        /// Job name for logging and status files.
        #[arg(long)]
        name: String,

        /// Path to the JSONL log file.
        #[arg(long)]
        log_file: String,

        /// Path to the status file.
        #[arg(long)]
        status_file: String,

        /// The command to execute.
        #[arg(last = true)]
        command: Vec<String>,
    },
}

#[derive(Subcommand, Debug)]
pub enum JobAction {
    /// Start a background container job.
    Run {
        /// Project ID.
        #[arg(long)]
        project_id: String,

        /// Job name.
        #[arg(long)]
        job: String,

        /// Run ID (auto-generated if not provided).
        #[arg(long)]
        run_id: Option<String>,

        /// The command to execute (after --).
        #[arg(last = true)]
        command: Vec<String>,
    },

    /// Check job status.
    Status {
        #[arg(long)]
        project_id: String,
        #[arg(long)]
        job: String,
        #[arg(long)]
        run_id: Option<String>,
    },

    /// Stream job logs.
    Tail {
        #[arg(long)]
        project_id: String,
        #[arg(long)]
        job: String,
        #[arg(long)]
        run_id: Option<String>,
        /// Number of lines to show.
        #[arg(long, default_value = "80")]
        lines: usize,
    },

    /// Stop a running job.
    Stop {
        #[arg(long)]
        project_id: String,
        #[arg(long)]
        job: String,
    },

    /// Check job health (PID liveness + last status).
    Health {
        #[arg(long)]
        project_id: String,
        #[arg(long)]
        job: String,
        #[arg(long)]
        run_id: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
pub enum ConfigAction {
    /// Print effective configuration.
    Show,
}

#[derive(Subcommand, Debug)]
pub enum HfAction {
    /// Download a HuggingFace model.
    Model {
        /// Model ID (e.g. Qwen/Qwen3-0.6B-Base).
        model_id: String,
    },

    /// Download a HuggingFace dataset.
    Dataset {
        /// Dataset ID (e.g. HuggingFaceFW/fineweb).
        dataset_id: String,

        /// Dataset config (default: default).
        #[arg(long, default_value = "default")]
        config: String,

        /// Split to download (default: train[:100]).
        #[arg(long, default_value = "train[:100]")]
        split: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    fn parse(args: &[&str]) -> Cli {
        let mut full_args = vec!["zephyr"];
        full_args.extend_from_slice(args);
        Cli::parse_from(full_args)
    }

    #[test]
    fn parse_no_args_gives_none_command() {
        let cli = parse(&[]);
        assert!(cli.command.is_none());
    }

    #[test]
    fn parse_version_subcommand() {
        let cli = parse(&["version"]);
        assert!(matches!(cli.command, Some(Command::Version)));
    }

    #[test]
    fn parse_shell_subcommand() {
        let cli = parse(&["shell"]);
        assert!(matches!(cli.command, Some(Command::Shell { .. })));
    }

    #[test]
    fn parse_shell_dry_run() {
        let cli = parse(&["shell", "--dry-run"]);
        match cli.command {
            Some(Command::Shell { dry_run, .. }) => assert!(dry_run),
            _ => panic!("expected Shell command"),
        }
    }

    #[test]
    fn parse_shell_dry_run_false_by_default() {
        let cli = parse(&["shell"]);
        match cli.command {
            Some(Command::Shell { dry_run, .. }) => assert!(!dry_run),
            _ => panic!("expected Shell command"),
        }
    }

    #[test]
    fn parse_shell_with_args() {
        let cli = parse(&["shell", "--", "echo", "hello"]);
        match cli.command {
            Some(Command::Shell { args, .. }) => {
                assert_eq!(args, vec!["echo", "hello"]);
            }
            _ => panic!("expected Shell command"),
        }
    }

    #[test]
    fn parse_run_with_command() {
        let cli = parse(&["run", "--", "python", "train.py"]);
        match cli.command {
            Some(Command::Run { args }) => {
                assert_eq!(args, vec!["python", "train.py"]);
            }
            _ => panic!("expected Run command"),
        }
    }

    #[test]
    fn parse_build_with_force() {
        let cli = parse(&["build", "--force"]);
        match cli.command {
            Some(Command::Build { force }) => assert!(force),
            _ => panic!("expected Build command"),
        }
    }

    #[test]
    fn parse_build_without_force() {
        let cli = parse(&["build"]);
        match cli.command {
            Some(Command::Build { force }) => assert!(!force),
            _ => panic!("expected Build command"),
        }
    }

    #[test]
    fn parse_gpu_check() {
        let cli = parse(&["gpu-check"]);
        assert!(matches!(cli.command, Some(Command::GpuCheck)));
    }

    #[test]
    fn parse_verify_spack() {
        let cli = parse(&["verify-spack"]);
        assert!(matches!(cli.command, Some(Command::VerifySpack)));
    }

    #[test]
    fn parse_config_show() {
        let cli = parse(&["config", "show"]);
        match cli.command {
            Some(Command::Config { action: ConfigAction::Show }) => {}
            _ => panic!("expected Config Show"),
        }
    }

    #[test]
    fn parse_job_run() {
        let cli = parse(&[
            "job", "run",
            "--project-id", "my-proj",
            "--job", "train",
            "--", "python", "train.py",
        ]);
        match cli.command {
            Some(Command::Job { action: JobAction::Run { project_id, job, command, .. } }) => {
                assert_eq!(project_id, "my-proj");
                assert_eq!(job, "train");
                assert_eq!(command, vec!["python", "train.py"]);
            }
            _ => panic!("expected Job Run"),
        }
    }

    #[test]
    fn parse_job_status() {
        let cli = parse(&["job", "status", "--project-id", "proj", "--job", "train"]);
        assert!(matches!(cli.command, Some(Command::Job { action: JobAction::Status { .. } })));
    }

    #[test]
    fn parse_job_tail_with_lines() {
        let cli = parse(&["job", "tail", "--project-id", "proj", "--job", "train", "--lines", "100"]);
        match cli.command {
            Some(Command::Job { action: JobAction::Tail { lines, .. } }) => {
                assert_eq!(lines, 100);
            }
            _ => panic!("expected Job Tail"),
        }
    }

    #[test]
    fn parse_job_tail_default_lines() {
        let cli = parse(&["job", "tail", "--project-id", "proj", "--job", "train"]);
        match cli.command {
            Some(Command::Job { action: JobAction::Tail { lines, .. } }) => {
                assert_eq!(lines, 80);
            }
            _ => panic!("expected Job Tail"),
        }
    }

    #[test]
    fn parse_uv_install() {
        let cli = parse(&["uv-install", "numpy", "pandas"]);
        match cli.command {
            Some(Command::UvInstall { packages, venv_dir }) => {
                assert_eq!(packages, vec!["numpy", "pandas"]);
                assert_eq!(venv_dir, ".venv");
            }
            _ => panic!("expected UvInstall"),
        }
    }

    #[test]
    fn parse_uv_install_custom_venv() {
        let cli = parse(&["uv-install", "--venv-dir", "/custom/venv", "torch"]);
        match cli.command {
            Some(Command::UvInstall { venv_dir, .. }) => {
                assert_eq!(venv_dir, "/custom/venv");
            }
            _ => panic!("expected UvInstall"),
        }
    }

    #[test]
    fn parse_hf_download_model() {
        let cli = parse(&["hf-download", "model", "Qwen/Qwen3-0.6B-Base"]);
        match cli.command {
            Some(Command::HfDownload { action: HfAction::Model { model_id } }) => {
                assert_eq!(model_id, "Qwen/Qwen3-0.6B-Base");
            }
            _ => panic!("expected HfDownload Model"),
        }
    }

    #[test]
    fn parse_hf_download_dataset() {
        let cli = parse(&["hf-download", "dataset", "HuggingFaceFW/fineweb"]);
        match cli.command {
            Some(Command::HfDownload { action: HfAction::Dataset { dataset_id, config, split } }) => {
                assert_eq!(dataset_id, "HuggingFaceFW/fineweb");
                assert_eq!(config, "default");
                assert_eq!(split, "train[:100]");
            }
            _ => panic!("expected HfDownload Dataset"),
        }
    }

    #[test]
    fn parse_entrypoint() {
        let cli = parse(&["entrypoint", "run-job", "--", "python", "train.py"]);
        match cli.command {
            Some(Command::Entrypoint { name, args }) => {
                assert_eq!(name, "run-job");
                assert_eq!(args, vec!["python", "train.py"]);
            }
            _ => panic!("expected Entrypoint"),
        }
    }

    #[test]
    fn parse_global_repo_flag() {
        let cli = parse(&["--repo", "/tmp/my-repo", "shell"]);
        assert_eq!(cli.repo, Some("/tmp/my-repo".to_string()));
    }

    #[test]
    fn parse_global_lease_mode() {
        let cli = parse(&["--lease-mode", "enforce", "shell"]);
        assert_eq!(cli.lease_mode, Some("enforce".to_string()));
    }

    #[test]
    fn parse_global_cache_profile() {
        let cli = parse(&["--cache-profile", "isolated", "shell"]);
        assert_eq!(cli.cache_profile, Some("isolated".to_string()));
    }

    #[test]
    fn parse_print_effective_config() {
        let cli = parse(&["--print-effective-config", "shell"]);
        assert!(cli.print_effective_config);
    }

    #[test]
    fn parse_stage_defaults() {
        let cli = parse(&["stage"]);
        match cli.command {
            Some(Command::Stage {
                source_yaml,
                specs,
                forbidden_names,
                allow_deprecated,
                gpu_verify,
                verbose,
                run_root,
                python_imports,
            }) => {
                assert_eq!(source_yaml, "pkg/zephyr/spack_src.yaml");
                assert!(specs.is_empty());
                assert_eq!(forbidden_names, "py-torch,py-jax,py-jaxlib,torch,jax,jaxlib,llvm");
                assert!(allow_deprecated);
                assert!(gpu_verify);
                assert!(!verbose);
                assert!(run_root.is_none());
                assert!(python_imports.is_empty());
            }
            _ => panic!("expected Stage command"),
        }
    }

    #[test]
    fn parse_stage_with_specs() {
        let cli = parse(&[
            "stage",
            "--spec", "py-soundfile",
            "--spec", "sox",
            "--python-import", "soundfile",
            "--verbose",
            "--source-yaml", "/tmp/test.yaml",
        ]);
        match cli.command {
            Some(Command::Stage { specs, python_imports, verbose, source_yaml, .. }) => {
                assert_eq!(specs, vec!["py-soundfile", "sox"]);
                assert_eq!(python_imports, vec!["soundfile"]);
                assert!(verbose);
                assert_eq!(source_yaml, "/tmp/test.yaml");
            }
            _ => panic!("expected Stage command"),
        }
    }

    #[test]
    fn parse_validate_quick() {
        let cli = parse(&["validate", "--quick"]);
        match cli.command {
            Some(Command::Validate { quick, verify_only }) => {
                assert!(quick);
                assert!(!verify_only);
            }
            _ => panic!("expected Validate"),
        }
    }

    #[test]
    fn parse_validate_verify_only() {
        let cli = parse(&["validate", "--verify-only"]);
        match cli.command {
            Some(Command::Validate { quick, verify_only }) => {
                assert!(!quick);
                assert!(verify_only);
            }
            _ => panic!("expected Validate"),
        }
    }

    #[test]
    fn parse_init_spack_only() {
        let cli = parse(&["init", "--spack-only"]);
        match cli.command {
            Some(Command::Init { spack_only, cuda_only, .. }) => {
                assert!(spack_only);
                assert!(!cuda_only);
            }
            _ => panic!("expected Init"),
        }
    }

    #[test]
    fn parse_job_wrapper_hidden() {
        let cli = parse(&[
            "job-wrapper",
            "--name", "train",
            "--log-file", "/tmp/log.jsonl",
            "--status-file", "/tmp/status",
            "--", "python", "train.py",
        ]);
        match cli.command {
            Some(Command::JobWrapper { name, log_file, status_file, command }) => {
                assert_eq!(name, "train");
                assert_eq!(log_file, "/tmp/log.jsonl");
                assert_eq!(status_file, "/tmp/status");
                assert_eq!(command, vec!["python", "train.py"]);
            }
            _ => panic!("expected JobWrapper"),
        }
    }
}
