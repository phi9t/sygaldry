#!/bin/bash
# Uninstall K3s and clean up.
#
# Usage:
#   sudo k3s/bootstrap/teardown.sh

set -eu -o pipefail

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [teardown:${BASH_LINENO[0]}] $*" >&2
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (or via sudo)." >&2
    exit 1
fi

if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    log "Uninstalling K3s..."
    /usr/local/bin/k3s-uninstall.sh
    log "K3s uninstalled."
else
    log "K3s uninstall script not found. K3s may not be installed."
fi
