#!/usr/bin/env bash

_cfg_section() {
    local section="$1" key="$2" default="$3"
    local config_file="${CONFIG:-${CONFIG_FILE:-}}"
    local value

    if [[ -z "${config_file}" ]]; then
        echo "${default}"
        return
    fi

    value="$(
        awk -v target_section="${section}" -v target_key="${key}" '
            $0 ~ ("^" target_section ":") { in_section = 1; next }
            in_section && $0 ~ /^[^[:space:]]/ { in_section = 0 }
            in_section && $0 ~ ("^  " target_key ":") {
                sub(/^[^:]+:[[:space:]]*/, "", $0)
                sub(/[[:space:]]+#.*$/, "", $0)
                gsub(/"/, "", $0)
                gsub(/[[:space:]]+$/, "", $0)
                print
                exit
            }
        ' "${config_file}" 2>/dev/null || true
    )"
    echo "${value:-${default}}"
}
