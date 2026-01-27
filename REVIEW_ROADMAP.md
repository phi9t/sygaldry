# Sygaldry Review + Roadmap (2026-02-03)

This doc expands the repo review into actionable, staged plans with concrete tasks,
acceptance criteria, and review questions.

## Scope
- Container runtime + GPU support
- Spack environments and packaging
- Temporal orchestration stack
- Speculative decoding + LLM experiments
- Tools/scripts for model runs
- Skills + developer experience
- Validation, testing, and repo hygiene

## Executive Summary (Current State)
- Strong container launcher + entrypoints, reproducible Spack envs, and Temporal-based orchestration.
- LLM speculative decoding is production-styled but metrics/CLI defaults need fixes.
- Tooling exists for Qwen3 experiments, but reproducibility and defaults are inconsistent.
- Validation is present but incomplete (pytest not in validate script; gitignore misses caches).

---

## Area 1: Container Runtime + GPU Support

### Current Strengths
- Single launcher handles image build, persistent mounts, and GPU gating.
- Entrypoints cover default shell, spack install/build, and GPU verification.

### Risks / Gaps
- `uv-install.sh` does not follow the new Spack+uv constraints workflow.
- CUDA detection relies on `rg`, and host CUDA gating is rigid.
- No explicit network/IPC isolation toggles.

### Near-Term (0–2 weeks)
1) Align `container/entrypoints/uv-install.sh` with AGENTS Spack+uv policy.
   - Use Spack Python, `--system-site-packages`, `.pth` inclusion, and constraints.
   - Acceptance: a fresh container can install pytest via uv without overriding Spack torch.
2) Add fallback for CUDA version detection if `rg` missing.
   - Acceptance: launcher logs CUDA version reliably without `rg`.
3) Add `SYGALDRY_NET` and `SYGALDRY_IPC` overrides.
   - Acceptance: `SYGALDRY_NET=bridge` and `SYGALDRY_IPC=private` work.

### Mid-Term (2–6 weeks)
4) Add healthcheck entrypoint that runs GPU + torch/jax quick tests.
5) Improve launcher diagnostics (print resolved config, GPU decision rationale).

### Long-Term (6–12 weeks)
6) Introduce versioned container images with CI build + artifact publishing.
7) Add rootless/remote Docker support where feasible.

---

## Area 2: Spack Environments + Packaging

### Current Strengths
- `pkg/zephyr/build.sh` handles lockfile vs reconcretize and generates view.
- Dependency graph artifacts are present.

### Risks / Gaps
- `spack.lock` is globally ignored, which weakens reproducibility if pinning is intended.
- No automated smoke tests for installed packages.

### Near-Term (0–2 weeks)
1) Decide lockfile policy (commit `pkg/zephyr/spack.lock` or keep local-only).
   - Acceptance: clear policy in README + AGENTS.
2) Add `spack-smoke.sh` (import torch/jax; GPU check).
   - Acceptance: zero-config run inside container.

### Mid-Term (2–6 weeks)
3) Split dev vs runtime envs to reduce size of base installs.
4) Add GPU-arch variants or matrix (e.g., compute capability targeting).

### Long-Term (6–12 weeks)
5) Prebuilt “golden” env caches with CI validation and version stamps.

---

## Area 3: Temporal Orchestration

### Current Strengths
- Structured logs with CLI introspection.
- Clean separation between workflows and activities.

### Risks / Gaps
- `ContainerJob` default entrypoint bug.
- No validation for missing/duplicate step IDs.

### Near-Term (0–2 weeks)
1) Fix `ContainerJob` default entrypoint (remove `.sh` suffix, or normalize once).
2) Validate pipeline steps: non-empty IDs, unique IDs, and dependency existence.
3) Add tests for container_job wiring and pipeline validation.
   - Acceptance: failing cases are caught before workflow execution.

### Mid-Term (2–6 weeks)
4) Add concurrency controls and cancellation propagation.
5) Support step-level resource hints (GPU/CPU/memory annotations).

