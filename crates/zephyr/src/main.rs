mod cli;
mod config;
mod config_types;
mod context;
mod error;
mod paths;

mod container;
mod host;

use std::error::Error;

use clap::Parser;
use cli::Cli;
use context::RuntimeContext;

fn main() {
    let cli = Cli::parse();
    let ctx = RuntimeContext::detect();

    let result = match ctx {
        RuntimeContext::Host => host::dispatch(&cli),
        RuntimeContext::Container => container::dispatch(&cli),
    };

    if let Err(e) = result {
        eprintln!("ERROR: {e}");
        if let Some(source) = e.source() {
            eprintln!("  caused by: {source}");
        }
        std::process::exit(1);
    }
}
