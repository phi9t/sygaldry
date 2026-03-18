# RFC-016: K3s YAML Path Externalization

**Status:** Proposed
**Files:** `k3s/templates/`, `k3s/manifests/`, `k3s/bootstrap/setup-nvidia.sh`, `k3s/bin/kentai`

---

## Problem

The K3s integration layer hardcodes the `/mnt/data_infra` host path throughout
YAML templates and bootstrap scripts. This makes it impossible to run the K3s
setup on a host with a different data root without editing multiple files. The
device plugin version is pinned by URL with no integrity check. The default
project ID is derived from the current directory name, creating an implicit
coupling that can produce collisions.

---

## Key Findings

### 1. `/mnt/data_infra` hardcoded 8+ times across YAML templates

`k3s/templates/dev-pod.yaml` contains 14 `hostPath` volume entries. Every one
hardcodes an absolute path rooted at `/mnt/data_infra`:

```yaml
# k3s/templates/dev-pod.yaml:115-117
- name: home
  hostPath:
    path: /mnt/data_infra/zephyr_container_infra/projects/${PROJECT_ID}/home
    type: DirectoryOrCreate
```

The pattern repeats for `config`, `local-share`, `outputs`, `workspace` (per-project),
`hf-cache`, `uv-cache`, `bazel-cache`, `torch-cache`, `triton-cache`,
`nv-compute-cache`, `jax-cache` (shared caches), `spack-store`, and
`sygaldry-repo`. The same paths appear verbatim in `k3s/templates/job.yaml`
(lines 117–176) and `k3s/templates/dev-pod-multirepo.yaml`.

In `k3s/lib/k3s-common.sh` (lines 23–26), the same root is expressed as a
defaulted variable:

```bash
# k3s/lib/k3s-common.sh:23-26
readonly ZEPHYR_CACHE_ROOT="${ZEPHYR_CACHE_ROOT:-/mnt/data_infra/zephyr_container_infra}"
readonly ZEPHYR_SHARED_ROOT="${ZEPHYR_SHARED_ROOT:-${ZEPHYR_CACHE_ROOT}/shared}"
readonly ZEPHYR_PROJECTS_ROOT="${ZEPHYR_PROJECTS_ROOT:-${ZEPHYR_CACHE_ROOT}/projects}"
readonly ZEPHYR_BUILD_ROOT="${ZEPHYR_BUILD_ROOT:-${ZEPHYR_CACHE_ROOT}/sygaldry}"
```

The shell scripts honour the `ZEPHYR_CACHE_ROOT` override, but YAML templates
do not — `envsubst` expands only the variables listed in their comment headers
(`PROJECT_ID`, `HOST_UID`, `HOST_GID`, `CONTAINER_IMAGE`, `GPU_COUNT`).

Counted occurrences of the literal string `/mnt/data_infra` in K3s files:
- `k3s/templates/dev-pod.yaml`: 14 occurrences
- `k3s/templates/job.yaml`: 14 occurrences
- `k3s/templates/dev-pod-multirepo.yaml`: 15 occurrences
- `k3s/lib/k3s-common.sh`: 1 occurrence (as default)

### 2. NVIDIA device plugin pinned by URL with no integrity check

`k3s/bootstrap/setup-nvidia.sh` line 73–75:

```bash
# k3s/bootstrap/setup-nvidia.sh:73-75
DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml"
log "Deploying NVIDIA k8s-device-plugin v0.17.0..."
kubectl apply -f "${DEVICE_PLUGIN_URL}"
```

The URL is fetched and applied directly to the live cluster with no SHA256
verification. A MITM or CDN compromise would silently deploy a tampered
manifest. The version string `v0.17.0` is embedded in the URL literal, making
upgrades a search-and-replace operation rather than a single constant change.

### 3. `kentai` uses `basename "$PWD"` as default project ID

`k3s/bin/kentai` line 29:

```bash
# k3s/bin/kentai:29
PROJECT_ID="${SYGALDRY_PROJECT_ID:-$(basename "${PWD}")}"
```

When a user runs `kentai` from a common directory name (e.g., `src`, `workspace`,
or `sygaldry`), the derived project ID can collide with pods created by other
users or other projects on the same cluster node. The implicit default is
invisible to users unfamiliar with this behaviour; `--help` output says
"default: current directory name" but does not warn about collision risk.

---

## Proposed Changes

### 1. Add path variables to `envsubst` expansion in templates