### Long-Term (6–12 weeks)
6) Export metrics (Prometheus-compatible counters for step outcomes).
7) UI enhancements: filtering by status, timing distributions.

---

## Area 4: Speculative Decoding + LLM Core

### Current Strengths
- Clear config, logging, metrics, and multi-GPU support.
- Demo script for algorithm explanation.

### Risks / Gaps
- Acceptance accounting inflates metrics and affects adaptive speculation.
- CLI `--auto-device-map` default overrides config default.
- Fallback generation ignores top_p/top_k options.

### Near-Term (0–2 weeks)
1) Fix acceptance metrics: count only draft tokens as accepted; mismatch token should not inflate acceptance.
2) Align CLI defaults with config defaults (auto-device-map on by default or explicit flag naming).
3) Make fallback generation respect top_p/top_k and temperature.
4) Add tests for acceptance accounting and adaptive K behavior.

### Mid-Term (2–6 weeks)
5) Add batch support and KV cache reuse (draft + target).
6) Add CLI flags for top_p/top_k with config mapping.

### Long-Term (6–12 weeks)
7) Add benchmark harness comparing standard vs speculative decoding.
8) Explore optimized kernels / better sampling implementations.

---

## Area 5: Tools & Experiments (Qwen3)

### Current Strengths
- Scripts cover scaling, inference, and LoRA training.

### Risks / Gaps
- `--streaming` flag always on and `model.eval()` missing.
- No seed or reproducibility controls.

### Near-Term (0–2 weeks)
1) Fix streaming flag behavior and set `model.eval()` + `torch.no_grad()`.
2) Add `--seed` and deterministic toggles.

### Mid-Term (2–6 weeks)
3) Factor shared utilities for model load, dtype selection, and dataset setup.

### Long-Term (6–12 weeks)
4) Integrate tools into Temporal pipelines for repeatable runs.

---

## Area 6: Skills + Developer Experience

### Current Strengths
- Local skill catalog is clear.
- LLM experiment skill adds GPU sanity + specdec runner.

### Risks / Gaps
- Skill documentation and entrypoints are slightly out of sync with AGENTS uv rules.

### Near-Term (0–2 weeks)
1) Align skill examples and entrypoints with Spack+uv constraints workflow.
2) Add a short “LLM experiments” block to README.

### Mid-Term (2–6 weeks)
3) Consolidate skill references (single index), reduce duplication.

### Long-Term (6–12 weeks)
4) Add lightweight skill validation checklist + template for new skills.

---

## Area 7: Validation, Testing, Repo Hygiene

### Current Strengths
- `validate_all.sh` covers Go + Python lint + shellcheck.
- Tests are collocated with modules.

### Risks / Gaps
- Pytest not invoked in validation.
- `.gitignore` misses venvs and caches.

### Near-Term (0–2 weeks)
1) Add pytest to `validate_all.sh` when available in venv.
2) Update `.gitignore` for `.venv/`, `.ruff_cache/`, `__pycache__/`.

### Mid-Term (2–6 weeks)
3) Add pre-commit config for lint/test hooks.

### Long-Term (6–12 weeks)
4) CI pipeline for container + spack smoke + python/go checks.

---

## Proposed Implementation Sequence (Draft)
1) Fix Temporal `ContainerJob` entrypoint + pipeline validation + tests.
2) Specdec metrics + CLI defaults + tests.
3) Validation updates (.gitignore + pytest in validate_all).
4) uv-install alignment with Spack+uv constraints.
5) Tools reproducibility fixes.

---

## Review Checklist
- [ ] Are priorities aligned with current operational pain?
- [ ] Which areas should be accelerated or deferred?
- [ ] Do we want lockfiles committed or local-only?
- [ ] Should GPU gating be strict (min CUDA) or permissive?
- [ ] Is the specdec CLI default behavior acceptable?

---

## Decisions Needed
- Lockfile policy for `pkg/zephyr`.
- Whether to enforce strict CUDA version gating or allow override.
- Whether specdec acceptance metrics should report both “accepted draft tokens” and “total tokens” metrics.

