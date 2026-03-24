pub mod cuda;
pub mod entrypoint;
pub mod gpu_check;
pub mod hf_download;
pub mod mlsys_venv;
pub mod spack;
pub mod uv_install;
pub mod verify;

use crate::cli::{Cli, Command, HfAction};
use crate::error::{Result, ZephyrError};

/// Dispatch a CLI command in container mode.
pub fn dispatch(cli: &Cli) -> Result<()> {
    match &cli.command {
        Some(Command::Init {
            spack_only,
            cuda_only,
            exec_args,
        }) => {
            if *cuda_only {
                cuda::setup_cuda_env()?;
            } else if *spack_only {
                spack::init_spack()?;
                spack::activate_env()?;
            } else {
                spack::full_init()?;
            }

            if !exec_args.is_empty() {
                let status = std::process::Command::new(&exec_args[0])
                    .args(&exec_args[1..])
                    .status()?;
                if !status.success() {
                    std::process::exit(status.code().unwrap_or(1));
                }
            }
            Ok(())
        }

        Some(Command::GpuCheck) => gpu_check::run(),

        Some(Command::VerifySpack) => verify::run(),

        Some(Command::UvInstall { packages, venv_dir }) => {
            uv_install::install(packages, venv_dir)
        }

        Some(Command::HfDownload { action }) => match action {
            HfAction::Model { model_id } => hf_download::download_model(model_id),
            HfAction::Dataset {
                dataset_id,
                config,
                split,
            } => hf_download::download_dataset(dataset_id, config, split),
        },

        Some(Command::Entrypoint { name, args }) => entrypoint::run(name, args),

        Some(Command::JobWrapper {
            name,
            log_file,
            status_file,
            command,
        }) => entrypoint::job_wrapper(name, log_file, status_file, command),

        // Host-side commands issued from inside container
        None | Some(Command::Shell { .. } | Command::Run { .. }) => {
            // In container with no subcommand: run the default entrypoint
            entrypoint::run("default", &cli.passthrough)
        }

        Some(
            Command::Job { .. }
            | Command::Build { .. }
            | Command::Config { .. }
            | Command::Stage { .. }
            | Command::Validate { .. }
            | Command::Lease { .. },
        ) => Err(ZephyrError::with_hint(
            "This command is only available on the host.",
            "Run it outside the container.",
        )),

        Some(Command::Version) => {
            println!("zephyr {} (container)", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
    }
}
