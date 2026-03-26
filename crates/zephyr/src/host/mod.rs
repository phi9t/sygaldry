pub mod cuda;
pub mod dirs;
pub mod docker_args;
pub(super) mod docker_env;
pub(super) mod docker_mounts;
pub mod image;
pub mod job;
pub mod launcher;
pub mod lease;
pub mod requirements;
pub mod staging;

use crate::cli::{Cli, Command, ConfigAction, LeaseAction};
use crate::config::{CliOverrides, ZephyrConfig};
use crate::error::{Result, ZephyrError};

/// Dispatch a CLI command in host mode.
pub fn dispatch(cli: &Cli) -> Result<()> {
    let overrides = CliOverrides {
        repo: cli.repo.clone(),
        run_id: cli.run_id.clone(),
        lease_mode: cli.lease_mode.clone(),
        cache_profile: cli.cache_profile.clone(),
        ..Default::default()
    };

    match &cli.command {
        None => {
            // No subcommand: launch interactive shell (backward compat)
            let config = ZephyrConfig::from_env(&overrides);
            if cli.print_effective_config {
                config.print_effective();
            }
            let ep = cli.entrypoint.as_deref().unwrap_or("default");
            launcher::launch(&config, ep, &cli.passthrough, false)
        }

        Some(Command::Shell { args, dry_run }) => {
            let config = ZephyrConfig::from_env(&overrides);
            if cli.print_effective_config {
                config.print_effective();
            }
            let ep = cli.entrypoint.as_deref().unwrap_or("default");
            launcher::launch(&config, ep, args, *dry_run)
        }

        Some(Command::Run { args }) => {
            let config = ZephyrConfig::from_env(&overrides);
            let ep = cli.entrypoint.as_deref().unwrap_or("run-job");
            launcher::launch(&config, ep, args, false)
        }

        Some(Command::Job { action }) => {
            let config = ZephyrConfig::from_env(&overrides);
            job::dispatch_job(action, &config.layout.projects_root)
        }

        Some(Command::Build { force }) => {
            let config = ZephyrConfig::from_env(&overrides);
            image::build_image(&config, *force)
        }

        Some(Command::Config { action }) => {
            match action {
                ConfigAction::Show => {
                    let config = ZephyrConfig::from_env(&overrides);
                    config.print_effective();
                    Ok(())
                }
            }
        }

        Some(Command::Stage {
            source_yaml,
            run_root,
            specs,
            python_imports,
            forbidden_names,
            allow_deprecated,
            gpu_verify,
            verbose,
        }) => {
            let config = ZephyrConfig::from_env(&overrides);
            let run_id = format!(
                "{}-{}",
                chrono::Local::now().format("%Y%m%d-%H%M%S"),
                std::process::id()
            );
            let source_path = if std::path::Path::new(source_yaml).is_absolute() {
                std::path::PathBuf::from(source_yaml)
            } else {
                config.sygaldry_home.join(source_yaml)
            };
            let run_root_path = run_root
                .as_ref()
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| config.sygaldry_home.join("outputs/spack_stage").join(&run_id));

            let stage_config = staging::StageConfig {
                source_yaml: source_path,
                run_root: run_root_path,
                specs: specs.clone(),
                python_imports: python_imports.clone(),
                forbidden_names: forbidden_names.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect(),
                allow_deprecated: *allow_deprecated,
                gpu_verify: *gpu_verify,
                verbose: *verbose,
                sygaldry_home: config.sygaldry_home.clone(),
            };
            staging::run_stage(&stage_config)
        }

        Some(Command::Validate { quick, verify_only }) => {
            let config = ZephyrConfig::from_env(&overrides);
            let mut args = vec![config.sygaldry_home.join("validate_all.sh").display().to_string()];
            if *quick {
                args.push("--quick".to_string());
            }
            if *verify_only {
                args.push("--verify-only".to_string());
            }
            let status = std::process::Command::new(&args[0])
                .args(&args[1..])
                .status()?;
            if status.success() {
                Ok(())
            } else {
                Err(ZephyrError::CommandFailed {
                    command: "validate_all.sh".to_string(),
                    code: status.code().unwrap_or(1),
                })
            }
        }

        Some(Command::Lease { action }) => {
            match action {
                LeaseAction::Release { project_id, resource, force } => {
                    let lease_overrides = crate::config::CliOverrides {
                        project_id: Some(project_id.clone()),
                        ..Default::default()
                    };
                    let config = ZephyrConfig::from_env(&lease_overrides);
                    lease::release(&config.layout.leases, resource, *force)
                }
            }
        }

        Some(Command::Version) => {
            println!("zephyr {}", env!("CARGO_PKG_VERSION"));
            if let Ok(home) = std::env::var("SYGALDRY_HOME") {
                println!("  Home: {home}");
            }
            Ok(())
        }

        // Container-side commands issued from host — error
        Some(
            Command::Init { .. }
            | Command::GpuCheck
            | Command::VerifySpack
            | Command::UvInstall { .. }
            | Command::HfDownload { .. }
            | Command::Entrypoint { .. }
            | Command::JobWrapper { .. },
        ) => Err(ZephyrError::with_hint(
            "This command is only available inside the container.",
            "Launch a container first with: zephyr shell",
        )),
    }
}
