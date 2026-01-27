#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SKILL_ROOT
SKILL_NAME="$(basename "${SKILL_ROOT}")"
readonly SKILL_NAME
REPO_ROOT="$(cd "${SKILL_ROOT}/../.." && pwd)"
readonly REPO_ROOT

usage() {
    cat <<'USAGE'
Usage:
  package_skill.sh --out-dir <path> --version <version> [options]

Options:
  --out-dir <path>       Output directory for packaged artifacts (required).
  --version <value>      Artifact version string (required).
  --snapshot-ref <ref>   Digest-pinned snapshot image for full smoke mode.
  --smoke-mode <mode>    full|skip (default: full).
  --force                Overwrite existing artifacts.

Outputs:
  <out-dir>/zephyr-<version>.tar.gz
  <out-dir>/zephyr-<version>.SHA256SUMS
  <out-dir>/zephyr-<version>.provenance.json
USAGE
}

log() {
    echo "[package-skill] $*" >&2
}

err() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

require_digest_ref() {
    local ref="$1"
    [[ -n "${ref}" ]] || err "snapshot ref is empty"
    [[ "${ref}" == *@sha256:* ]] || err "snapshot ref must include @sha256: digest"
    local digest
    digest="${ref##*@sha256:}"
    [[ "${digest}" =~ ^[a-f0-9]{64}$ ]] || err "invalid digest: ${digest}"
}

OUT_DIR=""
VERSION=""
SNAPSHOT_REF=""
SMOKE_MODE="full"
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir)
            OUT_DIR="${2:-}"
            shift 2
            ;;
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --snapshot-ref)
            SNAPSHOT_REF="${2:-}"
            shift 2
            ;;
        --smoke-mode)
            SMOKE_MODE="${2:-}"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            err "Unknown argument: $1"
            ;;
    esac
done

[[ -n "${OUT_DIR}" ]] || err "--out-dir is required"
[[ -n "${VERSION}" ]] || err "--version is required"
case "${SMOKE_MODE}" in
    full|skip)
        ;;
    *)
        err "--smoke-mode must be full|skip"
        ;;
esac

require_cmd bash
require_cmd tar
require_cmd sha256sum
require_cmd find
require_cmd python3

mkdir -p "${OUT_DIR}"
OUT_DIR="$(realpath "${OUT_DIR}")"
readonly OUT_DIR

artifact="${OUT_DIR}/${SKILL_NAME}-${VERSION}.tar.gz"
artifact_manifest="${OUT_DIR}/${SKILL_NAME}-${VERSION}.SHA256SUMS"
artifact_provenance="${OUT_DIR}/${SKILL_NAME}-${VERSION}.provenance.json"

if [[ ${FORCE} -ne 1 ]]; then
    [[ ! -e "${artifact}" ]] || err "Artifact already exists: ${artifact}"
    [[ ! -e "${artifact_manifest}" ]] || err "Manifest already exists: ${artifact_manifest}"
    [[ ! -e "${artifact_provenance}" ]] || err "Provenance already exists: ${artifact_provenance}"
fi

log "Running static checks"
bash -n "${SKILL_ROOT}/scripts/"*.sh
bash -n "${SKILL_ROOT}/portable/"*.sh
bash -n "${SKILL_ROOT}/assets/zephyr-mlsys-runtime/bin/"*.sh
bash -n "${SKILL_ROOT}/assets/zephyr-mlsys-runtime/container_entrypoints/"*.sh
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s bash -S warning "${SKILL_ROOT}/scripts/"*.sh "${SKILL_ROOT}/portable/"*.sh \
        "${SKILL_ROOT}/assets/zephyr-mlsys-runtime/bin/"*.sh \
        "${SKILL_ROOT}/assets/zephyr-mlsys-runtime/container_entrypoints/"*.sh
else
    log "shellcheck not found; skipping"
fi
python3 -m py_compile "${SKILL_ROOT}/scripts/"*.py
"${SKILL_ROOT}/scripts/validate_hermetic_mlsys.sh" "${SKILL_ROOT}"

DUMMY_SNAPSHOT_REF="ghcr.io/example/zephyr:spack@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

run_local_smoke() {
    local temp_repo
    temp_repo="$(mktemp -d)"
    mkdir -p "${temp_repo}/repo"

    "${SKILL_ROOT}/scripts/zephyr_mlsys_vendor.sh" install \
        --target-repo "${temp_repo}/repo" \
        --snapshot-ref "${DUMMY_SNAPSHOT_REF}" \
        --force
    "${SKILL_ROOT}/scripts/zephyr_mlsys_vendor.sh" check \
        --target-repo "${temp_repo}/repo"

    "${temp_repo}/repo/.codex-zephyr-mlsys/scripts/uv-env-build.sh" --help >/dev/null
}

run_full_smoke() {
    local smoke_snapshot_ref="$1"
    [[ -n "${smoke_snapshot_ref}" ]] || err "--snapshot-ref is required for --smoke-mode full"
    require_digest_ref "${smoke_snapshot_ref}"
    require_cmd docker
    docker info >/dev/null 2>&1 || err "Docker daemon is not available"

    local temp_repo
    temp_repo="$(mktemp -d)"
    mkdir -p "${temp_repo}/repo"

    "${SKILL_ROOT}/scripts/zephyr_mlsys_vendor.sh" install \
        --target-repo "${temp_repo}/repo" \
        --snapshot-ref "${smoke_snapshot_ref}" \
        --force

    MLSYS_DISABLE_GPU=1 "${temp_repo}/repo/.codex-zephyr-mlsys/bin/launch-mlsys.sh" hf-transformers --no-validate
}

