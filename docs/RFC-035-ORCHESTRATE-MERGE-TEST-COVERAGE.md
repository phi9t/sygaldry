# RFC-035: Add Test Coverage for orchestrate merge* Functions

**Status:** Proposed
**Priority:** Medium
**Effort:** M
**Area:** testing

## Problem

`temporal/cmd/orchestrate/main.go` has zero test coverage on its `merge*` functions:
- `mergeRetrySpec`
- `mergeDownloadSpec`
- `mergeDockerBuildSpec`
- `mergeDockerPushSpec`
- `mergePackageBuildSpec`
- `mergeContainerJobSpec`
- `mergeHFDownloadDatasetSpec`
- `mergeHFDownloadModelSpec`
- `mergeAgentTaskSpec`
- `mergeK8sJobSpec`
- `mergeMultiEngineAgentTaskSpec`

Additionally, `printOutput`, `writePlanManifest`, and `safeFilename` have 0% coverage. The overall `cmd/orchestrate` coverage is 54.8%, with most of the gaps concentrated in these merge helpers.

The merge functions implement the override-from-global logic that is central to the YAML plan execution: if a user sets `timeout_seconds: 3600` at the plan level and `300` at the step level, the step value should win. A bug here silently discards step-level config.

## Evidence

Running `go test ./... -coverprofile=/tmp/cover.out && go tool cover -func=/tmp/cover.out` in `temporal/`:

```
temporal-orchestration/cmd/orchestrate/main.go:mergeRetrySpec         0.0%
temporal-orchestration/cmd/orchestrate/main.go:mergeDownloadSpec       0.0%
temporal-orchestration/cmd/orchestrate/main.go:mergeDockerBuildSpec    0.0%
...
temporal-orchestration/cmd/orchestrate/main.go:safeFilename            0.0%
temporal-orchestration/cmd/orchestrate/main.go:printOutput             0.0%
```

## Proposed Changes

1. Add `temporal/cmd/orchestrate/merge_test.go` with table-driven tests for every `merge*` function:
   ```go
   func TestMergeRetrySpec(t *testing.T) {
       cases := []struct {
           name     string
           global   *RetrySpec
           step     *RetrySpec
           expected *RetrySpec
       }{
           {"nil global and step returns default", nil, nil, &RetrySpec{MaxAttempts: 1}},
           {"step overrides global", &RetrySpec{MaxAttempts: 3}, &RetrySpec{MaxAttempts: 5}, &RetrySpec{MaxAttempts: 5}},
           {"nil step inherits global", &RetrySpec{MaxAttempts: 3}, nil, &RetrySpec{MaxAttempts: 3}},
       }
       // ...
   }
   ```

2. Add tests for `safeFilename` covering: empty string, string with spaces, string with special chars, very long string.

3. Add tests for `writePlanManifest` using a temp dir.

4. Target: bring `cmd/orchestrate` coverage above 85%.

## Files Changed

- `temporal/cmd/orchestrate/merge_test.go` — new file with merge* test suite

## Verification

```bash
cd temporal && go test ./cmd/orchestrate/... -coverprofile=/tmp/cover.out
go tool cover -func=/tmp/cover.out | grep orchestrate
# cmd/orchestrate coverage must be >= 85%
```
