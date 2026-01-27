#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

SOURCE_YAML="${REPO_ROOT}/pkg/zephyr/spack_src.yaml"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_ROOT_DEFAULT="${REPO_ROOT}/outputs/spack_stage/${RUN_ID}"
RUN_ROOT="${RUN_ROOT:-${RUN_ROOT_DEFAULT}}"
FORBIDDEN_NAMES_DEFAULT="py-torch,py-jax,py-jaxlib,torch,jax,jaxlib,llvm"
FORBIDDEN_NAMES="${FORBIDDEN_NAMES:-${FORBIDDEN_NAMES_DEFAULT}}"
ALLOW_DEPRECATED=1
REQUIRE_GPU_VERIFY=1
VERBOSE=1

SPECS=()
PYTHON_IMPORTS=()

usage() {
    cat <<'EOF'
Usage:
  zephyr_stage_spack.sh [options]

Options:
  --source-yaml <path>       Source manifest to copy into staging
                             (default: <repo>/pkg/zephyr/spack_src.yaml)
  --run-root <path>          Explicit run root
                             (default: <repo>/outputs/spack_stage/<run_id>)
  --spec <spack-spec>        Spec to add/analyze (repeatable). If omitted,
                             concretize/analyze all root specs from lock.
  --python-import <module>   Extra Python module import to verify (repeatable).
  --forbidden-names <csv>    Comma-separated package names that must not be
                             newly required.
  --no-allow-deprecated      Do not pass --deprecated to concretize analyzer.
  --no-gpu-verify            Skip GPU verification scripts.
  --quiet                    Disable verbose analyzer output.
  -h, --help                 Show this help.

Examples:
  zephyr_stage_spack.sh --spec py-soundfile --python-import soundfile
  zephyr_stage_spack.sh --spec py-soundfile --spec sox
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-yaml)
            SOURCE_YAML="${2:-}"
            [[ -n "${SOURCE_YAML}" ]] || { echo "ERROR: --source-yaml needs a value" >&2; exit 2; }
            shift 2
            ;;
        --run-root)
            RUN_ROOT="${2:-}"
            [[ -n "${RUN_ROOT}" ]] || { echo "ERROR: --run-root needs a value" >&2; exit 2; }
            shift 2
            ;;
        --spec)
            SPECS+=("${2:-}")
            [[ -n "${SPECS[${#SPECS[@]}-1]}" ]] || { echo "ERROR: --spec needs a value" >&2; exit 2; }
            shift 2
            ;;
        --python-import)
            PYTHON_IMPORTS+=("${2:-}")
            [[ -n "${PYTHON_IMPORTS[${#PYTHON_IMPORTS[@]}-1]}" ]] || { echo "ERROR: --python-import needs a value" >&2; exit 2; }
            shift 2
            ;;
        --forbidden-names)
            FORBIDDEN_NAMES="${2:-}"
            [[ -n "${FORBIDDEN_NAMES}" ]] || { echo "ERROR: --forbidden-names needs a value" >&2; exit 2; }
            shift 2
            ;;
        --no-allow-deprecated)
            ALLOW_DEPRECATED=0
            shift
            ;;
        --no-gpu-verify)
            REQUIRE_GPU_VERIFY=0
            shift
            ;;
        --quiet)
            VERBOSE=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -f "/opt/spack_src/share/spack/setup-env.sh" ]]; then
    # shellcheck disable=SC1091
    source /opt/spack_src/share/spack/setup-env.sh
elif command -v spack >/dev/null 2>&1; then
    echo "WARNING: /opt/spack_src/share/spack/setup-env.sh missing; using spack from PATH" >&2
else
    echo "ERROR: missing /opt/spack_src/share/spack/setup-env.sh and spack not found in PATH" >&2
    exit 1
fi

if [[ ! -f "${SOURCE_YAML}" ]]; then
    echo "ERROR: source yaml not found: ${SOURCE_YAML}" >&2
    exit 1
fi

