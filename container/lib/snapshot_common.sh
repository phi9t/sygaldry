#!/bin/bash
# Shared snapshot utilities for Sygaldry container image management.
#
# Provides reusable functions for tagging, pushing, and verifying images.
# Source this file; do not execute it directly.

if [[ -n "${_SYGALDRY_SNAPSHOT_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly _SYGALDRY_SNAPSHOT_COMMON_LOADED=1

snapshot_log() {
    echo "[$(date +'%H:%M:%S')] $*"
}

snapshot_error() {
    echo "[$(date +'%H:%M:%S')] ERROR: $*" >&2
}

# snapshot_push <image_ref> [max_attempts]
# Push a docker image with retry logic.
# Returns 0 on success, 1 if all attempts fail.
snapshot_push() {
    local image_ref="$1"
    local max_attempts="${2:-3}"
    local attempt

    for attempt in $(seq 1 "${max_attempts}"); do
        snapshot_log "Pushing ${image_ref} (attempt ${attempt}/${max_attempts}) ..."
        if docker push "${image_ref}"; then
            snapshot_log "Done pushing ${image_ref}"
            return 0
        fi
        if [[ "${attempt}" -lt "${max_attempts}" ]]; then
            snapshot_log "Push failed, waiting 30s before retry..."
            sleep 30
        fi
    done

    snapshot_error "Failed to push ${image_ref} after ${max_attempts} attempts"
    return 1
}

# snapshot_tag_and_push <local_image> <remote_prefix> <tag> <date_tag> [max_attempts]
# Tags local image with :tag and :tag-date_tag, pushes both.
snapshot_tag_and_push() {
    local local_image="$1"
    local remote_prefix="$2"
    local tag="$3"
    local date_tag="$4"
    local max_attempts="${5:-3}"

    local remote_latest="${remote_prefix}:${tag}"
    local remote_dated="${remote_prefix}:${tag}-${date_tag}"

    snapshot_log "Tagging ${local_image} -> ${remote_latest}"
    docker tag "${local_image}" "${remote_latest}"

    snapshot_log "Tagging ${local_image} -> ${remote_dated}"
    docker tag "${local_image}" "${remote_dated}"

    snapshot_push "${remote_latest}" "${max_attempts}" || return 1
    snapshot_push "${remote_dated}" "${max_attempts}" || return 1
    return 0
}

# snapshot_verify <remote_ref>
# Returns 0 if the remote manifest exists.
snapshot_verify() {
    local remote_ref="$1"
    if docker manifest inspect "${remote_ref}" >/dev/null 2>&1; then
        echo "  OK: ${remote_ref}"
        return 0
    else
        echo "  FAIL: ${remote_ref}"
        return 1
    fi
}

# parse_snapshot_args [args...]
# Sets globals: DRY_RUN, DO_PUSH, REGISTRY, TARGETS
# Returns remaining args in PASSTHROUGH_ARGS.
# shellcheck disable=SC2034  # globals DRY_RUN, DO_PUSH, REGISTRY read by callers
parse_snapshot_args() {
    DRY_RUN=false
    DO_PUSH=false
    REGISTRY="ghcr.io/phi9t/sygaldry/zephyr"
    TARGETS=()
    PASSTHROUGH_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            --push) DO_PUSH=true; shift ;;
            --registry=*) REGISTRY="${1#*=}"; shift ;;
            --registry) REGISTRY="${2:-}"; shift 2 ;;
            --) shift; PASSTHROUGH_ARGS+=("$@"); break ;;
            *) TARGETS+=("$1"); shift ;;
        esac
    done
}
