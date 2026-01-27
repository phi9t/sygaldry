//! Integration test: verify the zephyr binary's host-side behavior.
//!
//! Uses the compiled test binary directly (not cargo run).

use std::path::PathBuf;

fn zephyr_bin() -> PathBuf {
    // cargo test builds binaries in target/debug/
    let mut path = std::env::current_exe().unwrap();
    path.pop(); // remove test binary name
    path.pop(); // remove 'deps'
    path.push("zephyr");
    path
}

const SYGALDRY_HOME: &str = "/mnt/data_infra/workspace/sygaldry";

#[test]
fn rust_binary_config_show_succeeds() {
    let output = std::process::Command::new(zephyr_bin())
        .args(["config", "show"])
        .env("SYGALDRY_HOME", SYGALDRY_HOME)
        .env_remove("SYGALDRY_IN_CONTAINER")
        .output()
        .expect("failed to run zephyr");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Effective config"),
        "config show should print effective config, got: {stderr}"
    );
    assert!(
        stderr.contains("Spack store"),
        "config show should mention Spack store"
    );
    assert!(
        stderr.contains("spack_store"),
        "should reference spack_store path"
    );
}

#[test]
fn rust_binary_version_succeeds() {
    let output = std::process::Command::new(zephyr_bin())
        .args(["version"])
        .env("SYGALDRY_HOME", SYGALDRY_HOME)
        .env_remove("SYGALDRY_IN_CONTAINER")
        .output()
        .expect("failed to run zephyr");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("zephyr 0.1.0"),
        "should print version, got: {stdout}"
    );
}

#[test]
fn container_cmd_rejected_on_host() {
    let cmds = &["gpu-check", "verify-spack"];
    for cmd in cmds {
        let output = std::process::Command::new(zephyr_bin())
            .args([cmd])
            .env("SYGALDRY_HOME", SYGALDRY_HOME)
            .env_remove("SYGALDRY_IN_CONTAINER")
            .output()
            .expect("failed to run zephyr");

        assert!(
            !output.status.success(),
            "{cmd} should fail on host"
        );
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("only available inside the container"),
            "{cmd} should say container-only, got: {stderr}"
        );
    }
}

#[test]
fn config_picks_up_project_id() {
    let output = std::process::Command::new(zephyr_bin())
        .args(["config", "show"])
        .env("SYGALDRY_HOME", SYGALDRY_HOME)
        .env("SYGALDRY_PROJECT_ID", "integration-test-proj")
        .env_remove("SYGALDRY_IN_CONTAINER")
        .output()
        .expect("failed to run zephyr");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("integration-test-proj"),
        "should show custom project ID, got: {stderr}"
    );
}

#[test]
fn config_shows_multi_repo_mode() {
    let output = std::process::Command::new(zephyr_bin())
        .args(["--repo", "/tmp/fake-repo", "config", "show"])
        .env("SYGALDRY_HOME", SYGALDRY_HOME)
        .env_remove("SYGALDRY_IN_CONTAINER")
        .output()
        .expect("failed to run zephyr");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("multi-repo"),
        "should show multi-repo mode, got: {stderr}"
    );
}

#[test]
fn help_output_includes_all_subcommands() {
    let output = std::process::Command::new(zephyr_bin())
        .args(["--help"])
        .env("SYGALDRY_HOME", SYGALDRY_HOME)
        .env_remove("SYGALDRY_IN_CONTAINER")
        .output()
        .expect("failed to run zephyr");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let expected_cmds = ["shell", "run", "job", "build", "config", "validate", "version",
                         "init", "gpu-check", "verify-spack", "uv-install", "hf-download", "entrypoint"];
    for cmd in &expected_cmds {
        assert!(
            stdout.contains(cmd),
            "help should mention '{cmd}', got: {stdout}"
        );
    }
}
