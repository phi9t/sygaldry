# Sygaldry

Sygaldry is an AI/ML research infrastructure repo with two production subsystems:

- Zephyr container infrastructure for hermetic GPU runtime and multi-repo reuse.
- Temporal workflow engine for durable YAML DAG execution.

GPU-only infrastructure: NVIDIA Docker runtime is required.

> **New here?** See [GETTING_STARTED.md](GETTING_STARTED.md) for first-time setup.

## Most Important Features

### Zephyr Container Infrastructure

- Hermetic runtime model: heavy ML stack is prebuilt in Spack snapshot images.
- Layered package ownership: Spack owns torch/jax/llvm-class dependencies, uv installs app-layer packages on top.
- Vendorable repo-local kit: downstream repos can vendor `.sygaldry/zephyr` with the same `repoctl` and `jobctl` UX.
- Image modes for adoption:
  - `standard`: always use pinned snapshot image
  - `auto`: prefer local derived image, fallback to pinned snapshot
  - `derived`: require local derived image
- Verification tooling: `repoctl verify spack`, `repoctl verify uv-layering`, `repoctl verify image`.

### Temporal Workflow Engine

- YAML plan orchestration with strict validation and cycle/dependency guardrails.
- DAG scheduler with retries, conditional execution (`when`), and `allow_failure` semantics.
- Plan composition: `params`, `env`, template imports/overrides, output interpolation.
- Operational interfaces: `run`, `validate`, `status` with YAML or JSON output and async mode.
- Observability: step stdout/stderr artifacts, structured JSONL step logs, run manifest, events stream, CLI and web visualizer.

## Quick Start

### 1) Zephyr shell and GPU sanity

```bash
./container/launch_container.sh
# inside container
spack-env-activate
gpu-test
jax-test
```

### 2) Temporal first run

```bash
cd temporal
./scripts/run.sh examples/quickstart/01_hello.yaml
```

Progressive examples: `temporal/examples/quickstart/QUICKSTART.md`.

## Vendor Hermetic Zephyr Into Another Repo

From this repo:

```bash
tools/zephyr_vendor_infra.sh install \
  --target-repo /path/to/target-repo \
  --snapshot-image ghcr.io/phi9t/sygaldry/zephyr:spack-YYYYMMDD \
  --snapshot-digest <64-hex-digest>
```

Then in target repo:

```bash
.sygaldry/zephyr/bin/repoctl config show
.sygaldry/zephyr/bin/repoctl verify spack
.sygaldry/zephyr/bin/repoctl verify uv-layering --no-gpu
.sygaldry/zephyr/bin/repoctl shell
```

Optional derived-image path:

```bash
.sygaldry/zephyr/bin/repoctl image build --repo .
.sygaldry/zephyr/bin/repoctl verify image --repo .
```

Canonical manual: `docs/ZEPHYR_VENDORING_GUIDE.md`.

## Documentation Map (Canonical Sources)

- `GETTING_STARTED.md` — first-time user guide.
- `DEPLOYMENT.md` — fresh machine setup (NVIDIA, Docker, Go).
- `TROUBLESHOOTING.md` — common issues and diagnostics.
- `docs/ARCHITECTURE.md` — architecture overview (Zephyr + Temporal).
- `docs/TEMPORAL_PLAN_SCHEMA.md` — YAML plan field reference.
- `container/ZEPHYR_SYSTEM_DESIGN.md` - authoritative Zephyr infra contract.
- `docs/ZEPHYR_VENDORING_GUIDE.md` - canonical vendoring and operation manual.
- `temporal/TEMPORAL_DESIGN.md` - canonical Temporal design and roadmap state.
- `temporal/TEMPORAL_ONBOARDING_GUIDE.md` - Temporal onboarding workflow.
- `docs/ONBOARDING.md` - repo onboarding and execution path.
- `docs/ENGINEERING_EXCELLENCE_STANDARD.md` - canonical multi-language quality and enforcement standard.
- `docs/REVIEW_REFACTOR_RUBRIC.md` - review/refactor rubric and blocking criteria.
- `docs/quality/COVERAGE_BASELINE.yaml` - coverage ratchet baseline and waiver map.
- `docs/RELEASE_CHECKLIST.md` - release gate checklist.
- `docs/RELEASE_NOTES_2026-02.md` - current release notes.

## Validation

```bash
# Repo baseline
./validate_all.sh --quick

# Engineering quality gates
./validate_all.sh --quality-all --quality-strict

# Temporal engine
cd temporal && go vet ./... && go test ./... && ./scripts/test-e2e.sh

# Zephyr vendoring (target repo fixture)
tools/zephyr_vendor_infra.sh check --target-repo /path/to/target-repo
```

## Community

- GitHub Issues for bug reports and feature requests.
- See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## Troubleshooting

- NVIDIA/container runtime: `container/NVIDIA_FIXES.md`, `container/diagnose_nvidia.sh`
- Zephyr infra contract and policy: `container/ZEPHYR_SYSTEM_DESIGN.md`
- Temporal behavior and limits: `temporal/TEMPORAL_DESIGN.md`
- Visualizer: `cd temporal/visualizer && node server.js` then open `http://localhost:8787`
- See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the full guide.

## License

MIT License. See [LICENSE](LICENSE).
