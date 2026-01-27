# Engineering Excellence Standard

Status: canonical quality policy for review and refactor work.

## 1) Purpose

This standard defines measurable software quality gates for Sygaldry across Rust, Python, C++, Go, and Bash.

Primary goals:

1. Readable code and maintainable structure.
2. Strong test coverage with explicit ratcheting.
3. Narrow, composable tools with well-scoped duties.
4. Linter-first coding standard enforcement.

## 2) Quality Principles

1. Readability first: names, structure, and control flow must be easy to follow.
2. Correctness before cleverness: prefer explicit behavior and clear failure paths.
3. Single-duty tools: each command owns one bounded responsibility.
4. Composition over monoliths: complex workflows are composed by orchestrating multiple scoped tools.
5. Ratchet quality, do not regress: coverage and lint quality cannot move backward.

## 3) Tiered Enforcement Model

- Local development: warnings for missing optional tooling where possible.
- PR gate: blocking lint/test/coverage via strict mode.
- Release gate: strict mode plus subsystem release checks.

Canonical commands:

```bash
# Local, non-strict (best effort)
./tools/quality/run_all.sh

# PR/CI, strict
./tools/quality/run_all.sh --strict

# Individual phases
./tools/quality/run_lint.sh --strict
./tools/quality/run_test.sh --strict
./tools/quality/run_coverage.sh --strict
```

`validate_all.sh` also exposes:

```bash
./validate_all.sh --quality-lint
./validate_all.sh --quality-test
./validate_all.sh --quality-coverage
./validate_all.sh --quality-all
```

## 4) Language Standards

### Rust

Required gates:

- `cargo fmt --check`
- `cargo clippy --all-targets --all-features -- -D warnings -D clippy::unwrap_used`
- `cargo test`

Policy:

- Pin toolchain in `crates/zephyr/rust-toolchain.toml`.
- Toolchain mismatch between `rustc` and `clippy` is a blocking error.

### Python

Required gates:

- `ruff check`
- `black --check`
- `pytest`
- coverage via `pytest-cov`

Policy:

- Use `.venv-lint` created with `uv venv`.
- Install lint/test dependencies with `uv pip install`.
- Follow Spack+uv ownership model from `AGENTS.md`.

### Go

Required gates:

- `gofmt -l` must be empty.
- `go vet ./...`
- `go test ./...`
- `staticcheck ./...` (required in strict mode)

### Bash

Required gates:

- `shellcheck -s bash -S warning`
- `shfmt -d` (required in strict mode)

Policy:

- Script baseline header remains: `set -eu -o pipefail`.

### C++

Required when C++ code exists:

- `clang-format --dry-run --Werror`
- `clang-tidy` (with compile database)
- `ctest --output-on-failure`

Policy:

- No C++ files means C++ gates report `SKIP`.

## 5) Coverage Ratchet Policy

Baseline file:

- `docs/quality/COVERAGE_BASELINE.yaml`

Gate rules:

1. New touched modules without baseline must meet 80% line coverage.
2. Modules below 80% can stay below target only if untouched and non-regressing.
3. If a below-target module is touched, coverage must improve by at least +2 points until it reaches 80%.
4. Modules at or above 80% must not drop below 80%.
5. Any baseline regression is a failure.

## 6) Waivers

Waivers are allowed only for explicit, time-bounded exceptions in the baseline file.

Waiver fields:

- `owner`
- `reason`
- `expires` (ISO date)

Waivers cannot hide regressions; they only relax target/improvement checks temporarily.

## 7) Tool Scope and Composition Contract

1. Each tool command should do one thing well.
2. Mutable commands should support dry-run behavior where feasible.
3. Complex workflows are composed via orchestrators (Temporal plan, wrappers) calling scoped commands.
4. Review and refactor PRs must document composition boundaries when changing tool responsibilities.

## 8) Canonical Review Artifacts

- Review rubric: `docs/REVIEW_REFACTOR_RUBRIC.md`
- Coverage baseline: `docs/quality/COVERAGE_BASELINE.yaml`
- Quality runners: `tools/quality/`

