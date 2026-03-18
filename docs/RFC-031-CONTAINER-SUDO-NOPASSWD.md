# RFC-031: Scope Container User sudo Privileges

**Status:** Proposed
**Priority:** Medium
**Effort:** S
**Area:** docker

## Problem

`container/dev_container.dockerfile` grants the container user `kvothe` unrestricted passwordless sudo:

```dockerfile
echo 'kvothe ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
```

This means any process running as `kvothe` inside the container — including an LLM agent with filesystem write access — can escalate to root within the container. While the container is isolated from the host by the Docker daemon, this is still a significant blast radius: a root process in the container can modify system libraries, install packages, and (in `--net=host` or `--ipc=host` mode) affect the host.

## Evidence

`container/dev_container.dockerfile` line 224:
```dockerfile
RUN echo 'kvothe ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
```

The container also runs with `--ipc=host` and `--net=host` (see RFC-032), amplifying the risk.

## Proposed Changes

1. Scope sudo to specific commands that actually require root. Based on the entrypoint scripts and Spack usage, the set is small:
   ```
   kvothe ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/dpkg, /opt/spack_src/bin/spack, /usr/sbin/ldconfig
   ```

2. Add a comment in the Dockerfile explaining why each allowed command requires root.

3. Run a one-time audit of all entrypoint scripts to confirm the full required-sudo command list, then lock it down.

4. For development use where unrestricted sudo is needed, document the `ZEPHYR_DEV_SUDO=1` env var as an explicit opt-in that adds `NOPASSWD:ALL` during container startup (via an entrypoint check) rather than baking it into the image.

## Files Changed

- `container/dev_container.dockerfile` — replace `NOPASSWD:ALL` with scoped command list

## Verification

```bash
# Build the image
docker build -f container/dev_container.dockerfile -t sygaldry/zephyr:test-sudo .
# Verify kvothe cannot sudo arbitrary commands:
docker run --rm sygaldry/zephyr:test-sudo sudo id
# Should fail with "command not in sudoers" for commands not in the allow list.
docker run --rm sygaldry/zephyr:test-sudo sudo /usr/bin/apt-get --version
# Should succeed.
```
