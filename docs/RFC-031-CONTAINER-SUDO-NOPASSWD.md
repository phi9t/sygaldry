# RFC-031: Add Explicit Dev-Only Unrestricted sudo Opt-In

**Status:** Draft — v2
**Date:** 2026-03-21
**Priority:** Low
**Effort:** S
**Area:** docker

## Problem

The main security issue from the original RFC is now fixed: `container/dev_container.dockerfile:221-227`
scopes `kvothe` to package-management commands only, using a dedicated sudoers file:

```dockerfile
Cmnd_Alias ZEPHYR_PKG_CMDS = /usr/bin/apt, /usr/bin/apt-get, /usr/bin/dpkg, /usr/sbin/ldconfig
kvothe ALL=(ALL) NOPASSWD: ZEPHYR_PKG_CMDS
```

That removes the baked-in `NOPASSWD:ALL` blast radius. The remaining gap is developer ergonomics:
there is still no explicit, temporary opt-in for the rare debugging session that genuinely needs
full root inside the container.

## Evidence

- `container/dev_container.dockerfile:221-227` limits sudo to `apt`, `apt-get`, `dpkg`, and `ldconfig`
- No `ZEPHYR_DEV_SUDO` handling exists in `crates/zephyr/src/host/docker_args.rs` or the container entrypoint path

## Remaining Change

1. Add a development-only `ZEPHYR_DEV_SUDO=1` opt-in so a caller can request unrestricted sudo
   without baking `NOPASSWD:ALL` into the image by default.

## Files Changed

- `crates/zephyr/src/host/docker_args.rs` or equivalent launcher path — pass through the explicit opt-in
- container startup path — apply the dev-only sudo override when requested
- `CLAUDE.md` — document the escape hatch and make clear that it is for local debugging only

## Verification

```bash
# Default image remains least-privilege
docker run --rm sygaldry/zephyr:test-sudo sudo id
# Should fail.

# Dev-only override restores unrestricted sudo when explicitly requested
ZEPHYR_DEV_SUDO=1 sygaldry shell -- sudo id
```