Add `ZEPHYR_CACHE_ROOT`, `ZEPHYR_PROJECTS_ROOT`, `ZEPHYR_SHARED_ROOT`, and
`ZEPHYR_BUILD_ROOT` to the template variable set, and replace every hardcoded
path with the corresponding variable:

```yaml
# k3s/templates/dev-pod.yaml (proposed)
- name: home
  hostPath:
    path: ${ZEPHYR_PROJECTS_ROOT}/${PROJECT_ID}/home
    type: DirectoryOrCreate
```

Export the variables from `k3s-common.sh` before calling `envsubst`, since
`k3s-common.sh` already defines them:

```bash
# k3s/lib/k3s-common.sh (add export)
export ZEPHYR_CACHE_ROOT ZEPHYR_SHARED_ROOT ZEPHYR_PROJECTS_ROOT ZEPHYR_BUILD_ROOT
```

The `kentai` `create_pod` function passes variables via `export` before calling
`envsubst < "${template}"`, so this is the natural insertion point.

### 2. Extract a `paths.env` file for documentation

Create `k3s/lib/paths.env` as a sourced defaults file:

```bash
# k3s/lib/paths.env
# Canonical host-side path defaults for K3s integration.
# Override by setting environment variables before running kentai or bootstrap scripts.
: "${ZEPHYR_CACHE_ROOT:=/mnt/data_infra/zephyr_container_infra}"
: "${ZEPHYR_SHARED_ROOT:=${ZEPHYR_CACHE_ROOT}/shared}"
: "${ZEPHYR_PROJECTS_ROOT:=${ZEPHYR_CACHE_ROOT}/projects}"
: "${ZEPHYR_BUILD_ROOT:=${ZEPHYR_CACHE_ROOT}/sygaldry}"
```

Source this file from `k3s-common.sh` and from `setup-nvidia.sh`. All host
path logic is then centralized in one file.

### 3. Add SHA256 verification for the device plugin manifest

Download the manifest to a temporary file and verify before applying:

```bash
DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml"
DEVICE_PLUGIN_SHA256="<known-sha256>"

tmp_manifest="$(mktemp)"
curl -fsSL "${DEVICE_PLUGIN_URL}" -o "${tmp_manifest}"
echo "${DEVICE_PLUGIN_SHA256}  ${tmp_manifest}" | sha256sum -c -
kubectl apply -f "${tmp_manifest}"
rm -f "${tmp_manifest}"
```

The SHA256 should be computed from the canonical download and stored as a
constant in `setup-nvidia.sh`.

### 4. Require explicit project ID in `kentai`

Remove the `basename "$PWD"` default and require `--project-id` or
`SYGALDRY_PROJECT_ID` to be set:

```bash
# k3s/bin/kentai (proposed)
PROJECT_ID="${SYGALDRY_PROJECT_ID:-}"

# After parse_args:
if [[ -z "${PROJECT_ID}" ]]; then
    die "--project-id is required (or set SYGALDRY_PROJECT_ID)"
fi
```

Update the help text accordingly.

---

## Files Changed

| File | Action |
|------|--------|
| `k3s/lib/k3s-common.sh` | Export path variables, source `paths.env` |
| `k3s/lib/paths.env` | New — canonical path defaults |
| `k3s/templates/dev-pod.yaml` | Replace hardcoded paths with `${ZEPHYR_*}` variables |
| `k3s/templates/dev-pod-multirepo.yaml` | Same |
| `k3s/templates/job.yaml` | Same |
| `k3s/bootstrap/setup-nvidia.sh` | Add SHA256 verification, source `paths.env` |
| `k3s/bin/kentai` | Require explicit project ID |

---

## Verification

```bash
# Verify templates expand correctly with a custom root
ZEPHYR_CACHE_ROOT=/tmp/test-infra \
ZEPHYR_PROJECTS_ROOT=/tmp/test-infra/projects \
ZEPHYR_SHARED_ROOT=/tmp/test-infra/shared \
ZEPHYR_BUILD_ROOT=/tmp/test-infra/sygaldry \
PROJECT_ID=test HOST_UID=1000 HOST_GID=1000 \
CONTAINER_IMAGE=sygaldry/zephyr:base GPU_COUNT=1 \
envsubst < k3s/templates/dev-pod.yaml | grep '/mnt/data_infra'
# Expected: no output (no hardcoded paths remain)

shellcheck -s bash -S warning k3s/bootstrap/setup-nvidia.sh k3s/bin/kentai k3s/lib/k3s-common.sh
```
