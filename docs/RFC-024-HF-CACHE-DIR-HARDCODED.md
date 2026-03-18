# RFC-024: Stop Hardcoding HF Cache Dir in Activities

**Status:** Proposed
**Priority:** Medium
**Effort:** XS
**Area:** temporal

## Problem

`HFDownloadDataset` and `HFDownloadModel` in `temporal/internal/activities/steps.go` ignore the `CacheDir` field on their input structs and unconditionally set `cacheDir := "/opt/hf_cache"`. This breaks any pipeline that runs outside the standard Sygaldry container layout, and makes the activities impossible to unit-test without mocking the filesystem at `/opt/hf_cache`.

## Evidence

`temporal/internal/activities/steps.go` — `HFDownloadDataset` (~line 703):
```go
cacheDir := "/opt/hf_cache"
if input.CacheDir != "" {
    // this branch exists but the assignment above overwrites it
```

Wait — the evidence is the absence of the branch. The actual code is:
```go
cacheDir := "/opt/hf_cache"
```
with no subsequent conditional. The `HFDownloadDatasetInput` struct has no `CacheDir` field, confirming the field was never threaded through.

Similarly for `HFDownloadModel` (~line 749).

## Proposed Changes

1. Add `CacheDir string \`json:"cacheDir"\`` to both `HFDownloadDatasetInput` and `HFDownloadModelInput`.
2. In both activity functions, resolve cache dir with a fallback:
   ```go
   cacheDir := input.CacheDir
   if cacheDir == "" {
       cacheDir = os.Getenv("HF_HOME")
   }
   if cacheDir == "" {
       cacheDir = "/opt/hf_cache"
   }
   ```
3. Thread the `cache_dir` field through the YAML pipeline step spec:
   ```go
   type HFDownloadModelSpec struct {
       ModelID  string `yaml:"model_id" json:"modelId"`
       CacheDir string `yaml:"cache_dir" json:"cacheDir"`
   }
   ```
4. Update `startActivity()` in `pipeline.go` to pass `spec.CacheDir` when constructing the activity input.

## Files Changed

- `temporal/internal/activities/steps.go` — `HFDownloadDatasetInput`, `HFDownloadModelInput`, both activity functions
- `temporal/cmd/orchestrate/main.go` — `HFDownloadDatasetSpec`, `HFDownloadModelSpec`
- `temporal/internal/workflows/pipeline.go` — `startActivity()` case for `hf_download_*`

## Verification

```bash
cd temporal && go build ./...
go test ./internal/activities/...
# Add a test that passes CacheDir="/tmp/test-hf" and verifies HF_HOME is set correctly.
```
