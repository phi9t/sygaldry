#!/bin/bash
set -eu -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [codex_run:${BASH_LINENO[0]}] $*" >&2
}

# Defaults
PROMPT=""
PROMPT_FILE=""
MODEL="${CODEX_DEV_LOOP_MODEL:-o3}"
WORKDIR="."
OUTPUT=""

usage() {
    local code
    code="${1:-1}"
    cat >&2 <<EOF
Usage: $(basename "$0") [--prompt <text> | --prompt-file <file>] [options]

Invoke Codex CLI in unrestricted mode with full filesystem access.

Options:
  --prompt <text>       Prompt text (required unless --prompt-file given)
  --prompt-file <file>  Read prompt from file (for long prompts)
  --model <model>       Model to use (default: o3, or CODEX_DEV_LOOP_MODEL)
  --workdir <dir>       Working directory (default: .)
  --output <file>       Write final message to file
  -h, --help            Show this help

Environment:
  CODEX_DEV_LOOP_MODEL  Override default model (default: o3)
  OPENAI_API_KEY        Required for Codex API access
EOF
    exit "$code"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt)      PROMPT="$2"; shift 2 ;;
        --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
        --model)       MODEL="$2"; shift 2 ;;
        --workdir)     WORKDIR="$2"; shift 2 ;;
        --output)      OUTPUT="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) log "Unknown flag: $1"; usage ;;
    esac
done

# Resolve prompt from --prompt-file if provided
if [[ -n "$PROMPT_FILE" ]]; then
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log "Error: prompt file not found: $PROMPT_FILE"
        exit 1
    fi
    PROMPT="$(cat "$PROMPT_FILE")"
fi

if [[ -z "$PROMPT" ]]; then
    log "Error: --prompt or --prompt-file is required"
    usage
fi

# Validate prerequisites
if ! command -v codex &>/dev/null; then
    log "Error: codex CLI not found on PATH"
    exit 1
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    log "Error: OPENAI_API_KEY is not set"
    exit 1
fi

if [[ ! -d "$WORKDIR" ]]; then
    log "Error: workdir does not exist: $WORKDIR"
    exit 1
fi

# Build command
CMD=(codex exec --dangerously-bypass-approvals-and-sandbox --json -m "$MODEL" -C "$WORKDIR")

if [[ -n "$OUTPUT" ]]; then
    CMD+=(-o "$OUTPUT")
fi

# Log file for JSONL events (PID suffix for concurrency safety)
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/codex-run-$(date +'%Y%m%d-%H%M%S')-$$.jsonl"

log "Model: $MODEL | Workdir: $WORKDIR"
PROMPT_PREVIEW="${PROMPT:0:200}"
if (( ${#PROMPT} > 200 )); then
    PROMPT_PREVIEW="${PROMPT_PREVIEW}..."
fi
log "Prompt: $PROMPT_PREVIEW"
log "JSONL log: $LOG_FILE"

# Run codex, tee JSONL events to log file
"${CMD[@]}" "$PROMPT" | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}

log "Codex exited with code $EXIT_CODE"
if [[ -n "$OUTPUT" ]]; then
    log "Output written to: $OUTPUT"
fi

exit "$EXIT_CODE"
