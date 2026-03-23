# RFC-057: Add `--dry-run` Flag to `zephyr shell`

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Medium
**Effort:** M

---

## Problem

`zephyr shell` launches a Docker container immediately with no preview. There is no way to see
the exact `docker run` command that would be executed without actually starting the container.
This makes it hard to debug configuration issues, audit security posture, or document effective
launch parameters.

`ZEPHYR_ROOTLESS=0 zephyr config show` prints resolved config but not the full `docker run`
arguments.

---

## Solution

Add a `--dry-run` flag to the `zephyr shell` subcommand. When set:

1. Build the `docker run` argument list exactly as normal (config, env vars, mounts, resource
   limits, user spec, entrypoint).
2. Print the full command to stdout, one argument per line:

```
docker run \
  --rm \
  --gpus all \
  --user 1000:1000 \
  --network bridge \
  --ipc shareable \
  --shm-size 16g \
  ...
  sygaldry/zephyr:base \
  zephyr entrypoint default
```

3. Exit 0 without starting the container.

### Implementation

In `crates/zephyr/src/cli.rs`, add `dry_run: bool` to `ShellArgs`.

In `crates/zephyr/src/host/launcher.rs`, check the flag before calling `Command::new("docker").exec()`:

```rust
if config.dry_run {
    print_docker_run_command(&args);
    return Ok(());
}
```

`print_docker_run_command` iterates the args slice, shell-quoting tokens containing spaces or
special characters, printing with trailing ` \` per line.

### Scope

Only `zephyr shell` needs `--dry-run`. Other subcommands are out of scope.

---

## Acceptance Criteria

1. `zephyr shell --dry-run` prints a `docker run` command and exits 0.
2. The output contains `--gpus`, `--user`, at least one `-v` mount, and the image name.
3. Unit tests assert: `dry_run=true` returns `Ok(())` without calling `execvp`.
4. `./validate_all.sh --quick` passes.
