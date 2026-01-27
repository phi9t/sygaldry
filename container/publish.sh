#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

readonly REGISTRY_BASE="ghcr.io/phi9t/sygaldry/zephyr"
readonly LOCAL_BASE="sygaldry/zephyr"
readonly DEFAULT_IMAGES="spack hf hf-datasets vllm sglang torchtitan megatronlm mlsys"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [publish:${BASH_LINENO[0]}] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Missing command: $1"
}

json_escape() {
    python3 - "$1" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1]))
PY
}

manifest_digest_for_ref() {
    local ref="$1"
    local out
    out="$(docker buildx imagetools inspect "${ref}" 2>/dev/null | sed -n 's/^Digest:[[:space:]]*//p' | head -1)"
    if [[ -n "${out}" ]]; then
        echo "${out}"
        return 0
    fi
    return 1
}

emit_manifest() {
    local release_id="$1"
    local candidate_suffix="$2"
    local out_path="$3"
    local images_csv="$4"

    mkdir -p "$(dirname "${out_path}")"

    local now_utc
    now_utc="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    local json
    json="{\"schema_version\":\"sygaldry-zephyr-image-set/v1\",\"release_id\":$(json_escape "${release_id}"),\"generated_at_utc\":$(json_escape "${now_utc}"),\"registry_base\":$(json_escape "${REGISTRY_BASE}"),\"images\":["

    local first=true
    local name
    IFS=',' read -r -a names <<<"${images_csv}"
    for name in "${names[@]}"; do
        name="$(echo "${name}" | xargs)"
        [[ -z "${name}" ]] && continue

        local stable_tag="${name}"
        local candidate_tag="${name}-${candidate_suffix}"
        local source_ref="${REGISTRY_BASE}:${candidate_tag}"
        local digest=""
        if ! digest="$(manifest_digest_for_ref "${source_ref}")"; then
            error "Candidate tag not resolvable: ${source_ref}"
        fi

        if [[ "${first}" == "true" ]]; then
            first=false
        else
            json+=","
        fi

        json+="{\"name\":$(json_escape "${name}"),\"stable_tag\":$(json_escape "${stable_tag}"),\"candidate_tag\":$(json_escape "${candidate_tag}"),\"source_ref\":$(json_escape "${source_ref}"),\"source_digest\":$(json_escape "${digest}")}" 
    done

    json+="]}"

    printf '%s\n' "${json}" > "${out_path}"
    python3 -m json.tool "${out_path}" >/dev/null
}

usage() {
    cat <<USAGE
Usage:
  $0 <command> [options]

Commands:
  build-candidates   Build candidate images and emit release manifest
  verify-candidates  Verify candidate tags from release manifest
  promote            Promote candidate digests to moving tags
  rollback           Re-apply moving tags from a prior release manifest

Global options:
  --dry-run          Print actions only

build-candidates options:
  --release-id ID                Release identifier (default: UTC timestamp)
  --candidate-suffix SUFFIX      Candidate suffix (default: <date>-<shortsha>)
  --images CSV                   Comma-separated image names
  --manifest-out PATH            Manifest output path
  --snapshot-image IMAGE         Snapshot image for mlsys builds (default: sygaldry/zephyr:spack)
  --skip-build                   Only emit manifest; do not run builds

verify-candidates options:
  --manifest PATH                Input manifest path (required)

promote options:
  --manifest PATH                Input manifest path (required)
  --tool TOOL                    crane|skopeo (default: crane)

rollback options:
  --manifest PATH                Input manifest path (required)
  --tool TOOL                    crane|skopeo (default: crane)
USAGE
}

resolve_default_release_id() {
    date -u +"%Y%m%d-%H%M%S"
}

resolve_default_candidate_suffix() {
    local shortsha
    shortsha="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo dev)"
    echo "$(date -u +%Y%m%d)-${shortsha}"
}

do_build_candidates() {
    local dry_run="$1"
    shift

    local release_id
    release_id="$(resolve_default_release_id)"
    local suffix
    suffix="$(resolve_default_candidate_suffix)"
    local images_csv="${DEFAULT_IMAGES// /,}"
    local manifest_out=""
    local snapshot_image="${LOCAL_BASE}:spack"
    local skip_build=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --release-id) release_id="${2:-}"; shift 2 ;;
            --candidate-suffix) suffix="${2:-}"; shift 2 ;;
            --images) images_csv="${2:-}"; shift 2 ;;
            --manifest-out) manifest_out="${2:-}"; shift 2 ;;
            --snapshot-image) snapshot_image="${2:-}"; shift 2 ;;
            --skip-build) skip_build=true; shift ;;
            *) error "Unknown build-candidates option: $1" ;;
        esac
    done

    [[ -n "${manifest_out}" ]] || manifest_out="${REPO_ROOT}/container/releases/${release_id}/image-set.json"

    log "build-candidates release_id=${release_id} suffix=${suffix}"
    log "images=${images_csv}"

    if [[ "${skip_build}" != "true" ]]; then
        if [[ "${dry_run}" == "true" ]]; then
            log "DRY RUN: bash ${SCRIPT_DIR}/snapshot_spack.sh --tag ${LOCAL_BASE}:spack --no-verify"
            log "DRY RUN: SYGALDRY_SNAPSHOT_IMAGE=${snapshot_image} bash ${SCRIPT_DIR}/snapshot_mlsys.sh all --no-verify"
            log "DRY RUN: retag/push candidate tags to GHCR"
        else
            bash "${SCRIPT_DIR}/snapshot_spack.sh" --tag "${LOCAL_BASE}:spack" --no-verify
            SYGALDRY_SNAPSHOT_IMAGE="${snapshot_image}" bash "${SCRIPT_DIR}/snapshot_mlsys.sh" all --no-verify

            local name
            IFS=',' read -r -a names <<<"${images_csv}"
            for name in "${names[@]}"; do
                name="$(echo "${name}" | xargs)"
                [[ -z "${name}" ]] && continue
                local local_ref="${LOCAL_BASE}:${name}"
                local candidate_ref="${REGISTRY_BASE}:${name}-${suffix}"
                docker image inspect "${local_ref}" >/dev/null
                docker tag "${local_ref}" "${candidate_ref}"
                docker push "${candidate_ref}"
            done
        fi
    else
        log "Skipping build (--skip-build)"
    fi

    if [[ "${dry_run}" == "true" ]]; then
        log "DRY RUN: emit manifest to ${manifest_out}"
    else
        emit_manifest "${release_id}" "${suffix}" "${manifest_out}" "${images_csv}"
        log "Wrote manifest: ${manifest_out}"
    fi
}

