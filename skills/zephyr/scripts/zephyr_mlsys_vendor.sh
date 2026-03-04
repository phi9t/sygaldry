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
  zephyr_mlsys_vendor.sh install --target-repo <path> [--snapshot-ref <ref>] [--force]
  zephyr_mlsys_vendor.sh update  --target-repo <path>
  zephyr_mlsys_vendor.sh check   --target-repo <path>

Options:
  --target-repo <path>   Target repository root.
  --snapshot-ref <ref>   Digest-pinned snapshot ref written into config.yaml as base_image.
                         Required for install; ignored for update and check.
  --force                Allow install over existing runtime kit.

Installs build-mlsys.sh, launch-mlsys.sh, _build_helper.py, container scripts,
and a config.yaml template into .zephyr-mlsys/ in the target repository.

After install, edit .zephyr-mlsys/config.yaml to set base_image and
image, then run .zephyr-mlsys/bin/build-mlsys.sh to build the image.
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

copy_scripts() {
    local target_kit="$1"

    mkdir -p "${target_kit}/bin"
    mkdir -p "${target_kit}/container"

    # Bin scripts
    cp -a "${RUNTIME_SRC}/bin/build-mlsys.sh" "${target_kit}/bin/"
    cp -a "${RUNTIME_SRC}/bin/launch-mlsys.sh" "${target_kit}/bin/"
    cp -a "${RUNTIME_SRC}/bin/_build_helper.py" "${target_kit}/bin/"

    chmod +x "${target_kit}/bin/build-mlsys.sh"
    chmod +x "${target_kit}/bin/launch-mlsys.sh"

    # Container scripts (COPYed into Docker image at build time)
    cp -a "${RUNTIME_SRC}/container/entrypoint.sh" "${target_kit}/container/"
    cp -a "${RUNTIME_SRC}/container/run-job.sh" "${target_kit}/container/"

    chmod +x "${target_kit}/container/entrypoint.sh"
    chmod +x "${target_kit}/container/run-job.sh"
}

write_config_template() {
    local target_kit="$1"
    local snapshot_ref="$2"
    local target_repo="$3"
    local config_file="${target_kit}/config.yaml"

    cp "${RUNTIME_SRC}/templates/config.yaml.template" "${config_file}"

    if [[ -n "${snapshot_ref}" ]]; then
        # Substitute the digest placeholder with the actual ref
        sed -i "s|sygaldry/zephyr:spack@sha256:REPLACE_WITH_DIGEST|${snapshot_ref}|" "${config_file}"
    fi

    # Auto-detect pyproject.toml and pre-fill config
    if [[ -f "${target_repo}/pyproject.toml" ]]; then
        log "Detected pyproject.toml in target repo"
        # Check for mlsys or gpu extras
        local has_mlsys_extra=0
        if python3 -c "
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        sys.exit(1)
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
extras = data.get('project', {}).get('optional-dependencies', {})
if 'mlsys' in extras:
    sys.exit(0)
sys.exit(1)
" "${target_repo}/pyproject.toml" 2>/dev/null; then
            has_mlsys_extra=1
        fi

        if [[ "${has_mlsys_extra}" -eq 1 ]]; then
            log "Found [project.optional-dependencies.mlsys] -- pre-filling config"
            sed -i '/^python_deps:/,/^[^ #]/{
                /^python_deps:/c\python_deps:\n  pyproject: pyproject.toml\n  extras: [mlsys]
                /^  packages:/d
                /^    - /d
            }' "${config_file}"
        else
            log "Found pyproject.toml but no 'mlsys' extra -- using inline packages (edit config.yaml)"
        fi
    fi

    # Auto-detect project name for image tag
    local project_name
    project_name="$(basename "${target_repo}")"
    if [[ "${project_name}" != "REPLACE_WITH_YOUR_PROJECT" ]]; then
        sed -i "s|REPLACE_WITH_YOUR_PROJECT|${project_name}|" "${config_file}"
    fi
}

write_justfile() {
    local target_kit="$1"
    cp "${RUNTIME_SRC}/templates/justfile.template" "${target_kit}/justfile"
}

