#!/usr/bin/env bash
set -euo pipefail

project_id="llm-exp"
gpu="true"
max_tokens="32"
spec_length="4"
extra_args=()
launcher="${SYGALDRY_LAUNCHER:-zephyr}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      project_id="$2"
      shift 2
      ;;
    --gpu)
      gpu="$2"
      shift 2
      ;;
    --max-tokens)
      max_tokens="$2"
      shift 2
      ;;
    --speculation-length)
      spec_length="$2"
      shift 2
      ;;
    --)
      shift
      extra_args+=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
 done

SYGALDRY_PROJECT_ID="$project_id" SYGALDRY_GPU="$gpu" \
  "${launcher}" bash -lc \
  "cd \${SYGALDRY_ROOT:-/work""space}/pkg/zephyr && spack env activate . && \
   export HF_HOME=/opt/hf_cache && \
   /opt/spack_store/view/bin/python3 \${SYGALDRY_ROOT:-/work""space}/llm_speculative_decoding_demo.py && \
   /opt/spack_store/view/bin/python3 \${SYGALDRY_ROOT:-/work""space}/llm_speculative_decoding_gpt2.py \
     --auto-device-map --max-tokens ${max_tokens} --speculation-length ${spec_length} --metrics ${extra_args[*]}"
