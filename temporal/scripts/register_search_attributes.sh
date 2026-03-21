#!/usr/bin/env bash
set -euo pipefail

TEMPORAL_CLI="${TEMPORAL_CLI:-temporal}"
TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-default}"

register_attr() {
  local name="$1"
  local type="$2"
  local output

  if output="$("${TEMPORAL_CLI}" operator search-attribute create \
    --namespace "${TEMPORAL_NAMESPACE}" \
    --name "${name}" \
    --type "${type}" 2>&1)"; then
    printf '[temporal] created search attribute %s (%s)\n' "${name}" "${type}"
    return 0
  fi

  if printf '%s' "${output}" | grep -qi 'already exists'; then
    printf '[temporal] search attribute %s already exists\n' "${name}"
    return 0
  fi

  printf '%s\n' "${output}" >&2
  return 1
}

register_attr "SygaldryPipelineWorkflowID" "Keyword"
register_attr "SygaldryPipelineCurrentStepID" "Keyword"
register_attr "SygaldryPipelineCurrentStepName" "Keyword"
