# RFC-008: Pipeline Step Hardening

**Status:** Draft — v1
**Date:** 2026-03-16
**Priority:** Medium

---

## 1. Problem

Three hardening issues across the Temporal pipeline step execution path.

### 1.1 `K8sJob` activity is a stub

`temporal/internal/workflows/pipeline.go:78-87` defines `K8sJobSpec`:
```go
type K8sJobSpec struct {
    ProjectID  string            `yaml:"project_id"`
    Entrypoint string            `yaml:"entrypoint"`
    Command    string            `yaml:"command"`
    Env        map[string]string `yaml:"env"`
    GPU        bool              `yaml:"gpu"`
    GPUCount   int               `yaml:"gpu_count"`
    Image      string            `yaml:"image"`
    Namespace  string            `yaml:"namespace"`
}
```

`temporal/cmd/worker/main.go:54` registers `activities.K8sJob`. But looking at the activities package, `K8sJob` is either missing or is a stub that returns an unimplemented error. Pipeline YAMLs using `type: k8s_job` will fail at runtime with no clear error at validation time.

### 1.2 `ContainerJobSpec.LauncherPath` is a footgun

`pipeline.go:57-63`:
```go
type ContainerJobSpec struct {
    ...
    LauncherPath string `yaml:"launcher_path"`  // optional override
}
```

`launcher_path` allows pipeline authors to override the container launcher with an arbitrary path. This is a security and portability footgun — if the path doesn't exist on the worker host, the job silently fails or runs the wrong binary.

### 1.3 No early validation of step spec completeness

`cmd/orchestrate/main.go` validates step types and dependency graphs at plan submission time, but does not validate that type-specific spec fields are present. A step with `type: hf_download_model` but missing `hf_download_model.model_id` only fails at activity execution time — potentially hours into a multi-step pipeline.

---

## 2. Changes

### Change 1 — Implement `K8sJob` activity or emit clear "not implemented" error

**Option A (recommended short-term):** Make `K8sJob` return a clear, actionable error:
```go
// temporal/internal/activities/k8s_job.go
func K8sJob(ctx context.Context, input K8sJobInput) (RunCommandResult, error) {
    return RunCommandResult{ExitCode: -1}, temporal.NewNonRetryableApplicationError(
        "k8s_job step type is not yet implemented; use container_job instead",
        "NotImplemented",
        nil,
    )
}
```

**Option B (complete implementation):** Implement `K8sJob` using `kubectl`:
```go
func K8sJob(ctx context.Context, input K8sJobInput) (RunCommandResult, error) {
    // 1. Generate Job manifest from input
    manifest := buildK8sJobManifest(input)

    // 2. Apply: kubectl apply -f -
    // 3. Wait for completion: kubectl wait job/<name> --for=condition=complete
    // 4. Collect logs: kubectl logs job/<name>
    // 5. Delete: kubectl delete job/<name>
}
```

Option B requires `kubectl` on the worker host. Implement Option A first (one-day task) to prevent silent failures, then Option B in a follow-up.

### Change 2 — Remove `launcher_path` from `ContainerJobSpec`

`launcher_path` was added as an escape hatch but is never used in any existing pipeline YAML. Remove it:

```go
// DELETE from ContainerJobSpec:
LauncherPath string `json:"launcherPath" yaml:"launcher_path"`
```

Update `ContainerJob` activity to not accept a launcher path override. The launcher is always `zephyr` (after RFC-002 is merged) or the default at `${SYGALDRY_HOME}/bin/sygaldry`.

This is a breaking change for anyone using `launcher_path` — but a grep confirms no existing YAML uses it:
```bash
grep -r "launcher_path" temporal/examples/ tools/agentic/
# Expected: no results
```

### Change 3 — Early spec validation in `cmd/orchestrate`

**File:** `temporal/cmd/orchestrate/main.go`

Add a `validateStepSpec()` function called during plan validation that checks type-specific required fields:

```go
func validateStepSpec(step PipelineStep) error {
    switch step.Type {
    case "hf_download_model":
        if step.HFDownloadModel == nil || step.HFDownloadModel.ModelID == "" {
            return fmt.Errorf("step %q: hf_download_model.model_id is required", step.ID)
        }
    case "hf_download_dataset":
        if step.HFDownloadDataset == nil || step.HFDownloadDataset.DatasetID == "" {
            return fmt.Errorf("step %q: hf_download_dataset.dataset_id is required", step.ID)
        }
    case "container_job":
        if step.ContainerJob == nil {
            return fmt.Errorf("step %q: container_job spec is required", step.ID)
        }
    case "k8s_job":
        return fmt.Errorf("step %q: k8s_job is not yet implemented; use container_job", step.ID)
    case "download":
        if step.Download == nil || step.Download.URL == "" {
            return fmt.Errorf("step %q: download.url is required", step.ID)
        }
    case "docker_build":
        if step.DockerBuild == nil || step.DockerBuild.Image == "" {
            return fmt.Errorf("step %q: docker_build.image is required", step.ID)
        }
    case "agent_task":
        if step.AgentTask == nil {
            return fmt.Errorf("step %q: agent_task spec is required", step.ID)
        }
        if step.AgentTask.Prompt == "" && step.AgentTask.PromptFile == "" {
            return fmt.Errorf("step %q: agent_task requires prompt or prompt_file", step.ID)
        }
    }
    return nil
}
```

Call `validateStepSpec()` from the existing validation loop in `cmd/orchestrate/main.go`. Add tests in `cmd/orchestrate/main_test.go` for each case.

---

## 3. Files Changed

| File | Action |
|------|--------|
| `temporal/internal/activities/k8s_job.go` | New — clear "not implemented" error (or full impl) |
| `temporal/internal/workflows/pipeline.go` | Remove `LauncherPath` from `ContainerJobSpec` |
| `temporal/cmd/orchestrate/main.go` | Add `validateStepSpec()`, call in validation |
| `temporal/cmd/orchestrate/main_test.go` | Tests for new validation cases |

---

## 4. Verification

```bash
cd temporal && go test ./...

# Validate a plan using k8s_job → should fail with clear error at validation
go run ./cmd/orchestrate validate -plan examples/k8s_job_test.yaml
# Expected: "step 'train': k8s_job is not yet implemented; use container_job"

# Validate missing model_id → should fail at plan time not execution
cat > /tmp/bad_plan.yaml <<'EOF'
steps:
  - id: dl
    type: hf_download_model
    hf_download_model: {}
EOF
go run ./cmd/orchestrate validate -plan /tmp/bad_plan.yaml
# Expected: "step 'dl': hf_download_model.model_id is required"
```

---

## 5. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Removing `launcher_path` breaks existing YAMLs | Near-zero | grep confirms no usage |
| K8s job validation error is over-broad | Low | Error message is explicit: "use container_job" |
| `validateStepSpec` too strict for optional fields | Low | Only validate fields documented as required in CLAUDE.md |