iter_manifest_rows() {
    local manifest="$1"
    python3 - "${manifest}" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
for item in data.get('images', []):
    print("\t".join([
        item['name'],
        item['stable_tag'],
        item['candidate_tag'],
        item['source_ref'],
        item['source_digest'],
    ]))
PY
}

promote_one() {
    local tool="$1"
    local source_ref="$2"
    local stable_tag="$3"
    local target_ref="${REGISTRY_BASE}:${stable_tag}"

    case "${tool}" in
        crane)
            require_cmd crane
            crane copy "${source_ref}" "${target_ref}"
            ;;
        skopeo)
            require_cmd skopeo
            skopeo copy --preserve-digests "docker://${source_ref}" "docker://${target_ref}"
            ;;
        *)
            error "Unsupported promotion tool: ${tool}"
            ;;
    esac
}

do_verify_candidates() {
    local dry_run="$1"
    shift

    local manifest=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --manifest) manifest="${2:-}"; shift 2 ;;
            *) error "Unknown verify-candidates option: $1" ;;
        esac
    done
    [[ -n "${manifest}" ]] || error "--manifest is required"
    [[ -f "${manifest}" ]] || error "Manifest not found: ${manifest}"

    python3 -m json.tool "${manifest}" >/dev/null

    # Schema validation: use check-jsonschema if available, else python jsonschema.
    local schema_file="${SCRIPT_DIR}/releases/image-set.schema.json"
    if [[ -f "${schema_file}" ]]; then
        if command -v check-jsonschema >/dev/null 2>&1; then
            check-jsonschema --schemafile "${schema_file}" "${manifest}"
        elif python3 -c 'import jsonschema' >/dev/null 2>&1; then
            python3 - "${schema_file}" "${manifest}" <<'PY'
import json, sys, jsonschema
schema_path, manifest_path = sys.argv[1], sys.argv[2]
with open(schema_path, 'r', encoding='utf-8') as f:
    schema = json.load(f)
with open(manifest_path, 'r', encoding='utf-8') as f:
    instance = json.load(f)
jsonschema.validate(instance, schema)
print("Schema validation: OK")
PY
        else
            log "WARNING: check-jsonschema and python jsonschema unavailable; skipping schema validation"
            log "  Install with: pip install check-jsonschema  OR  pip install jsonschema"
        fi
    else
        log "WARNING: Schema file not found at ${schema_file}; skipping schema validation"
    fi

    while IFS=$'\t' read -r name stable _candidate source_ref source_digest; do
        [[ -z "${name}" ]] && continue
        if [[ "${dry_run}" == "true" ]]; then
            log "DRY RUN: verify ${source_ref} digest=${source_digest}"
            continue
        fi

        local got
        got="$(manifest_digest_for_ref "${source_ref}" || true)"
        [[ -n "${got}" ]] || error "Missing source manifest: ${source_ref}"
        [[ "${got}" == "${source_digest}" ]] || error "Digest mismatch for ${source_ref}: got=${got} expected=${source_digest}"
        log "OK ${source_ref}"
    done < <(iter_manifest_rows "${manifest}")
}

do_promote_or_rollback() {
    local mode="$1"
    local dry_run="$2"
    shift 2

    local manifest=""
    local tool="crane"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --manifest) manifest="${2:-}"; shift 2 ;;
            --tool) tool="${2:-}"; shift 2 ;;
            *) error "Unknown ${mode} option: $1" ;;
        esac
    done
    [[ -n "${manifest}" ]] || error "--manifest is required"
    [[ -f "${manifest}" ]] || error "Manifest not found: ${manifest}"

    while IFS=$'\t' read -r name stable _candidate source_ref _source_digest; do
        [[ -z "${name}" ]] && continue
        if [[ "${dry_run}" == "true" ]]; then
            log "DRY RUN: ${mode} ${source_ref} -> ${REGISTRY_BASE}:${stable} via ${tool}"
            continue
        fi
        promote_one "${tool}" "${source_ref}" "${stable}"
        log "${mode} OK: ${name} -> ${REGISTRY_BASE}:${stable}"
    done < <(iter_manifest_rows "${manifest}")
}

main() {
    [[ $# -gt 0 ]] || { usage; exit 2; }

    local dry_run=false
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    set -- "${args[@]}"
    local cmd="$1"
    shift

    case "${cmd}" in
        build-candidates)
            do_build_candidates "${dry_run}" "$@"
            ;;
        verify-candidates)
            do_verify_candidates "${dry_run}" "$@"
            ;;
        promote)
            do_promote_or_rollback "promote" "${dry_run}" "$@"
            ;;
        rollback)
            do_promote_or_rollback "rollback" "${dry_run}" "$@"
            ;;
        --help|-h|help)
            usage
            ;;
        *)
            error "Unknown command: ${cmd}"
            ;;
    esac
}

main "$@"
