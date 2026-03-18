# RFC-033: Add Resource Limits to docker run

**Status:** Proposed
**Priority:** Low
**Effort:** S
**Area:** docker

## Problem

The container launcher passes no resource limit flags to `docker run`. A runaway container — or an LLM agent that spawns a compute-intensive subprocess — can consume all available CPU, memory, and disk I/O on the host, starving other containers and host processes.

With SAIL running autonomously in continuous cycles, unbounded resource consumption is a real operational risk: an agent that enters a loop could exhaust host memory before the Temporal heartbeat timeout fires.

## Evidence

`crates/zephyr/src/host/docker_args.rs` — `build()` function: no `--memory`, `--cpus`, `--blkio-weight`, or `--memory-swap` flags.

`container/launch_container.sh` — `build_docker_args()`: same absence.

## Proposed Changes

1. Add configurable resource limit env vars with reasonable defaults:
   | Env Var | Docker Flag | Default |
   |---------|-------------|---------|
   | `ZEPHYR_MEMORY_LIMIT` | `--memory` | (unset — no limit) |
   | `ZEPHYR_CPU_LIMIT` | `--cpus` | (unset — no limit) |
   | `ZEPHYR_MEMORY_SWAP` | `--memory-swap` | (unset) |
   | `ZEPHYR_PIDS_LIMIT` | `--pids-limit` | `4096` |

2. For SAIL-triggered containers specifically (where `SAIL_RUN=1` is set in the environment), apply stricter defaults:
   - `--pids-limit 4096` (prevent fork bombs)
   - `--memory 64g` (generous but bounded for a 128GB host)

3. Implement in the Rust `docker_args::build()` and pass through to the bash shim.

4. Document all new env vars in `CLAUDE.md`.

## Files Changed

- `crates/zephyr/src/host/docker_args.rs` — add resource limit args from config
- `crates/zephyr/src/config.rs` — add `memory_limit`, `cpu_limit`, `pids_limit` fields
- `container/launch_container.sh` — same env vars
- `CLAUDE.md` — document new vars

## Verification

```bash
cd crates/zephyr && cargo test
# Functional: launch with ZEPHYR_PIDS_LIMIT=100, verify docker inspect shows pids-limit=100
docker inspect <container_id> | grep -i pids
```
