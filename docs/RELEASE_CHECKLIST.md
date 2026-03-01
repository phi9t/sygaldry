# Release Checklist

Scope: internal release of Sygaldry Zephyr container infra and Temporal workflow engine.

## 1) Documentation Gate

- [ ] `README.md` reflects current subsystem scope and canonical doc map.
- [ ] `docs/ONBOARDING.md` matches current onboarding flow.
- [ ] `docs/ZEPHYR_VENDORING_GUIDE.md` is accurate for `repoctl`/`jobctl` and image modes.
- [ ] `temporal/README.md` matches current CLI and step-type support.
- [ ] `temporal/TEMPORAL_DESIGN.md` updated if behavior changed.
- [ ] Release notes and readiness review are updated:
  - `docs/RELEASE_NOTES_2026-02.md`
  - `docs/RELEASE_READINESS_REVIEW_2026-02.md`

## 2) Code Validation Gate

Run from repo root unless noted:

```bash
./validate_all.sh --quick
./validate_all.sh --quality-all --quality-strict
cd temporal && go vet ./... && go test ./... && ./scripts/test-e2e.sh
```

Optional expanded gate:

```bash
cd temporal && ./scripts/e2e/run_medium.sh
```

If `shellcheck` is available in the environment:

```bash
./validate_all.sh
```

## 3) Zephyr Vendoring Gate

Fixture-repo validation from `sygaldry` root:

```bash
tools/zephyr_vendor_infra.sh install --target-repo <fixture_repo> --snapshot-image <image> --snapshot-digest <digest>
tools/zephyr_vendor_infra.sh check --target-repo <fixture_repo>
```

In fixture repo:

```bash
.sygaldry/zephyr/bin/repoctl config show
.sygaldry/zephyr/bin/repoctl verify image --skip-spack
.sygaldry/zephyr/bin/repoctl verify spack
.sygaldry/zephyr/bin/repoctl verify uv-layering --no-gpu
```

Derived-image flow (optional but recommended):

```bash
.sygaldry/zephyr/bin/repoctl image build --repo .
.sygaldry/zephyr/bin/repoctl verify image --repo .
```

## 4) Temporal Operational Gate

- [ ] `./scripts/run.sh examples/quickstart/01_hello.yaml` succeeds.
- [ ] `go run ./cmd/orchestrate validate -plan examples/quickstart/03_outputs.yaml` succeeds.
- [ ] `./scripts/logs_cli.py summary --latest` returns latest run summary.
- [ ] Visualizer starts with `node visualizer/server.js` and serves `http://localhost:8787`.

## 5) Release Artifacts

- [ ] `LICENSE` present at repo root.
- [ ] `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md` present (or explicitly deferred).
- [ ] No internal-only docs at public surface (`docs/internal/` is the triage destination).
- [ ] `temporal/docker-compose.yml` has dev-only credential comment.
- [ ] `container/logs/` in `.gitignore`; no log files tracked (`git ls-files container/logs/` is empty).
- [ ] Tag or version metadata updated if required by release process.
- [ ] Internal announcement prepared with:
  - core feature highlights
  - validation status
  - known risks and rollback notes
- [ ] Rollback path documented for Zephyr image mode (`derived` -> `standard`).

## 6) Sign-off

| Area | Owner | Status |
|------|-------|--------|
| Zephyr infra | Container maintainers | [ ] |
| Temporal engine | Workflow maintainers | [ ] |
| Docs | Maintainers | [ ] |
| Release readiness | Release owner | [ ] |
