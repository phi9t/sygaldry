# justfile — Common development tasks for Sygaldry
#
# Install just: https://just.systems  (or: cargo install just)
# Usage: just <target>

# Default: list available recipes
default:
    @just --list

# ── SAIL: Sygaldry Agentic Improvement Loop ──────────────────────────────────

# Run the full SAIL improvement loop (requires Temporal worker + gh CLI + claude CLI)
sail:
    sygaldry sail

# Dry run: discover issues and log what would happen (no LLM calls, no Temporal)
sail-dry:
    sygaldry sail --dry-run

# Preview discovered issues without running any pipeline
sail-discover:
    sygaldry sail discover | python3 -c "import json,sys; [print(f\"[p{i['priority']}] {i['type']}: {i['title']}\") for i in json.load(sys.stdin)]"

# Start the Temporal worker (leave running in a separate terminal)
sail-worker:
    sygaldry sail worker

# Validate the improvement_loop.yaml plan schema
sail-validate:
    sygaldry sail validate-plan

# Echo engine end-to-end test: exercises full pipeline without LLM tokens
sail-echo:
    SAIL_PLANNER_ENGINE=echo SAIL_IMPLEMENTER_ENGINE=echo sygaldry sail

# ── Validation ───────────────────────────────────────────────────────────────

# Quick validation (go build/vet/test + ruff + black; skips shellcheck)
validate:
    ./validate_all.sh --quick

# Full validation suite (includes shellcheck)
validate-full:
    ./validate_all.sh

# Infrastructure validation only (no Spack build)
validate-infra:
    ./validate_all.sh --infra

# ── Go ───────────────────────────────────────────────────────────────────────

# Run all Go tests
test:
    cd temporal && go test ./...

# Build all Go binaries
build:
    cd temporal && go build ./...

# Run go vet
vet:
    cd temporal && go vet ./...

# ── Snapshots ────────────────────────────────────────────────────────────────

# Build spack snapshot image
snapshot-spack:
    sygaldry snapshot spack

# Build all MLSys images (vllm, sglang, torchtitan, megatronlm)
snapshot-mlsys:
    sygaldry snapshot llm-serving-all

# Build and push spack snapshot
snapshot-spack-push:
    sygaldry snapshot spack --push

# ── Python ───────────────────────────────────────────────────────────────────

# Lint Python with ruff
lint:
    .venv-lint/bin/ruff check .

# Format check with black
fmt-check:
    .venv-lint/bin/black --check .

# Auto-fix ruff issues
lint-fix:
    .venv-lint/bin/ruff check --fix .

# ── Container ────────────────────────────────────────────────────────────────

# Launch interactive container shell
shell:
    sygaldry shell

# Show effective container configuration
config:
    sygaldry config show
