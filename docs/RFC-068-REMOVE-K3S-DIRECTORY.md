# RFC-068: Remove k3s/ Directory

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Low
**Effort:** XS
**Blocked By:** RFC-061

---

## Problem

The `k3s/` directory contains the entire Kubernetes K3s batch-job infrastructure
(CLI tools, lib, manifests, templates) that was built to support the `k8s_job` step type.
RFC-061 removes `K8sJob` from the Temporal activities layer — after that, `k3s/` has
zero consumers in the codebase:

- `temporal/internal/activities/steps.go:743` — the only Go reference to `k3s/bin/kjob`
  is inside `K8sJob()`, which RFC-061 deletes
- No shell scripts, YAML pipelines, Python files, or documentation outside `k3s/` itself
  reference `k3s/`, `kjob`, or `kentai`
- The main architecture (CLAUDE.md, SYSTEM_DESIGN.md) describes Docker + Spack; K3s is
  not part of the documented infrastructure

Retaining `k3s/` after RFC-061 lands would be dead infrastructure with no path to use.

---

## Solution

Delete the entire directory tree:

```
k3s/
├── bin/
│   ├── kjob
│   └── kentai
├── bootstrap/
│   └── setup-nvidia.sh
├── lib/
│   └── k3s-common.sh
├── manifests/
│   └── (YAML manifests)
└── templates/
    └── (job templates)
```

No code outside `k3s/` needs updating (all references are inside `K8sJob()`, which
RFC-061 removes first).

---

## Acceptance Criteria

1. `k3s/` directory does not exist.
2. `grep -rn "k3s/\|kjob\|kentai" . --include="*.go" --include="*.sh" --include="*.py" --include="*.yaml"` returns 0 matches (excluding `docs/RFC-*.md`).
3. `cd temporal && go build ./...` passes (confirms no dangling imports).
