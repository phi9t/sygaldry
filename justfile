# justfile — Common development tasks for Sygaldry
#
# Install just: https://just.systems  (or: cargo install just)
# Usage: just <target>

# Default: list available recipes
default:
    @just --list

sygaldry_bin := "./bin/sygaldry"

# ── SAIL: Sygaldry Agentic Improvement Loop ──────────────────────────────────

# Run the full SAIL improvement loop (requires Temporal worker + gh CLI + claude CLI)
sail:
    {{sygaldry_bin}} sail

# Dry run: discover issues and log what would happen (no LLM calls, no Temporal)
sail-dry:
    {{sygaldry_bin}} sail --dry-run

# Preview discovered issues without running any pipeline
sail-discover:
    {{sygaldry_bin}} sail discover | python3 -c "import json,sys; [print(f\"[p{i['priority']}] {i['type']}: {i['title']}\") for i in json.load(sys.stdin)]"

# Start the Temporal worker (leave running in a separate terminal)
sail-worker:
    {{sygaldry_bin}} sail worker

# Run the unattended cron wrapper once
sail-cron:
    {{sygaldry_bin}} sail cron

# Validate the pipeline, then launch the unattended cron wrapper once
sail-initial:
    just sail-validate
    just sail-cron

# Analyze a persisted SAIL run directory
sail-analyze RUN_DIR:
    {{sygaldry_bin}} sail analyze-run --run-dir {{RUN_DIR}}

# Validate the improvement_loop.yaml plan schema
sail-validate:
    {{sygaldry_bin}} sail validate-plan

# Echo engine end-to-end test: exercises full pipeline without LLM tokens
sail-echo:
    SAIL_PLANNER_ENGINE=echo SAIL_IMPLEMENTER_ENGINE=echo {{sygaldry_bin}} sail

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
    {{sygaldry_bin}} snapshot spack

# Build all MLSys images (vllm, sglang, torchtitan, megatronlm)
snapshot-mlsys:
    {{sygaldry_bin}} snapshot llm-serving-all

# Build and push spack snapshot
snapshot-spack-push:
    {{sygaldry_bin}} snapshot spack --push

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
    {{sygaldry_bin}} shell

# Show effective container configuration
config:
    {{sygaldry_bin}} config show