SRC_ENV_DIR="${RUN_ROOT}/source_env"
ANALYZE_ROOT="${RUN_ROOT}/analyze_stage"
LOG_DIR="${RUN_ROOT}/logs"
ANALYZE_REPORT="${LOG_DIR}/concretize_report.json"
NEW_REQ_TXT="${LOG_DIR}/new_requirements.txt"
FINAL_STATUS="${LOG_DIR}/final_status.json"
INSTALL_LOG="${LOG_DIR}/install.log"
VERIFY_ZEPHYR_LOG="${LOG_DIR}/verify_pkg_zephyr.log"
VERIFY_GPU_LOG="${LOG_DIR}/verify_gpu.log"
VERIFY_IMPORTS_LOG="${LOG_DIR}/verify_imports.log"

export SOURCE_YAML RUN_ROOT SRC_ENV_DIR ANALYZE_ROOT LOG_DIR ANALYZE_REPORT NEW_REQ_TXT FINAL_STATUS
export INSTALL_LOG VERIFY_ZEPHYR_LOG VERIFY_GPU_LOG VERIFY_IMPORTS_LOG FORBIDDEN_NAMES

mkdir -p "${SRC_ENV_DIR}" "${LOG_DIR}"
cp "${SOURCE_YAML}" "${SRC_ENV_DIR}/spack.yaml"

