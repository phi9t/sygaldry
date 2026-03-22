package workflows

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

func TestNewPipelineStatusStartsPending(t *testing.T) {
	steps := []PipelineStep{{ID: "build"}, {ID: "test"}}
	status := newPipelineStatus("wf-123", steps)

	if status.WorkflowID != "wf-123" {
		t.Fatalf("workflow id = %q, want wf-123", status.WorkflowID)
	}
	if status.Phase != "running" {
		t.Fatalf("phase = %q, want running", status.Phase)
	}
	if got := status.StepStates["build"]; got != "pending" {
		t.Fatalf("build state = %q, want pending", got)
	}
	if got := status.StepStates["test"]; got != "pending" {
		t.Fatalf("test state = %q, want pending", got)
	}
}

func TestPipelineStatusSnapshotClonesMap(t *testing.T) {
	status := newPipelineStatus("wf-123", []PipelineStep{{ID: "build"}})
	snapshot := pipelineStatusSnapshot(status)
	snapshot.StepStates["build"] = "failed"

	if got := status.StepStates["build"]; got != "pending" {
		t.Fatalf("original state mutated to %q", got)
	}
}

func TestSetPipelineStepRunningTracksCurrentStep(t *testing.T) {
	status := newPipelineStatus("wf-123", []PipelineStep{{ID: "build", Name: "Build"}})
	setPipelineStepRunning(&status, PipelineStep{ID: "build", Name: "Build"})

	if got := status.StepStates["build"]; got != "running" {
		t.Fatalf("build state = %q, want running", got)
	}
	if status.CurrentStepID != "build" || status.CurrentStepName != "Build" {
		t.Fatalf("current step = %q/%q, want build/Build", status.CurrentStepID, status.CurrentStepName)
	}
}

func TestResolveStepOutcomeCanceledOnCancelSignal(t *testing.T) {
	run := runningStep{step: PipelineStep{ID: "build", Name: "Build"}}
	outcomes := map[string]StepOutcome{}

	outcome, earlyReturn := resolveStepOutcome(
		run,
		PipelineStepResult{Name: "Build"},
		temporal.NewCanceledError("cancelled"),
		outcomes,
		[]string{"build"},
		true,
	)

	if outcome.State != "canceled" {
		t.Fatalf("state = %q, want canceled", outcome.State)
	}
	if earlyReturn == nil {
		t.Fatal("expected early return on cancel")
	}
	if !temporal.IsCanceledError(earlyReturn.err) {
		t.Fatalf("expected canceled error, got %v", earlyReturn.err)
	}
}

// ---------------------------------------------------------------------------
// depsCompleted
// ---------------------------------------------------------------------------

