# RFC-078: Extract rfc_impl.go Helpers to rfc_impl_util.go

**Status:** Open
**Date:** 2026-03-25
**Priority:** Medium
**Effort:** XS

---

## Problem

`temporal/internal/workflows/rfc_impl.go` is 738 lines. Lines 667–738 contain
10 pure helper functions that have no workflow-specific dependencies (no
`workflow.Context` parameters, no activity calls). Keeping them in the primary
workflow file inflates its size and makes both sections harder to read.

Helper functions at the bottom of `rfc_impl.go`:
- `extractSetOutput` (line 671)
- `rfcImplStatusSnapshot` (line 682)
- `setRFCImplTasksPending` (line 688)
- `setRFCImplTaskState` (line 695)
- `completeRFCImplStatus` (line 702)
- `rfcSafeID` (line 709)
- `rfcTasksFilePath` (line 714)
- `rfcWorktreePath` (line 718)
- `rfcPlanFilePath` (line 722)
- `toAgentTaskEngines` (line 729)

---

## Solution

Create `temporal/internal/workflows/rfc_impl_util.go` in the same `workflows`
package and move all 10 helper functions into it. Remove them from `rfc_impl.go`.

No import changes are needed — both files share the same package.

---

## Acceptance Criteria

1. `temporal/internal/workflows/rfc_impl_util.go` exists and contains all 10
   helper functions
2. `rfc_impl.go` no longer contains those helpers (line count ≤ 670)
3. `cd temporal && go build ./... && go test ./...` passes
