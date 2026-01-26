#!/bin/bash
set -euo pipefail

if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
  source "/opt/spack_src/share/spack/setup-env.sh"
else
  echo "ERROR: Spack setup script not found at /opt/spack_src" >&2
  exit 1
fi

cd /workspace/pkg/zephyr
./build.sh