write_status() {
    python3 - <<'PY'
import json
import os

payload = {
    "run_root": os.environ["RUN_ROOT"],
    "source_yaml": os.environ["SOURCE_YAML"],
    "specs": os.environ.get("SPECS_CSV", ""),
    "forbidden_names_csv": os.environ.get("FORBIDDEN_NAMES", ""),
    "stage_env": os.environ.get("STAGE_ENV", ""),
    "analyze_report": os.environ.get("ANALYZE_REPORT", ""),
    "new_requirements": os.environ.get("NEW_REQ_TXT", ""),
    "install_log": os.environ.get("INSTALL_LOG", ""),
    "verify_pkg_zephyr_log": os.environ.get("VERIFY_ZEPHYR_LOG", ""),
    "verify_gpu_log": os.environ.get("VERIFY_GPU_LOG", ""),
    "verify_imports_log": os.environ.get("VERIFY_IMPORTS_LOG", ""),
    "status": os.environ.get("STATUS", "failed"),
    "failed_step": os.environ.get("FAIL_STEP", ""),
    "failure_message": os.environ.get("FAIL_MESSAGE", ""),
}
with open(os.environ["FINAL_STATUS"], "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY
}

fail() {
    local step="$1"
    local message="$2"
    local code="${3:-1}"
    export STATUS="failed" FAIL_STEP="${step}" FAIL_MESSAGE="${message}"
    write_status
    echo "FINAL_STATUS=${FINAL_STATUS}"
    echo "ERROR_STEP=${step}"
    echo "ERROR_MSG=${message}"
    exit "${code}"
}

SPECS_CSV=""
if [[ ${#SPECS[@]} -gt 0 ]]; then
    SPECS_CSV="$(IFS=,; echo "${SPECS[*]}")"
fi
export SPECS_CSV

ANALYZE_ARGS=(
    --source-env-dir "${SRC_ENV_DIR}"
    --stage-root "${ANALYZE_ROOT}"
    --output-json "${ANALYZE_REPORT}"
    --keep-stage
)
if [[ ${VERBOSE} -eq 1 ]]; then
    ANALYZE_ARGS+=(--verbose)
fi
if [[ ${ALLOW_DEPRECATED} -eq 1 ]]; then
    ANALYZE_ARGS+=(--allow-deprecated)
else
    ANALYZE_ARGS+=(--no-allow-deprecated)
fi
for spec in "${SPECS[@]}"; do
    ANALYZE_ARGS+=(--spec "${spec}")
done

"${REPO_ROOT}/tools/zephyr_concretize_analyze.sh" "${ANALYZE_ARGS[@]}" || fail "analyze" "concretization analysis failed" 2

STAGE_ENV="$(python3 - <<'PY'
import json
import os
print(json.load(open(os.environ["ANALYZE_REPORT"], "r", encoding="utf-8"))["stage_dir"])
PY
)"
export STAGE_ENV

python3 - <<'PY' || fail "pytorch_variants" "py-torch missing +nccl/+distributed in concretized lock" 16
import json
import os
import sys
from pathlib import Path

stage_env = Path(os.environ["STAGE_ENV"])
lock_path = stage_env / "spack.lock"
if not lock_path.is_file():
    print(f"ERROR: lock file not found: {lock_path}")
    sys.exit(1)

lock = json.loads(lock_path.read_text(encoding="utf-8"))
roots = lock.get("roots", [])
torch_roots = [root for root in roots if str(root.get("spec", "")).startswith("py-torch@")]
if not torch_roots:
    print("ERROR: no py-torch root found in concretized lock")
    sys.exit(1)

bad = []
for root in torch_roots:
    spec = str(root.get("spec", ""))
    if "+nccl" not in spec or "+distributed" not in spec:
        bad.append(spec)

if bad:
    print("ERROR: py-torch concretized without required variants")
    for spec in bad:
        print(f"- {spec}")
    sys.exit(1)

for root in torch_roots:
    print(f"PYTORCH_CONCRETIZED={root.get('spec', '')}")
PY

python3 - <<'PY' > "${NEW_REQ_TXT}" || fail "new_requirements" "failed to generate new requirements list" 3
import json
import os

report = json.load(open(os.environ["ANALYZE_REPORT"], "r", encoding="utf-8"))
for item in report.get("missing", []):
    print(f"- {item['name']}@{item['version']} /{item['hash']}")
PY

python3 - <<'PY' || fail "core_guard" "missing forbidden core packages in concretization" 10
import json
import os
import sys

forbidden_names = {
    n.strip() for n in os.environ.get("FORBIDDEN_NAMES", "").split(",") if n.strip()
}
report = json.load(open(os.environ["ANALYZE_REPORT"], "r", encoding="utf-8"))
missing = report.get("missing", [])
forbidden = [m for m in missing if m.get("name") in forbidden_names]

print(f"REPORT={os.environ['ANALYZE_REPORT']}")
print(f"STAGE_ENV={os.environ['STAGE_ENV']}")
print(f"TOTAL_MISSING={len(missing)}")
print(f"FORBIDDEN_MISSING={len(forbidden)}")

if forbidden:
    print("Forbidden missing specs detected:")
    for m in forbidden:
        print(f"- {m['name']}@{m['version']} /{m['hash']}")
    sys.exit(1)
PY

spack -e "${STAGE_ENV}" install 2>&1 | tee "${INSTALL_LOG}" || fail "install" "spack install failed" 11
spack -e "${STAGE_ENV}" env view regenerate >> "${INSTALL_LOG}" 2>&1 || fail "view_regenerate" "spack env view regenerate failed" 12

if [[ ${REQUIRE_GPU_VERIFY} -eq 1 ]]; then
    (
        cd "${STAGE_ENV}"
        "${REPO_ROOT}/pkg/zephyr/verify.sh" --require-gpu
    ) > "${VERIFY_ZEPHYR_LOG}" 2>&1 || fail "verify_pkg_zephyr" "pkg/zephyr/verify.sh failed" 13

    SYGALDRY_SPACK_ENV="${STAGE_ENV}" "${REPO_ROOT}/container/entrypoints/verify-gpu.sh" > "${VERIFY_GPU_LOG}" 2>&1 \
        || fail "verify_gpu" "container/entrypoints/verify-gpu.sh failed" 14
fi

if [[ ${#PYTHON_IMPORTS[@]} -gt 0 ]]; then
    PYTHON_IMPORTS_CSV="$(IFS=,; echo "${PYTHON_IMPORTS[*]}")"
    export PYTHON_IMPORTS_CSV
    bash -lc "eval \"\$(spack -e ${STAGE_ENV} env activate --sh)\"; python3 - <<'PY'
import importlib
import os

mods = [m for m in os.environ.get('PYTHON_IMPORTS_CSV', '').split(',') if m]
for m in mods:
    mod = importlib.import_module(m)
    print(m, getattr(mod, '__version__', 'unknown'))
PY" > "${VERIFY_IMPORTS_LOG}" 2>&1 || fail "verify_imports" "explicit Python import verification failed" 15
fi

export STATUS="ok" FAIL_STEP="" FAIL_MESSAGE=""
write_status
echo "RUN_ROOT=${RUN_ROOT}"
echo "STAGE_ENV=${STAGE_ENV}"
echo "ANALYZE_REPORT=${ANALYZE_REPORT}"
echo "NEW_REQUIREMENTS=${NEW_REQ_TXT}"
echo "FINAL_STATUS=${FINAL_STATUS}"
