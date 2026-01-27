# AGENTS.md

General guidelines for agents working in this repository.

## Environment and Package Management

- GPU-only policy: this repository supports GPU mode only.
- Never add, implement, document, or maintain a no-GPU/CPU-only mode.
- Always create a Python virtual environment with `uv venv` before installing Python packages.
- When using Spack Python, create the venv with the Spack interpreter and inherit Spack site-packages:
  ```bash
  uv venv --python /opt/spack_store/view/bin/python3 --system-site-packages .venv
  ```
- Ensure the Spack view site-packages is on the venv path via a .pth file:
  ```bash
  PY_VER=$(/opt/spack_store/view/bin/python3 - <<'PY'
  import sys
  print(f"{sys.version_info.major}.{sys.version_info.minor}")
  PY
  )
  echo "/opt/spack_store/view/lib/python${PY_VER}/site-packages" > \
    .venv/lib/python${PY_VER}/site-packages/spack-view.pth
  ```
- Treat all Spack-installed Python packages as constraints so they are not overridden:
  ```bash
  /opt/spack_store/view/bin/python3 - <<'PY' > /tmp/spack-constraints.txt
  import importlib.metadata as md
  for dist in sorted(md.distributions(), key=lambda d: (d.metadata.get("Name", "").lower(), d.version)):
      name = dist.metadata.get("Name")
      if name:
          print(f"{name}=={dist.version}")
  PY
  uv pip install --python .venv/bin/python --constraint /tmp/spack-constraints.txt <package>
  ```
- Use `uv pip install` inside a venv (never `pip install` directly, never `--system`).
- For system tools like shellcheck, use `spack add <pkg>` followed by `spack install`.

Example:
```bash
uv venv .venv-lint
source .venv-lint/bin/activate
uv pip install ruff black pytest pytest-cov mypy
```

## Local Skills (Repo-Scoped)

- Use repo-scoped skills from `skills/` and do **not** install them into `$CODEX_HOME/skills` until explicitly approved.
- Available skills are listed in `skills/LOCAL_SKILLS.md` (source of truth).

## Shell Script Standards

- Header: `set -eu -o pipefail`
- Separate `local`/`readonly` declaration from command substitution (SC2155):
  ```bash
  # Correct
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  readonly SCRIPT_DIR

  # Wrong
  readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ```
- Run `shellcheck -s bash -S warning` on all shell scripts before committing.

## Go Code (temporal/)

- Run `go vet ./...` and `go test ./...` from `temporal/` before committing.
- Use table-driven tests with subtests (`t.Run`).
- Use `t.TempDir()` and `t.Setenv()` for test isolation.
- Canonical Temporal design doc: `temporal/TEMPORAL_DESIGN.md`.
- When modifying Temporal code, examples, scripts, interfaces, or tests, update `temporal/TEMPORAL_DESIGN.md` in the same change to keep:
  - current state accurate
  - future plans and priorities current
- Do not create or maintain parallel Temporal design/roadmap docs; use `temporal/TEMPORAL_DESIGN.md` as the single source of truth.

## Python Testing

- Use `pytest` for Python tests.
- Collocate tests with modules: for `foo/bar_baz.py`, place tests in `foo/bar_baz_test.py`.

## Validation

Run `./validate_all.sh` from the repo root to check everything:
- Go: build, vet, test
- Python: pytest, ruff, black
- Shell: shellcheck

Engineering quality gates (review/refactor standard):

```bash
./validate_all.sh --quality-all
./validate_all.sh --quality-all --quality-strict
```

Canonical quality docs:
- `docs/ENGINEERING_EXCELLENCE_STANDARD.md`
- `docs/REVIEW_REFACTOR_RUBRIC.md`
- `docs/quality/COVERAGE_BASELINE.yaml`