func TestDepsCompleted(t *testing.T) {
	outcomes := map[string]StepOutcome{
		"a": {ID: "a", State: "success"},
		"b": {ID: "b", State: "failed"},
	}

	tests := []struct {
		name string
		step PipelineStep
		want bool
	}{
		{"no deps", PipelineStep{ID: "c"}, true},
		{"all deps completed", PipelineStep{ID: "c", DependsOn: []string{"a", "b"}}, true},
		{"missing dep", PipelineStep{ID: "c", DependsOn: []string{"a", "x"}}, false},
		{"empty deps list", PipelineStep{ID: "c", DependsOn: []string{}}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := depsCompleted(tt.step, outcomes); got != tt.want {
				t.Errorf("depsCompleted() = %v, want %v", got, tt.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// shouldSkip
// ---------------------------------------------------------------------------

func TestShouldSkip(t *testing.T) {
	outcomes := map[string]StepOutcome{
		"a": {ID: "a", State: "success"},
		"b": {ID: "b", State: "failed"},
	}

	tests := []struct {
		name       string
		step       PipelineStep
		wantSkip   bool
		wantReason string
	}{
		{
			"no when, all deps succeeded",
			PipelineStep{ID: "c", DependsOn: []string{"a"}},
			false, "",
		},
		{
			"no when, dep failed",
			PipelineStep{ID: "c", DependsOn: []string{"b"}},
			true, "dependency b did not succeed",
		},
		{
			"no when, no deps",
			PipelineStep{ID: "c"},
			false, "",
		},
		{
			"no when, multiple deps all success",
			PipelineStep{ID: "c", DependsOn: []string{"a"}},
			false, "",
		},
		{
			"no when, one dep failed among many",
			PipelineStep{ID: "c", DependsOn: []string{"a", "b"}},
			true, "dependency b did not succeed",
		},
		{
			"when success matches",
			PipelineStep{ID: "c", When: &When{Step: "a", Status: "success"}},
			false, "",
		},
		{
			"when success doesn't match",
			PipelineStep{ID: "c", When: &When{Step: "b", Status: "success"}},
			true, "when condition not met: b is success",
		},
		{
			"when failure matches",
			PipelineStep{ID: "c", When: &When{Step: "b", Status: "failure"}},
			false, "",
		},
		{
			"when failure doesn't match",
			PipelineStep{ID: "c", When: &When{Step: "a", Status: "failure"}},
			true, "when condition not met: a is failure",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			skip, reason := shouldSkip(tt.step, outcomes)
			if skip != tt.wantSkip {
				t.Errorf("shouldSkip() skip = %v, want %v", skip, tt.wantSkip)
			}
			if reason != tt.wantReason {
				t.Errorf("shouldSkip() reason = %q, want %q", reason, tt.wantReason)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// ordered
// ---------------------------------------------------------------------------

func TestOrdered(t *testing.T) {
	outcomes := map[string]StepOutcome{
		"b": {ID: "b"},
		"a": {ID: "a"},
		"c": {ID: "c"},
	}
	order := []string{"a", "b", "c"}

	result := ordered(outcomes, order)
	if len(result) != 3 {
		t.Fatalf("len(result) = %d, want 3", len(result))
	}
	for i, id := range order {
		if result[i].ID != id {
			t.Errorf("result[%d].ID = %q, want %q", i, result[i].ID, id)
		}
	}
}

func TestOrderedWithExtra(t *testing.T) {
	outcomes := map[string]StepOutcome{
		"a":     {ID: "a"},
		"extra": {ID: "extra"},
	}
	order := []string{"a"}

	result := ordered(outcomes, order)
	if len(result) != 2 {
		t.Fatalf("len(result) = %d, want 2", len(result))
	}
	if result[0].ID != "a" {
		t.Errorf("result[0].ID = %q, want %q", result[0].ID, "a")
	}
	if result[1].ID != "extra" {
		t.Errorf("result[1].ID = %q, want %q", result[1].ID, "extra")
	}
}

func TestOrderedEmpty(t *testing.T) {
	result := ordered(map[string]StepOutcome{}, []string{})
	if len(result) != 0 {
		t.Errorf("expected empty result, got %d", len(result))
	}
}

// ---------------------------------------------------------------------------
// stepName
// ---------------------------------------------------------------------------

func TestStepName(t *testing.T) {
	tests := []struct {
		step PipelineStep
		want string
	}{
		{PipelineStep{ID: "foo", Name: "bar"}, "bar"},
		{PipelineStep{ID: "foo"}, "foo"},
		{PipelineStep{ID: "foo", Name: ""}, "foo"},
	}
	for _, tt := range tests {
		if got := stepName(tt.step); got != tt.want {
			t.Errorf("stepName(%+v) = %q, want %q", tt.step, got, tt.want)
		}
	}
}

// ---------------------------------------------------------------------------
// PipelineInput / PipelineStep YAML parsing
// ---------------------------------------------------------------------------

func TestPipelineStepTypes(t *testing.T) {
	// Verify struct fields exist for all step types
	step := PipelineStep{
		ID:   "test",
		Type: "container_job",
		ContainerJob: &ContainerJobSpec{
			ProjectID:  "my-project",
			Command:    "python train.py",
			Entrypoint: "run-job.sh",
			GPU:        true,
		},
	}
	if step.ContainerJob.ProjectID != "my-project" {
		t.Error("ContainerJobSpec fields not accessible")
	}

	step2 := PipelineStep{
		ID:   "dl",
		Type: "hf_download_model",
		HFDownloadModel: &HFDownloadModelSpec{
			ModelID:  "Qwen/Qwen3-0.6B-Base",
			CacheDir: "/opt/hf_cache",
		},
	}
	if step2.HFDownloadModel.ModelID != "Qwen/Qwen3-0.6B-Base" {
		t.Error("HFDownloadModelSpec fields not accessible")
	}

	step3 := PipelineStep{
		ID:   "ds",
		Type: "hf_download_dataset",
		HFDownloadDataset: &HFDownloadDatasetSpec{
			DatasetID: "HuggingFaceFW/fineweb",
			Config:    "default",
			Split:     "train[:100]",
		},
	}
	if step3.HFDownloadDataset.DatasetID != "HuggingFaceFW/fineweb" {
		t.Error("HFDownloadDatasetSpec fields not accessible")
	}
}

// ---------------------------------------------------------------------------
// waitActivity result mapping (type assertions)
// ---------------------------------------------------------------------------

func TestPipelineStepResultFields(t *testing.T) {
	r := PipelineStepResult{
		Name:            "test",
		ExitCode:        0,
		Stdout:          "out",
		Stderr:          "err",
		StdoutPath:      "/tmp/stdout",
		StderrPath:      "/tmp/stderr",
		StructuredPath:  "/tmp/structured",
		StdoutTruncated: true,
		StderrTruncated: false,
		Succeeded:       true,
		DurationSec:     42,
		Outputs:         map[string]string{"k": "v"},
	}
	if !r.Succeeded || r.ExitCode != 0 || r.DurationSec != 42 {
		t.Error("PipelineStepResult fields not correctly set")
	}
	if r.Outputs["k"] != "v" {
		t.Errorf("outputs not set: %+v", r.Outputs)
	}
}

func TestStepOutcomeFields(t *testing.T) {
	o := StepOutcome{
		ID:         "step-1",
		Name:       "Step One",
		State:      "success",
		SkipReason: "",
	}
	if o.State != "success" || o.SkipReason != "" {
		t.Error("StepOutcome fields not correctly set")
	}

	skipped := StepOutcome{
		ID:         "step-2",
		State:      "skipped",
		SkipReason: "dep failed",
	}
	if skipped.State != "skipped" || skipped.SkipReason != "dep failed" {
		t.Error("skipped StepOutcome fields not correctly set")
	}
}

func TestParseStepOutputs(t *testing.T) {
	out := parseStepOutputs(strings.Join([]string{
		"plain line",
		"::set-output name=image_tag::my-org/my-image:abc",
		"::set-output name=model_id::Qwen/Qwen3-0.6B-Base",
	}, "\n"))
	if len(out) != 2 {
		t.Fatalf("expected 2 outputs, got %d", len(out))
	}
	if out["image_tag"] != "my-org/my-image:abc" {
		t.Fatalf("unexpected image_tag: %+v", out)
	}
}

func TestExpandTemplateString(t *testing.T) {
	got, err := expandTemplateString("hello ${{ params.name }}", func(expr string) (string, error) {
		if strings.TrimSpace(expr) == "params.name" {
			return "world", nil
		}
		return "", nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if got != "hello world" {
		t.Fatalf("got %q", got)
	}
}

func TestExpandStepTemplates(t *testing.T) {
	step := PipelineStep{
		ID:      "build",
		Type:    "command",
		Command: "echo ${{ params.version }}",
		Env: map[string]string{
			"IMAGE": "${{ params.repo }}:${{ params.version }}",
		},
	}
	outcomes := map[string]StepOutcome{
		"prev": {
			ID: "prev",
			Result: PipelineStepResult{
				Outputs: map[string]string{"tag": "v1"},
			},
		},
	}
	err := expandStepTemplates(&step, outcomes, map[string]string{"version": "1.2.3", "repo": "my/repo"}, map[string]string{"X": "Y"})
	if err != nil {
		t.Fatalf("expandStepTemplates failed: %v", err)
	}
	if step.Command != "echo 1.2.3" {
		t.Fatalf("unexpected command: %q", step.Command)
	}
	if step.Env["IMAGE"] != "my/repo:1.2.3" {
		t.Fatalf("unexpected env IMAGE: %q", step.Env["IMAGE"])
	}
}

func TestActivityOptionsForStepRetry(t *testing.T) {
	base := activityOptionsForStep(
		workflowActivityOptionsStub(),
		PipelineStep{
			ID: "step-a",
			Retry: &RetrySpec{
				MaxAttempts:            7,
				InitialIntervalSeconds: 3,
				BackoffCoefficient:     1.5,
				MaximumIntervalSeconds: 40,
			},
		},
	)
	if base.RetryPolicy == nil {
		t.Fatal("retry policy is nil")
	}
	if base.RetryPolicy.MaximumAttempts != 7 {
		t.Fatalf("max attempts = %d", base.RetryPolicy.MaximumAttempts)
	}
	if base.RetryPolicy.InitialInterval != 3*time.Second {
		t.Fatalf("initial interval = %s", base.RetryPolicy.InitialInterval)
	}
}

func workflowActivityOptionsStub() workflow.ActivityOptions {
	return workflow.ActivityOptions{
		StartToCloseTimeout: 2 * time.Hour,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    5 * time.Second,
			BackoffCoefficient: 2,
			MaximumInterval:    1 * time.Minute,
			MaximumAttempts:    3,
		},
	}
}

// ---------------------------------------------------------------------------
// resolveStepOutcome
// ---------------------------------------------------------------------------

func TestResolveStepOutcomeSuccess(t *testing.T) {
	run := runningStep{step: PipelineStep{ID: "s1", Name: "Step 1"}}
	result := PipelineStepResult{ExitCode: 0, Stdout: "ok"}
	outcomes := map[string]StepOutcome{}
	order := []string{"s1"}

	outcome, earlyReturn := resolveStepOutcome(run, result, nil, outcomes, order, false)
	if outcome.State != "success" {
		t.Errorf("State = %q, want success", outcome.State)
	}
	if earlyReturn != nil {
		t.Error("should not early return on success")
	}
}

func TestResolveStepOutcomeNonZeroExit(t *testing.T) {
	run := runningStep{step: PipelineStep{ID: "s1", AllowFailure: false}}
	result := PipelineStepResult{ExitCode: 1}
	outcomes := map[string]StepOutcome{}
	order := []string{"s1"}

	outcome, earlyReturn := resolveStepOutcome(run, result, nil, outcomes, order, false)
	if outcome.State != "failed" {
		t.Errorf("State = %q, want failed", outcome.State)
	}
	if earlyReturn == nil {
		t.Fatal("should early return on non-zero exit without AllowFailure")
	}
	if earlyReturn.Succeeded {
		t.Error("early return should not be Succeeded")
	}
}

func TestResolveStepOutcomeNonZeroExitAllowed(t *testing.T) {
	run := runningStep{step: PipelineStep{ID: "s1", AllowFailure: true}}
	result := PipelineStepResult{ExitCode: 1}
	outcomes := map[string]StepOutcome{}
	order := []string{"s1"}

	outcome, earlyReturn := resolveStepOutcome(run, result, nil, outcomes, order, false)
	if outcome.State != "failed" {
		t.Errorf("State = %q, want failed", outcome.State)
	}
	if earlyReturn != nil {
		t.Error("should NOT early return when AllowFailure is true")
	}
}

func TestResolveStepOutcomeActivityError(t *testing.T) {
	run := runningStep{step: PipelineStep{ID: "s1"}}
	result := PipelineStepResult{}
	outcomes := map[string]StepOutcome{}
	order := []string{"s1"}

	outcome, earlyReturn := resolveStepOutcome(run, result, fmt.Errorf("timeout"), outcomes, order, false)
	if outcome.State != "failed" {
		t.Errorf("State = %q, want failed", outcome.State)
	}
	if outcome.Result.Error != "timeout" {
		t.Errorf("Error = %q, want timeout", outcome.Result.Error)
	}
	if earlyReturn == nil {
		t.Fatal("should early return on activity error")
	}
}

func TestResolveStepOutcomeActivityErrorAllowed(t *testing.T) {
	run := runningStep{step: PipelineStep{ID: "s1", AllowFailure: true}}
	result := PipelineStepResult{}
	outcomes := map[string]StepOutcome{}
	order := []string{"s1"}

	_, earlyReturn := resolveStepOutcome(run, result, fmt.Errorf("timeout"), outcomes, order, false)
	if earlyReturn != nil {
		t.Error("should NOT early return when AllowFailure is true")
	}
}

func TestSortedStepIDs(t *testing.T) {
	steps := map[string]PipelineStep{
		"b-step": {ID: "b-step"},
		"a-step": {ID: "a-step"},
		"c-step": {ID: "c-step"},
	}
	ids := sortedStepIDs(steps)
	if len(ids) != 3 {
		t.Fatalf("want 3 IDs, got %d", len(ids))
	}
	for i, want := range []string{"a-step", "b-step", "c-step"} {
		if ids[i] != want {
			t.Errorf("ids[%d] = %q, want %q", i, ids[i], want)
		}
	}
}

func TestSortedStepIDsEmpty(t *testing.T) {
	ids := sortedStepIDs(map[string]PipelineStep{})
	if len(ids) != 0 {
		t.Errorf("expected empty slice, got %v", ids)
	}
}

func TestCloneMap(t *testing.T) {
	orig := map[string]string{"a": "1", "b": "2"}
	clone := cloneMap(orig)
	if clone["a"] != "1" || clone["b"] != "2" {
		t.Errorf("cloneMap content mismatch: %v", clone)
	}
	// Mutations to clone must not affect original
	clone["a"] = "mutated"
	if orig["a"] != "1" {
		t.Error("cloneMap shared backing storage with original")
	}
}

func TestCloneMapEmpty(t *testing.T) {
	result := cloneMap(nil)
	if result == nil || len(result) != 0 {
		t.Errorf("cloneMap(nil) = %v, want empty map", result)
	}
}

func TestMergeStringMaps(t *testing.T) {
	base := map[string]string{"a": "1", "b": "2"}
	override := map[string]string{"b": "override", "c": "3"}
	result := mergeStringMaps(base, override)
	if result["a"] != "1" {
		t.Errorf("a = %q, want 1", result["a"])
	}
	if result["b"] != "override" {
		t.Errorf("b = %q, want override", result["b"])
	}
	if result["c"] != "3" {
		t.Errorf("c = %q, want 3", result["c"])
	}
	// Original base must not be mutated
	if base["b"] != "2" {
		t.Error("mergeStringMaps mutated base map")
	}
}