migrate_old_kit_dir() {
    local target_repo="$1"
    local old_kit="${target_repo}/.codex-zephyr-mlsys"
    local new_kit="${target_repo}/.zephyr-mlsys"

    if [[ -d "${old_kit}" ]] && [[ ! -d "${new_kit}" ]]; then
        log "Migrating .codex-zephyr-mlsys/ -> .zephyr-mlsys/"
        mv "${old_kit}" "${new_kit}"
        log "Migration complete. Old directory renamed."
    elif [[ -d "${old_kit}" ]] && [[ -d "${new_kit}" ]]; then
        log "WARNING: Both .codex-zephyr-mlsys/ and .zephyr-mlsys/ exist."
        log "Using .zephyr-mlsys/; remove .codex-zephyr-mlsys/ manually."
    fi
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
        --help | -h)
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

TARGET_KIT="${TARGET_REPO}/.zephyr-mlsys"
CONFIG_FILE="${TARGET_KIT}/config.yaml"

case "${MODE}" in
    install | update | check) ;;
    *) err "Unknown mode: ${MODE}. Use install|update|check." ;;
esac

# --- check mode ---
if [[ "${MODE}" == "check" ]]; then
    [[ -d "${TARGET_KIT}" ]] || err "Missing kit: ${TARGET_KIT}"
    [[ -f "${CONFIG_FILE}" ]] || err "Missing config.yaml: ${CONFIG_FILE}"
    [[ -x "${TARGET_KIT}/bin/build-mlsys.sh" ]] || err "Missing build script"
    [[ -x "${TARGET_KIT}/bin/launch-mlsys.sh" ]] || err "Missing launch script"
    [[ -f "${TARGET_KIT}/bin/_build_helper.py" ]] || err "Missing _build_helper.py"
    [[ -f "${TARGET_KIT}/container/entrypoint.sh" ]] || err "Missing container/entrypoint.sh"
    [[ -f "${TARGET_KIT}/container/run-job.sh" ]] || err "Missing container/run-job.sh"

    base_image="$(read_yaml_value "${CONFIG_FILE}" base_image)"
    [[ -n "${base_image}" ]] || err "config.yaml: base_image is not set"
    [[ "${base_image}" != *REPLACE_WITH_DIGEST* ]] \
        || err "config.yaml: base_image still has placeholder -- edit ${CONFIG_FILE}"

    image="$(read_yaml_value "${CONFIG_FILE}" image)"
    [[ -n "${image}" ]] || err "config.yaml: image is not set"
    [[ "${image}" != *REPLACE_WITH* ]] \
        || err "config.yaml: image still has placeholder -- edit ${CONFIG_FILE}"

    log "check passed"
    log "target=${TARGET_KIT}"
    log "base_image=${base_image}"
    log "image=${image}"
    exit 0
fi

# --- install mode ---
if [[ "${MODE}" == "install" ]]; then
    # Migrate old directory name if present
    migrate_old_kit_dir "${TARGET_REPO}"

    if [[ -d "${TARGET_KIT}" ]] && [[ ${FORCE} -ne 1 ]]; then
        err "Target kit already exists: ${TARGET_KIT} (use --force to reinstall)"
    fi
    if [[ -n "${SNAPSHOT_REF}" ]]; then
        require_digest_ref "${SNAPSHOT_REF}"
    fi

    rm -rf "${TARGET_KIT}"
    copy_scripts "${TARGET_KIT}"
    write_config_template "${TARGET_KIT}" "${SNAPSHOT_REF}" "${TARGET_REPO}"
    write_justfile "${TARGET_KIT}"

    log "install complete"
    log "target=${TARGET_KIT}"
    if [[ -n "${SNAPSHOT_REF}" ]]; then
        log "base_image written: ${SNAPSHOT_REF}"
    else
        log "next: edit ${CONFIG_FILE} to set base_image and image"
    fi
    log "then: ${TARGET_KIT}/bin/build-mlsys.sh"
    exit 0
fi

# --- update mode ---
# Migrate old directory name if present
migrate_old_kit_dir "${TARGET_REPO}"

[[ -d "${TARGET_KIT}" ]] || err "No kit found at ${TARGET_KIT}. Run install first."

# Re-copy scripts only; preserve config.yaml so user edits survive.
copy_scripts "${TARGET_KIT}"
write_justfile "${TARGET_KIT}"

log "update complete (scripts updated; config.yaml preserved)"
log "target=${TARGET_KIT}"
log "re-run: ${TARGET_KIT}/bin/build-mlsys.sh"
