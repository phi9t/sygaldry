# NVIDIA Fixes (Host + Docker)

This workspace includes tools to inspect and repair NVIDIA driver + Docker GPU access.

## Scripts

### 1) Inspect current setup

```bash
./container/inspect_nvidia_setup.sh
```

Outputs a detailed snapshot of:
- OS/kernel details
- GPU detection (PCI)
- NVIDIA kernel modules
- Device nodes under `/dev`
- `nvidia-smi` and NVML library presence
- Installed NVIDIA packages
- Docker + NVIDIA container toolkit status

A timestamped log is written under:

```
./container/logs/nvidia_inspect_YYYYmmdd_HHMMSS.log
```

### 2) Apply fixes

```bash
./container/fix_nvidia_setup.sh
```

This script:
- Installs base dependencies (DKMS, headers, ubuntu-drivers, etc.)
- Upgrades GnuPG components to resolve common apt dependency issues
- Runs `apt --fix-broken install` to resolve partial installs
- Installs the recommended NVIDIA driver (or defaults to `nvidia-driver-545`)
- Removes conflicting `*-server` driver packages when present
- Purges incomplete CUDA 12.8 packages (often left in `iU` state)
- Loads NVIDIA kernel modules
- Installs and configures `nvidia-container-toolkit`
- Restarts Docker and runs validation checks

A timestamped log is written under:

```
./container/logs/nvidia_fix_YYYYmmdd_HHMMSS.log
```

## Expected outcomes

- `nvidia-smi` works on the host
- Docker can run GPU containers with `--gpus all`

## If issues persist

1. Run `./container/diagnose_nvidia.sh` and review its output.
2. Check for a required reboot (look for `/var/run/reboot-required`).
3. If kernel modules still fail, re-run `./container/fix_nvidia_setup.sh` after reboot.
4. If apt dependency errors persist, re-run `./container/fix_nvidia_setup.sh` and confirm that no `cuda-12-8` packages remain in `iU` state.

## Notes

- This is optimized for Ubuntu 24.04 (Noble). If you are on a different distro,
  adjust the package manager and repo instructions accordingly.
- For multi-GPU systems, `nvidia-smi -L` should list all GPUs.

## Incident Record: Jan 26, 2026 (Ubuntu 24.04)

### Summary
`container/fix_nvidia_setup.sh` initially failed due to a mixed NVIDIA driver state and broken apt dependencies. The system had an old NVIDIA 570 kernel module loaded while user-space driver libraries were 555.42.06, causing an NVML driver/library mismatch. Docker GPU runtime also failed for the same reason. The fix was to repair apt dependencies, resolve an NVIDIA package file conflict, and reload the correct 555.42.06 kernel modules.

### Symptoms
- `nvidia-smi` failed with: `Failed to initialize NVML: Driver/library version mismatch`.
- Docker GPU test failed with `nvidia-container-cli: initialization error: nvml error: driver/library version mismatch`.
- `apt` operations failed with NVIDIA/CUDA dependency conflicts.

### Root cause
- NVIDIA kernel module from 570.x was still loaded while the installed driver stack was 555.42.06.
- `apt --fix-broken install` initially failed because `libnvidia-compute-570` and `libnvidia-common-570-server` tried to install the same file (`/usr/share/nvidia/files.d/sandboxutils-filelist.json`).

### Fix process
1. Run the setup script; it failed during dependency repair.
   - Command: `sudo ./container/fix_nvidia_setup.sh`

2. Repair apt dependency state (with a force-overwrite to resolve the file collision).
   - Commands:
     - `sudo apt --fix-broken install -y`
     - `sudo apt -o Dpkg::Options::="--force-overwrite" --fix-broken install -y`

3. Rerun the setup script (succeeds).
   - Command: `sudo ./container/fix_nvidia_setup.sh`

4. Validate kernel module version vs. user-space version.
   - Kernel module was 570.x initially:
     - `cat /proc/driver/nvidia/version`
   - Reload modules to match 555.42.06:
     - `sudo modprobe -r nvidia_drm nvidia_uvm nvidia_modeset nvidia`
     - `sudo modprobe nvidia && sudo modprobe nvidia_modeset && sudo modprobe nvidia_uvm && sudo modprobe nvidia_drm`

5. Validate on host and in Docker.
   - `nvidia-smi`
   - `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`

6. Cleanup orphaned CUDA 12.8 packages.
   - `sudo apt autoremove -y`

### Final state
- `nvidia-smi` works on host.
- Docker GPU runtime works.
- NVIDIA kernel module and user-space libraries are aligned at `555.42.06`.
- CUDA 12.8 packages that were pulled in during failed attempts were removed.

### Notes
- Fix log from the script: `container/logs/nvidia_fix_20260126_194350.log`.
- If this recurs, check for mixed NVIDIA kernel modules with:
  - `cat /proc/driver/nvidia/version`
  - `modinfo -F version nvidia`
  
