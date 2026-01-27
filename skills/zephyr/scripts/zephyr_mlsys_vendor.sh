#!/bin/bash
# Install/update/check vendored MLSys runtime kit in a target repo.
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SKILL_ROOT
RUNTIME_SRC="${SKILL_ROOT}/assets/zephyr-mlsys-runtime"
readonly RUNTIME_SRC

usage() {
    cat <<'USAGE'
Usage:
  zephyr_mlsys_vendor.sh install --target-repo <path> --snapshot-ref <ref> [--force]
  zephyr_mlsys_vendor.sh update  --target-repo <path> --snapshot-ref <ref>
  zephyr_mlsys_vendor.sh check   --target-repo <path>

Options:
  --target-repo <path>   Target repository root.
  --snapshot-ref <ref>   Digest-pinned snapshot image reference.
  --force                Allow install over existing runtime kit.
USAGE
}

log() {
    echo "[zephyr-mlsys-vendor] $*" >&2
}

err() {
    log "ERROR: $*"
    exit 1
}

require_digest_ref() {
    local ref="$1"
    [[ -n "${ref}" ]] || err "snapshot ref is empty"
    [[ "${ref}" == *@sha256:* ]] || err "snapshot ref must include @sha256: digest"
    local digest
    digest="${ref##*@sha256:}"
    [[ "${digest}" =~ ^[a-f0-9]{64}$ ]] || err "invalid digest: ${digest}"
}

read_yaml_value() {
    local file="$1"
    local key="$2"
    awk -F ':' -v want="${key}" '
        $0 ~ "^[[:space:]]*" want "[[:space:]]*:[[:space:]]*" {
            sub("^[[:space:]]*" want "[[:space:]]*:[[:space:]]*", "", $0)
            sub(/[[:space:]]+#.*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            gsub(/^"|"$/, "", $0)
            print $0
            exit
        }
    ' "${file}"
}

copy_runtime_kit() {
    local target_kit="$1"

    mkdir -p "${target_kit}/bin" "${target_kit}/scripts" "${target_kit}/envs" "${target_kit}/container_entrypoints"

    cp -a "${RUNTIME_SRC}/bin/launch-mlsys.sh" "${target_kit}/bin/"
    cp -a "${RUNTIME_SRC}/container_entrypoints/." "${target_kit}/container_entrypoints/"

    cp -a "${SKILL_ROOT}/scripts/uv-env-build.sh" "${target_kit}/scripts/"
    cp -a "${SKILL_ROOT}/scripts/uv-env-validate.sh" "${target_kit}/scripts/"
    cp -a "${SKILL_ROOT}/scripts/uv-env-activate.sh" "${target_kit}/scripts/"
    cp -a "${SKILL_ROOT}/scripts/parse-env-yaml.py" "${target_kit}/scripts/"

    cp -a "${SKILL_ROOT}/envs/." "${target_kit}/envs/"

    chmod +x "${target_kit}/bin/launch-mlsys.sh"
    chmod +x "${target_kit}/scripts/"*.sh
    chmod +x "${target_kit}/container_entrypoints/"*.sh
}

write_runtime_config() {
    local target_kit="$1"
    local snapshot_ref="$2"
    local built_at_utc
    built_at_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    cat > "${target_kit}/runtime.yaml" <<EOF_YAML
snapshot_ref: ${snapshot_ref}
installed_by: zephyr
installed_at_utc: ${built_at_utc}
EOF_YAML
}

MODE="${1:-}"
[[ -n "${MODE}" ]] || {
    usage
    exit 2
}
if [[ "${MODE}" == "--help" || "${MODE}" == "-h" || "${MODE}" == "help" ]]; then
    usage
    exit 0
fi
shift || true

TARGET_REPO=""
SNAPSHOT_REF=""
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-repo)
            TARGET_REPO="${2:-}"
            shift 2
            ;;
        --snapshot-ref)
            SNAPSHOT_REF="${2:-}"
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

[[ -d "${RUNTIME_SRC}" ]] || err "Runtime source missing: ${RUNTIME_SRC}"

[[ -n "${TARGET_REPO}" ]] || err "--target-repo is required"
TARGET_REPO="$(realpath "${TARGET_REPO}")"
[[ -d "${TARGET_REPO}" ]] || err "Target repo not found: ${TARGET_REPO}"

TARGET_KIT="${TARGET_REPO}/.codex-zephyr-mlsys"
RUNTIME_CONFIG="${TARGET_KIT}/runtime.yaml"

case "${MODE}" in
    install|update|check)
        ;;
    *)
        err "Unknown mode: ${MODE}. Use install|update|check."
        ;;
esac

if [[ "${MODE}" == "check" ]]; then
    [[ -d "${TARGET_KIT}" ]] || err "Missing kit: ${TARGET_KIT}"
    [[ -f "${RUNTIME_CONFIG}" ]] || err "Missing runtime config: ${RUNTIME_CONFIG}"
    [[ -x "${TARGET_KIT}/bin/launch-mlsys.sh" ]] || err "Missing launcher"
    [[ -x "${TARGET_KIT}/scripts/uv-env-build.sh" ]] || err "Missing builder"
    [[ -x "${TARGET_KIT}/scripts/uv-env-validate.sh" ]] || err "Missing validator"
    [[ -f "${TARGET_KIT}/scripts/parse-env-yaml.py" ]] || err "Missing YAML parser"
    [[ -f "${TARGET_KIT}/container_entrypoints/uv-install.sh" ]] || err "Missing uv-install"

    configured_ref="$(read_yaml_value "${RUNTIME_CONFIG}" snapshot_ref)"
    require_digest_ref "${configured_ref}"

    log "check passed"
    log "target=${TARGET_KIT}"
    log "snapshot_ref=${configured_ref}"
    exit 0
fi

[[ -n "${SNAPSHOT_REF}" ]] || err "--snapshot-ref is required for ${MODE}"
require_digest_ref "${SNAPSHOT_REF}"

if [[ -d "${TARGET_KIT}" ]] && [[ "${MODE}" == "install" ]] && [[ ${FORCE} -ne 1 ]]; then
    err "Target kit already exists: ${TARGET_KIT} (use --force)"
fi

if [[ -d "${TARGET_KIT}" ]]; then
    rm -rf "${TARGET_KIT}"
fi

copy_runtime_kit "${TARGET_KIT}"
write_runtime_config "${TARGET_KIT}" "${SNAPSHOT_REF}"

log "${MODE} complete"
log "target=${TARGET_KIT}"
log "snapshot_ref=${SNAPSHOT_REF}"
log "next: ${TARGET_KIT}/bin/launch-mlsys.sh hf-transformers"
