package workflows

import (
	"testing"
)

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
	}
	if !r.Succeeded || r.ExitCode != 0 || r.DurationSec != 42 {
		t.Error("PipelineStepResult fields not correctly set")
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
