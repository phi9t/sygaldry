#!/bin/bash
# Canonical snapshot defaults for Zephyr skill scripts.
#
# Source this file to load the default snapshot reference:
#   source "$(dirname "${BASH_SOURCE[0]}")/snapshot_defaults.sh"
#
# The SNAPSHOT_REF variable is set to the pinned digest-stable reference
# unless already defined by the caller or the ZEPHYR_SNAPSHOT_REF env var.
# Override at call-time:
#   ZEPHYR_SNAPSHOT_REF=ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:<digest> \
#     ./run_hf_real_workload.sh
#   OR
#   ./run_hf_real_workload.sh --snapshot-ref ghcr.io/...@sha256:<digest>

# Pinned to the validated spack-20260212-082355 snapshot image.
# Update this value when a new snapshot is promoted via:
#   make -C container publish-dry-run  # then promote
readonly ZEPHYR_DEFAULT_SNAPSHOT_REF="ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c"

# Respect env var override; fall back to pinned default.
SNAPSHOT_REF="${ZEPHYR_SNAPSHOT_REF:-${ZEPHYR_DEFAULT_SNAPSHOT_REF}}"
