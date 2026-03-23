# RFC-063: Stale Lease Auto-Recovery in Zephyr Launcher

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Medium
**Effort:** S

---

## Problem

`crates/zephyr/src/host/lease.rs` implements a file-based lease with a 6-hour TTL. When a
container process crashes (SIGKILL, OOM), the lease file persists. The next `zephyr shell`
invocation finds an unexpired lease and returns `LeaseConflict`:

```
error: lease already acquired for project sygaldry by PID 12345 (expires in 5h47m)
```

The user must manually delete the lease file or wait 6 hours. There is no `zephyr lease
release` command or automatic recovery.

---

## Solution

Add PID liveness checking to the lease-acquire path.

### Change 1: Record PID in lease file

Include the acquiring process PID as line 1 of the lease file.

### Change 2: Check liveness before rejecting

When an unexpired lease is found:
1. Parse the PID from the lease file.
2. Check liveness via `kill(pid, 0)` (signal 0 = existence check).
3. If process is dead (ESRCH), log a warning and overwrite the lease:
   ```
   warn: stale lease found for PID 12345 (process not running); recovering
   ```
4. If alive, reject as before.

Use `nix::sys::signal::kill(Pid::from_raw(pid), None)` — `nix` is already a transitive dep.

### Change 3: `zephyr lease release` subcommand

Add `lease release --project-id <id>` that:
1. Reads the lease file.
2. If the holding PID is dead (or `--force` is given), deletes the file and prints "lease released".
3. If alive, prints a warning and exits non-zero (unless `--force`).

---

## Acceptance Criteria

1. After a simulated crash (lease file with dead PID), `zephyr shell` launches successfully.
2. Unit test `test_acquire_stale_pid_recovers` in `host/lease.rs` passes.
3. `zephyr lease release --project-id sygaldry` with a stale lease exits 0 and removes the file.
4. `./validate_all.sh --quick` passes.
