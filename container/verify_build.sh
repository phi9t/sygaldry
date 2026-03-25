#!/usr/bin/env bash
# Run Spack install via Temporal pipeline.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

exec go -C "${ROOT}/temporal" run ./cmd/orchestrate run \
    -plan examples/spack-build-pipeline.yaml
