# RFC-061: Remove Unused k8s_job Step Type

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Low
**Effort:** S

---

## Problem

The `k8s_job` step type is fully implemented but never used: zero YAML pipeline examples
reference it, no end-to-end tests exercise it, and no production plans invoke it. It adds
dead surface area to the plan schema, the validator, and the activity implementation —
increasing cognitive overhead for contributors and creating maintenance burden without
providing value.

---

## Solution

### Edit `temporal/internal/activities/steps.go`

- Remove `K8sJobInput` struct (line 357)
- Remove `K8sJob` function (lines 693–776)

### Edit `temporal/internal/workflows/pipeline.go`

- Remove `K8sJobSpec` struct (line 78)
- Remove `K8sJob *K8sJobSpec` field from the step struct (line 134)
- Remove env-merge cases for K8sJob (lines 506–507, 524–525)
- Remove `case "k8s_job":` switch arm (lines 830–835)

### Edit `temporal/internal/plan/validator.go`

- Remove `"k8s_job": true` from the valid types map (line 21)
- Remove `case "k8s_job":` validation block (lines 93–95)

### Edit `temporal/internal/activities/steps_test.go`

- Remove `TestK8sJobValidation` (line 448)

---

## Acceptance Criteria

1. `grep -rn "k8s_job\|K8sJob\|K8sJobSpec\|K8sJobInput" temporal/` returns 0 matches.
2. `cd temporal && go build ./...` passes.
3. `cd temporal && go test ./...` passes.