log "Running runtime smoke checks"
run_local_smoke
if [[ "${SMOKE_MODE}" == "full" ]]; then
    run_full_smoke "${SNAPSHOT_REF}"
else
    log "Skipping full container smoke checks (--smoke-mode skip)"
fi

stage_parent="$(mktemp -d)"
stage_skill="${stage_parent}/${SKILL_NAME}"

log "Staging package content"
mkdir -p "${stage_skill}"
cp -a "${SKILL_ROOT}/SKILL.md" "${stage_skill}/"
cp -a "${SKILL_ROOT}/agents" "${stage_skill}/"
cp -a "${SKILL_ROOT}/scripts" "${stage_skill}/"
cp -a "${SKILL_ROOT}/envs" "${stage_skill}/"
cp -a "${SKILL_ROOT}/portable" "${stage_skill}/"
cp -a "${SKILL_ROOT}/assets" "${stage_skill}/"
cp -a "${SKILL_ROOT}/references" "${stage_skill}/"
cp -a "${SKILL_ROOT}/VALIDATION.md" "${stage_skill}/"
find "${stage_skill}" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "${stage_skill}" -type f -name '*.pyc' -delete
chmod +x "${stage_skill}/scripts/"*.sh
chmod +x "${stage_skill}/portable/"*.sh
chmod +x "${stage_skill}/assets/zephyr-mlsys-runtime/bin/"*.sh
chmod +x "${stage_skill}/assets/zephyr-mlsys-runtime/container_entrypoints/"*.sh

manifest_file="${stage_skill}/SHA256SUMS"
provenance_file="${stage_skill}/provenance.json"

(
    cd "${stage_parent}"
    find "${SKILL_NAME}" -type f ! -name 'SHA256SUMS' ! -name 'provenance.json' \
        | LC_ALL=C sort \
        | while read -r rel_path; do
            hash="$(sha256sum "${rel_path}" | awk '{print $1}')"
            printf "%s  %s\n" "${hash}" "${rel_path}"
        done > "${manifest_file}"
)

source_repo="$(git -C "${REPO_ROOT}" config --get remote.origin.url 2>/dev/null || echo unknown)"
source_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
if git -C "${REPO_ROOT}" diff --quiet && git -C "${REPO_ROOT}" diff --cached --quiet; then
    source_tree_dirty="false"
else
    source_tree_dirty="true"
fi
build_timestamp_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
builder_tool="skills/zephyr/scripts/package_mlsys.sh"

python3 - "${stage_parent}" "${manifest_file}" "${provenance_file}" "${SKILL_NAME}" "${VERSION}" "${source_repo}" "${source_commit}" "${source_tree_dirty}" "${build_timestamp_utc}" "${builder_tool}" <<'PY'
import json
import os
import sys

base_dir = sys.argv[1]
manifest_path = sys.argv[2]
provenance_path = sys.argv[3]
skill_name = sys.argv[4]
skill_version = sys.argv[5]
source_repo = sys.argv[6]
source_commit = sys.argv[7]
source_tree_dirty = sys.argv[8].lower() == "true"
build_timestamp_utc = sys.argv[9]
builder_tool = sys.argv[10]

entries = []
with open(manifest_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        digest, rel_path = line.split("  ", 1)
        full_path = os.path.join(base_dir, rel_path)
        entries.append(
            {
                "path": rel_path,
                "sha256": digest,
                "size_bytes": os.path.getsize(full_path),
            }
        )

payload = {
    "schema_version": "zephyr-mlsys-provenance/v1",
    "skill_name": skill_name,
    "skill_version": skill_version,
    "source_repo": source_repo,
    "source_commit": source_commit,
    "source_tree_dirty": source_tree_dirty,
    "build_timestamp_utc": build_timestamp_utc,
    "builder_tool": builder_tool,
    "excluded_patterns": ["SHA256SUMS", "provenance.json"],
    "runtime_contract": {
        "no_repo_runtime_dependency": True,
        "required_clis": ["bash", "python3", "docker", "git", "sha256sum"],
        "required_python_packages": ["PyYAML"],
    },
    "included_files": entries,
}

with open(provenance_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

log "Creating deterministic tarball"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -czf "${artifact}" -C "${stage_parent}" "${SKILL_NAME}"

sha256sum "${artifact}" > "${artifact}.sha256"
cp "${manifest_file}" "${artifact_manifest}"
cp "${provenance_file}" "${artifact_provenance}"

tar -tf "${artifact}" >/dev/null

log "Validating packaged artifact runtime independence"
artifact_extract_root="$(mktemp -d)"
tar -xzf "${artifact}" -C "${artifact_extract_root}"
packaged_skill="${artifact_extract_root}/${SKILL_NAME}"
"${packaged_skill}/scripts/validate_hermetic_mlsys.sh" "${packaged_skill}"
artifact_target="$(mktemp -d)"
mkdir -p "${artifact_target}/repo"
"${packaged_skill}/scripts/zephyr_mlsys_vendor.sh" install \
    --target-repo "${artifact_target}/repo" \
    --snapshot-ref "${DUMMY_SNAPSHOT_REF}" \
    --force
"${packaged_skill}/scripts/zephyr_mlsys_vendor.sh" check --target-repo "${artifact_target}/repo"

log "Packaging complete"
log "artifact=${artifact}"
log "manifest=${artifact_manifest}"
log "provenance=${artifact_provenance}"
