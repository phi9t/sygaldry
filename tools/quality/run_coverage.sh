#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
STRICT="${QUALITY_STRICT:-0}"
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi
export QUALITY_STRICT="${STRICT}"

log() {
    echo "[quality][coverage] $*" >&2
}

OUT_DIR="${QUALITY_OUTPUT_DIR:-${REPO_ROOT}/.quality/coverage}"
readonly OUT_DIR
mkdir -p "${OUT_DIR}"

TMP_DIR="$(mktemp -d)"
readonly TMP_DIR
trap 'rm -rf "${TMP_DIR}"' EXIT

METRICS_JSON="${OUT_DIR}/metrics.json"
readonly METRICS_JSON
CHANGED_FILES="${OUT_DIR}/changed_files.txt"
readonly CHANGED_FILES

{
    if [[ -n "${QUALITY_CHANGED_BASE:-}" ]]; then
        git -C "${REPO_ROOT}" diff --name-only "${QUALITY_CHANGED_BASE}...HEAD" || true
    elif [[ -n "${GITHUB_BASE_REF:-}" ]] && git -C "${REPO_ROOT}" rev-parse --verify "origin/${GITHUB_BASE_REF}" >/dev/null 2>&1; then
        git -C "${REPO_ROOT}" diff --name-only "origin/${GITHUB_BASE_REF}...HEAD" || true
    else
        git -C "${REPO_ROOT}" diff --name-only HEAD || true
        git -C "${REPO_ROOT}" ls-files --others --exclude-standard || true
    fi
} | sort -u >"${CHANGED_FILES}"

GO_METRICS_JSON="${TMP_DIR}/go_metrics.json"
readonly GO_METRICS_JSON
PYTHON_METRICS_JSON="${TMP_DIR}/python_metrics.json"
readonly PYTHON_METRICS_JSON
printf '[]\n' >"${GO_METRICS_JSON}"
printf '[]\n' >"${PYTHON_METRICS_JSON}"

if command -v go >/dev/null 2>&1; then
    GO_PROFILE="${TMP_DIR}/go.cover"
    readonly GO_PROFILE
    log "Collecting Go coverage"
    if go test -C "${REPO_ROOT}/temporal" -coverprofile "${GO_PROFILE}" ./... >/dev/null; then
        python3 - "${GO_PROFILE}" "${GO_METRICS_JSON}" <<'PY'
import json
import os
import pathlib
import re
import sys

profile_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
pattern = re.compile(r"^(?P<file>[^:]+):\d+\.\d+,\d+\.\d+\s+(?P<num>\d+)\s+(?P<count>\d+)$")

stats = {}
for line in profile_path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("mode:"):
        continue
    match = pattern.match(line)
    if not match:
        continue
    rel_file = match.group("file")
    if rel_file.startswith("temporal-orchestration/"):
        rel_file = rel_file[len("temporal-orchestration/") :]
    num = int(match.group("num"))
    count = int(match.group("count"))
    rel_dir = os.path.dirname(rel_file) or "."
    key_dir = "temporal" if rel_dir == "." else f"temporal/{rel_dir}"
    key = f"go:{key_dir}"
    entry = stats.setdefault(key, {"total": 0, "covered": 0, "source": key_dir + "/"})
    entry["total"] += num
    if count > 0:
        entry["covered"] += num

metrics = []
for key, entry in sorted(stats.items()):
    if entry["total"] == 0:
        continue
    value = 100.0 * entry["covered"] / entry["total"]
    metrics.append(
        {
            "key": key,
            "language": "go",
            "value": round(value, 4),
            "sources": [entry["source"]],
        }
    )

out_path.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
PY
    else
        log "ERROR: go coverage command failed"
        exit 1
    fi
elif [[ "${STRICT}" == "1" ]]; then
    log "ERROR: go not found"
    exit 1
else
    log "WARN: go not found; skipping Go coverage"
fi

VENV_DIR="${REPO_ROOT}/.venv-lint"
readonly VENV_DIR
PYTEST="${VENV_DIR}/bin/pytest"
if [[ -x "${PYTEST}" ]]; then
    PYTEST_HELP="$(${PYTEST} --help 2>/dev/null || true)"
    if [[ "${PYTEST_HELP}" == *"--cov"* ]]; then
        PYTHON_COVERAGE_JSON="${TMP_DIR}/python_coverage.json"
        readonly PYTHON_COVERAGE_JSON
        log "Collecting Python coverage"
        PYTEST_COVERAGE_ARGS=(
            --ignore=pkg
            --ignore=llm_speculative_decoding_gpt2_test.py
            --ignore=tools/qwen3_scale_test.py
            -q
            --cov=.
            --cov-report=json:"${PYTHON_COVERAGE_JSON}"
        )
        set +e
        (cd "${REPO_ROOT}" && "${PYTEST}" "${PYTEST_COVERAGE_ARGS[@]}" >/dev/null)
        pytest_status=$?
        set -e
        if [[ ${pytest_status} -eq 5 ]]; then
            log "WARN: no host-safe Python tests collected for coverage"
        elif [[ ${pytest_status} -eq 0 ]]; then
            python3 - "${PYTHON_COVERAGE_JSON}" "${PYTHON_METRICS_JSON}" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))

metrics = []
for file_path, payload in sorted(data.get("files", {}).items()):
    if not file_path.endswith(".py"):
        continue
    summary = payload.get("summary", {})
    percent = summary.get("percent_covered")
    if percent is None:
        continue
    key = "python:" + file_path[:-3]
    metrics.append(
        {
            "key": key,
            "language": "python",
            "value": float(percent),
            "sources": [file_path],
        }
    )

out_path.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
PY
        else
            log "ERROR: pytest coverage run failed"
            exit 1
        fi
    elif [[ "${STRICT}" == "1" ]]; then
        log "ERROR: pytest-cov plugin missing; install pytest-cov in .venv-lint"
        exit 1
    else
        log "WARN: pytest-cov plugin missing; skipping Python coverage"
    fi
elif [[ "${STRICT}" == "1" ]]; then
    log "ERROR: pytest not found at ${PYTEST}"
    exit 1
else
    log "WARN: pytest not found at ${PYTEST}; skipping Python coverage"
fi

python3 - "${GO_METRICS_JSON}" "${PYTHON_METRICS_JSON}" "${METRICS_JSON}" <<'PY'
import datetime as dt
import json
import pathlib
import sys

combined = []
for path in sys.argv[1:3]:
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if isinstance(data, list):
        combined.extend(data)

out = {
    "generated_at": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
    "metrics": combined,
}
pathlib.Path(sys.argv[3]).write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
PY

log "Applying coverage ratchet gate"
GATE_ARGS=(
    --baseline "${REPO_ROOT}/docs/quality/COVERAGE_BASELINE.yaml"
    --metrics "${METRICS_JSON}"
    --changed-files "${CHANGED_FILES}"
)
if [[ "${STRICT}" == "1" ]]; then
    GATE_ARGS+=(--strict)
fi
python3 "${SCRIPT_DIR}/coverage_gate.py" "${GATE_ARGS[@]}"

log "PASS"
