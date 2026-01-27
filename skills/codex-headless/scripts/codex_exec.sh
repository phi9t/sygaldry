#!/bin/bash
set -eu -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [codex_exec:${BASH_LINENO[0]}] $*" >&2
}

# Defaults
PROMPT=""
MODEL="o4-mini"
WORKDIR="."
OUTPUT=""
SANDBOX="workspace-write"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --prompt <text> [options]

Options:
  --prompt <text>     Prompt text (required)
  --model <model>     Model to use (default: o4-mini)
  --workdir <dir>     Working directory (default: .)
  --output <file>     Write final message to file
  --sandbox <mode>    Sandbox mode: read-only, workspace-write, danger-full-access
                      (default: workspace-write)
  -h, --help          Show this help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt)  PROMPT="$2"; shift 2 ;;
        --model)   MODEL="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --sandbox) SANDBOX="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) log "Unknown flag: $1"; usage ;;
    esac
done

if [[ -z "$PROMPT" ]]; then
    log "Error: --prompt is required"
    usage
fi

# Build command
CMD=(codex exec --full-auto --json -m "$MODEL" -s "$SANDBOX" -C "$WORKDIR")

if [[ -n "$OUTPUT" ]]; then
    CMD+=(-o "$OUTPUT")
fi

# Log file for JSONL events
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/codex-$(date +'%Y%m%d-%H%M%S').jsonl"

log "Model: $MODEL | Sandbox: $SANDBOX | Workdir: $WORKDIR"
log "Prompt: $PROMPT"
log "JSONL log: $LOG_FILE"

# Run codex, tee JSONL events to log file
"${CMD[@]}" "$PROMPT" | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}

log "Codex exited with code $EXIT_CODE"
if [[ -n "$OUTPUT" ]]; then
    log "Output written to: $OUTPUT"
fi

exit "$EXIT_CODE"
