package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"

	"temporal-orchestration/internal/workflows"
)

func TestMergePipelineStep(t *testing.T) {
	base := workflows.PipelineStep{
		ID:             "base",
		Name:           "Base",
		Type:           "command",
		DependsOn:      []string{"setup"},
		When:           &workflows.When{Step: "setup", Status: "success"},
		Command:        "echo base",
		Args:           []string{"base"},
		Env:            map[string]string{"BASE": "1", "KEEP": "yes"},
		WorkingDir:     "/base",
		TimeoutSeconds: 60,
		Retry: &workflows.RetrySpec{
			MaxAttempts:            2,
			InitialIntervalSeconds: 5,
		},
		Download: &workflows.DownloadSpec{
			URL:    "https://example.com/base",
			Output: "/tmp/base",
		},
		AgentTask: &workflows.AgentTaskSpec{
			Engine: "codex",
			Env:    map[string]string{"AGENT": "base"},
			Params: map[string]string{"mode": "baseline"},
		},
	}
	override := workflows.PipelineStep{
		ID:             "override",
		Name:           "Override",
		Type:           "agent_task",
		DependsOn:      []string{"build"},
		When:           &workflows.When{Step: "build", Status: "failure"},
		Command:        "echo override",
		Args:           []string{"override"},
		Env:            map[string]string{"BASE": "2", "NEW": "yes"},
		WorkingDir:     "/override",
		TimeoutSeconds: 120,
		AllowFailure:   true,
		Retry: &workflows.RetrySpec{
			MaxAttempts: 4,
		},
		Download: &workflows.DownloadSpec{
			Output: "/tmp/override",
			Sha256: "abc123",
		},
		AgentTask: &workflows.AgentTaskSpec{
			Model:      "gpt-5",
			Prompt:     "do the thing",
			WorkingDir: "/agent",
			Env:        map[string]string{"AGENT": "override"},
			Params:     map[string]string{"extra": "1"},
		},
	}

	merged := mergePipelineStep(base, override)

	if merged.ID != "override" || merged.Name != "Override" || merged.Type != "agent_task" {
		t.Fatalf("top-level overrides not applied: %+v", merged)
	}
	if !reflect.DeepEqual(merged.DependsOn, []string{"build"}) {
		t.Fatalf("depends_on override not applied: %#v", merged.DependsOn)
	}
	if merged.When == nil || merged.When.Step != "build" || merged.When.Status != "failure" {
		t.Fatalf("when override not applied: %+v", merged.When)
	}
	if merged.Command != "echo override" || merged.WorkingDir != "/override" || merged.TimeoutSeconds != 120 || !merged.AllowFailure {
		t.Fatalf("scalar overrides not applied: %+v", merged)
	}
	if got := merged.Env["BASE"]; got != "2" || merged.Env["KEEP"] != "yes" || merged.Env["NEW"] != "yes" {
		t.Fatalf("env merge incorrect: %#v", merged.Env)
	}
	if merged.Retry == nil || merged.Retry.MaxAttempts != 4 || merged.Retry.InitialIntervalSeconds != 5 {
		t.Fatalf("retry merge incorrect: %+v", merged.Retry)
	}
	if merged.Download == nil || merged.Download.URL != "https://example.com/base" || merged.Download.Output != "/tmp/override" || merged.Download.Sha256 != "abc123" {
		t.Fatalf("download merge incorrect: %+v", merged.Download)
	}
	if merged.AgentTask == nil || merged.AgentTask.Engine != "codex" || merged.AgentTask.Model != "gpt-5" || merged.AgentTask.Prompt != "do the thing" {
		t.Fatalf("agent task merge incorrect: %+v", merged.AgentTask)
	}
	if merged.AgentTask.Env["AGENT"] != "override" || merged.AgentTask.Params["mode"] != "baseline" || merged.AgentTask.Params["extra"] != "1" {
		t.Fatalf("agent task map merge incorrect: %+v", merged.AgentTask)
	}

	override.DependsOn[0] = "mutated"
	override.When.Step = "mutated"
	override.Args[0] = "mutated"
	if merged.DependsOn[0] != "build" || merged.When.Step != "build" || merged.Args[0] != "override" {
		t.Fatalf("merge should copy slice/pointer fields: %+v", merged)
	}
}

func TestMergeRetrySpec(t *testing.T) {
	tests := []struct {
		name     string
		base     *workflows.RetrySpec
		override *workflows.RetrySpec
		want     *workflows.RetrySpec
	}{
		{
			name:     "nil base starts empty",
			base:     nil,
			override: &workflows.RetrySpec{},
			want:     &workflows.RetrySpec{},
		},
		{
			name: "override replaces non-zero fields",
			base: &workflows.RetrySpec{
				MaxAttempts:            2,
				InitialIntervalSeconds: 5,
				BackoffCoefficient:     1.5,
				MaximumIntervalSeconds: 10,
			},
			override: &workflows.RetrySpec{
				MaxAttempts:        7,
				BackoffCoefficient: 2.0,
			},
			want: &workflows.RetrySpec{
				MaxAttempts:            7,
				InitialIntervalSeconds: 5,
				BackoffCoefficient:     2.0,
				MaximumIntervalSeconds: 10,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mergeRetrySpec(tt.base, tt.override)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("mergeRetrySpec() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestMergeRetrySpecBaseNilWithFullOverride(t *testing.T) {
	got := mergeRetrySpec(nil, &workflows.RetrySpec{
		MaxAttempts:            3,
		InitialIntervalSeconds: 7,
		BackoffCoefficient:     2.5,
		MaximumIntervalSeconds: 21,
	})
	want := &workflows.RetrySpec{
		MaxAttempts:            3,
		InitialIntervalSeconds: 7,
		BackoffCoefficient:     2.5,
		MaximumIntervalSeconds: 21,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeRetrySpec(nil, full override) = %+v, want %+v", got, want)
	}
}

func TestMergeDownloadSpec(t *testing.T) {
	got := mergeDownloadSpec(
		&workflows.DownloadSpec{URL: "https://example.com/base", Output: "/tmp/base", Sha256: "old"},
		&workflows.DownloadSpec{Output: "/tmp/override", Sha256: "new"},
	)
	want := &workflows.DownloadSpec{URL: "https://example.com/base", Output: "/tmp/override", Sha256: "new"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeDownloadSpec() = %+v, want %+v", got, want)
	}
}

func TestMergeDownloadSpecBaseNil(t *testing.T) {
	got := mergeDownloadSpec(nil, &workflows.DownloadSpec{
		URL:    "https://example.com/new",
		Output: "/tmp/new",
		Sha256: "sha",
	})
	want := &workflows.DownloadSpec{
		URL:    "https://example.com/new",
		Output: "/tmp/new",
		Sha256: "sha",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeDownloadSpec(nil, override) = %+v, want %+v", got, want)
	}
}

func TestMergeDockerBuildSpec(t *testing.T) {
	got := mergeDockerBuildSpec(
		&workflows.DockerBuildSpec{
			Image:      "base:latest",
			Context:    ".",
			Dockerfile: "Dockerfile",
			BuildArgs:  map[string]string{"BASE": "1", "KEEP": "yes"},
			Labels:     map[string]string{"tier": "base"},
			Platform:   "linux/amd64",
			Target:     "builder",
		},
		&workflows.DockerBuildSpec{
			Image:     "override:latest",
			BuildArgs: map[string]string{"BASE": "2"},
			Labels:    map[string]string{"role": "train"},
			Target:    "runtime",
		},
	)
	want := &workflows.DockerBuildSpec{
		Image:      "override:latest",
		Context:    ".",
		Dockerfile: "Dockerfile",
		BuildArgs:  map[string]string{"BASE": "2", "KEEP": "yes"},
		Labels:     map[string]string{"tier": "base", "role": "train"},
		Platform:   "linux/amd64",
		Target:     "runtime",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeDockerBuildSpec() = %+v, want %+v", got, want)
	}
}

func TestMergeDockerBuildSpecBaseNil(t *testing.T) {
	got := mergeDockerBuildSpec(nil, &workflows.DockerBuildSpec{
		Image:      "override:latest",
		Context:    "/workspace",
		Dockerfile: "Dockerfile.cuda",
		BuildArgs:  map[string]string{"CUDA": "1"},
		Labels:     map[string]string{"role": "train"},
		Platform:   "linux/arm64",
		Target:     "runtime",
	})
	want := &workflows.DockerBuildSpec{
		Image:      "override:latest",
		Context:    "/workspace",
		Dockerfile: "Dockerfile.cuda",
		BuildArgs:  map[string]string{"CUDA": "1"},
		Labels:     map[string]string{"role": "train"},
		Platform:   "linux/arm64",
		Target:     "runtime",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeDockerBuildSpec(nil, override) = %+v, want %+v", got, want)
	}
}

func TestMergeHFDownloadDatasetSpec(t *testing.T) {
	got := mergeHFDownloadDatasetSpec(
		&workflows.HFDownloadDatasetSpec{
			DatasetID: "org/base",
			Config:    "default",
			Split:     "train",
			CacheDir:  "/cache/base",
		},
		&workflows.HFDownloadDatasetSpec{
			Config:   "clean",
			CacheDir: "/cache/override",
		},
	)
	want := &workflows.HFDownloadDatasetSpec{
		DatasetID: "org/base",
		Config:    "clean",
		Split:     "train",
		CacheDir:  "/cache/override",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeHFDownloadDatasetSpec() = %+v, want %+v", got, want)
	}
}

func TestMergeHFDownloadDatasetSpecBaseNil(t *testing.T) {
	got := mergeHFDownloadDatasetSpec(nil, &workflows.HFDownloadDatasetSpec{
		DatasetID: "org/new",
		Config:    "cfg",
		Split:     "validation",
		CacheDir:  "/cache/new",
	})
	want := &workflows.HFDownloadDatasetSpec{
		DatasetID: "org/new",
		Config:    "cfg",
		Split:     "validation",
		CacheDir:  "/cache/new",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeHFDownloadDatasetSpec(nil, override) = %+v, want %+v", got, want)
	}
}

func TestMergeHFDownloadModelSpec(t *testing.T) {
	got := mergeHFDownloadModelSpec(
		&workflows.HFDownloadModelSpec{ModelID: "org/base", CacheDir: "/cache/base"},
		&workflows.HFDownloadModelSpec{CacheDir: "/cache/override"},
	)
	want := &workflows.HFDownloadModelSpec{ModelID: "org/base", CacheDir: "/cache/override"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeHFDownloadModelSpec() = %+v, want %+v", got, want)
	}
}

func TestMergeHFDownloadModelSpecBaseNil(t *testing.T) {
	got := mergeHFDownloadModelSpec(nil, &workflows.HFDownloadModelSpec{
		ModelID:  "org/new-model",
		CacheDir: "/cache/new",
	})
	want := &workflows.HFDownloadModelSpec{
		ModelID:  "org/new-model",
		CacheDir: "/cache/new",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeHFDownloadModelSpec(nil, override) = %+v, want %+v", got, want)
	}
}

func TestMergeK8sJobSpec(t *testing.T) {
	got := mergeK8sJobSpec(
		&workflows.K8sJobSpec{
			ProjectID:  "base-project",
			Entrypoint: "default",
			Command:    "python base.py",
			Env:        map[string]string{"BASE": "1", "KEEP": "yes"},
			GPUCount:   1,
			Image:      "base:image",
			Namespace:  "base-ns",
		},
		&workflows.K8sJobSpec{
			Command:   "python override.py",
			Env:       map[string]string{"BASE": "2"},
			GPU:       true,
			GPUCount:  4,
			Image:     "override:image",
			Namespace: "override-ns",
		},
	)
	want := &workflows.K8sJobSpec{
		ProjectID:  "base-project",
		Entrypoint: "default",
		Command:    "python override.py",
		Env:        map[string]string{"BASE": "2", "KEEP": "yes"},
		GPU:        true,
		GPUCount:   4,
		Image:      "override:image",
		Namespace:  "override-ns",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeK8sJobSpec() = %+v, want %+v", got, want)
	}
}

func TestMergeK8sJobSpecBaseNil(t *testing.T) {
	got := mergeK8sJobSpec(nil, &workflows.K8sJobSpec{
		ProjectID:  "project",
		Entrypoint: "run-job",
		Command:    "python train.py",
		Env:        map[string]string{"A": "1"},
		GPU:        true,
		GPUCount:   2,
		Image:      "trainer:image",
		Namespace:  "ml",
	})
	want := &workflows.K8sJobSpec{
		ProjectID:  "project",
		Entrypoint: "run-job",
		Command:    "python train.py",
		Env:        map[string]string{"A": "1"},
		GPU:        true,
		GPUCount:   2,
		Image:      "trainer:image",
		Namespace:  "ml",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeK8sJobSpec(nil, override) = %+v, want %+v", got, want)
	}
}

func TestMergeAgentTaskSpec(t *testing.T) {
	got := mergeAgentTaskSpec(
		&workflows.AgentTaskSpec{
			Engine:     "codex",
			Model:      "gpt-4",
			Prompt:     "base prompt",
			WorkingDir: "/base",
			Sandbox:    "workspace-write",
			Env:        map[string]string{"BASE": "1", "KEEP": "yes"},
			Params:     map[string]string{"mode": "baseline"},
		},
		&workflows.AgentTaskSpec{
			Model:      "gpt-5",
			PromptFile: "prompt.md",
			WorkingDir: "/override",
			Env:        map[string]string{"BASE": "2"},
			Params:     map[string]string{"extra": "1"},
		},
	)
	want := &workflows.AgentTaskSpec{
		Engine:     "codex",
		Model:      "gpt-5",
		Prompt:     "base prompt",
		PromptFile: "prompt.md",
		WorkingDir: "/override",
		Sandbox:    "workspace-write",
		Env:        map[string]string{"BASE": "2", "KEEP": "yes"},
		Params:     map[string]string{"mode": "baseline", "extra": "1"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeAgentTaskSpec() = %+v, want %+v", got, want)
	}
}

func TestMergeAgentTaskSpecBaseNil(t *testing.T) {
	got := mergeAgentTaskSpec(nil, &workflows.AgentTaskSpec{
		Engine:     "codex",
		Model:      "gpt-5",
		Prompt:     "hello",
		PromptFile: "prompt.md",
		WorkingDir: "/workspace",
		Sandbox:    "danger-full-access",
		Env:        map[string]string{"A": "1"},
		Params:     map[string]string{"mode": "fast"},
	})
	want := &workflows.AgentTaskSpec{
		Engine:     "codex",
		Model:      "gpt-5",
		Prompt:     "hello",
		PromptFile: "prompt.md",
		WorkingDir: "/workspace",
		Sandbox:    "danger-full-access",
		Env:        map[string]string{"A": "1"},
		Params:     map[string]string{"mode": "fast"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("mergeAgentTaskSpec(nil, override) = %+v, want %+v", got, want)
	}
}

func TestMergeStringMaps(t *testing.T) {
	tests := []struct {
		name     string
		base     map[string]string
		override map[string]string
		want     map[string]string
	}{
		{
			name:     "nil base and override",
			base:     nil,
			override: nil,
			want:     map[string]string{},
		},
		{
			name:     "nil override keeps base",
			base:     map[string]string{"a": "1"},
			override: nil,
			want:     map[string]string{"a": "1"},
		},
		{
			name:     "nil base copies override",
			base:     nil,
			override: map[string]string{"b": "2"},
			want:     map[string]string{"b": "2"},
		},
		{
			name:     "override wins",
			base:     map[string]string{"a": "1", "keep": "yes"},
			override: map[string]string{"a": "2"},
			want:     map[string]string{"a": "2", "keep": "yes"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mergeStringMaps(tt.base, tt.override)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("mergeStringMaps() = %#v, want %#v", got, tt.want)
			}
		})
	}
}

func TestStringMapFlagString(t *testing.T) {
	var nilFlag *stringMapFlag
	if got := nilFlag.String(); got != "" {
		t.Fatalf("nil stringMapFlag String() = %q, want empty string", got)
	}

	flagValue := stringMapFlag{
		"beta":  "2",
		"alpha": "1",
	}
	if got := flagValue.String(); got != "alpha=1,beta=2" {
		t.Fatalf("stringMapFlag String() = %q, want sorted output", got)
	}
}

func TestSafeFilename(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "empty", input: "", want: ""},
		{name: "spaces trimmed and replaced", input: "  workflow id  ", want: "workflow_id"},
		{name: "slashes colons tabs replaced", input: "a/b:c\tz", want: "a_b_c_z"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := safeFilename(tt.input); got != tt.want {
				t.Fatalf("safeFilename(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestWritePlanManifest(t *testing.T) {
	dir := t.TempDir()
	steps := []workflows.PipelineStep{
		{
			ID:        "build",
			Name:      "Build",
			Type:      "docker_build",
			DependsOn: []string{"setup"},
			When:      &workflows.When{Step: "setup", Status: "success"},
		},
	}

	if err := writePlanManifest(dir, "workflow/id", "run:1", steps); err != nil {
		t.Fatalf("writePlanManifest() error = %v", err)
	}

	manifestPath := filepath.Join(dir, "workflow_id_run_1_plan.json")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", manifestPath, err)
	}

	var manifest planManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("manifest JSON decode failed: %v", err)
	}

	if manifest.WorkflowID != "workflow/id" || manifest.RunID != "run:1" || manifest.LogDir != dir {
		t.Fatalf("manifest metadata incorrect: %+v", manifest)
	}
	if len(manifest.Steps) != 1 {
		t.Fatalf("manifest steps len = %d, want 1", len(manifest.Steps))
	}
	if manifest.Steps[0].ID != "build" || manifest.Steps[0].Name != "Build" || manifest.Steps[0].Type != "docker_build" {
		t.Fatalf("manifest step incorrect: %+v", manifest.Steps[0])
	}
	if !strings.Contains(manifest.CreatedAt, "T") {
		t.Fatalf("manifest CreatedAt should be RFC3339-like, got %q", manifest.CreatedAt)
	}
}

func TestWritePlanManifestDefaultsToLogsDir(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)

	if err := writePlanManifest("", "wf", "run", nil); err != nil {
		t.Fatalf("writePlanManifest() error = %v", err)
	}

	if _, err := os.Stat(filepath.Join(dir, "logs", "wf_run_plan.json")); err != nil {
		t.Fatalf("default log manifest not created: %v", err)
	}
}

func TestPrintOutput(t *testing.T) {
	payload := runOutput{
		WorkflowID: "wf-123",
		RunID:      "run-456",
		Async:      true,
	}

	jsonOut := captureStdout(t, func() {
		if err := printOutput("json", payload); err != nil {
			t.Fatalf("printOutput(json) error = %v", err)
		}
	})
	var jsonPayload runOutput
	if err := json.Unmarshal([]byte(jsonOut), &jsonPayload); err != nil {
		t.Fatalf("json output decode failed: %v", err)
	}
	if jsonPayload.WorkflowID != payload.WorkflowID || jsonPayload.RunID != payload.RunID || !jsonPayload.Async {
		t.Fatalf("json output incorrect: %+v", jsonPayload)
	}

	yamlOut := captureStdout(t, func() {
		if err := printOutput("yaml", payload); err != nil {
			t.Fatalf("printOutput(yaml) error = %v", err)
		}
	})
	var yamlPayload runOutput
	if err := yaml.Unmarshal([]byte(yamlOut), &yamlPayload); err != nil {
		t.Fatalf("yaml output decode failed: %v", err)
	}
	if yamlPayload.WorkflowID != payload.WorkflowID || yamlPayload.RunID != payload.RunID || !yamlPayload.Async {
		t.Fatalf("yaml output incorrect: %+v", yamlPayload)
	}

	if err := printOutput("bogus", payload); err == nil {
		t.Fatal("printOutput should reject unknown output modes")
	}
}

func TestRunCommandRequiresPlan(t *testing.T) {
	err := runCommand(nil)
	if err == nil || !strings.Contains(err.Error(), "-plan is required") {
		t.Fatalf("runCommand() error = %v, want missing plan error", err)
	}
}

func TestRunCommandRejectsInvalidPlan(t *testing.T) {
	path := filepath.Join(t.TempDir(), "invalid.yaml")
	if err := os.WriteFile(path, []byte("steps:\n  - id: only\n    bogus: true\n"), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	err := runCommand([]string{"-plan", path})
	if err == nil || !strings.Contains(err.Error(), "unable to parse plan") {
		t.Fatalf("runCommand() error = %v, want parse error", err)
	}
}

func TestStatusCommandRequiresWorkflowID(t *testing.T) {
	err := statusCommand(nil)
	if err == nil || !strings.Contains(err.Error(), "-workflow-id is required") {
		t.Fatalf("statusCommand() error = %v, want missing workflow id", err)
	}
}

func TestLoadPipelinePlanImportsAndDefaults(t *testing.T) {
	dir := t.TempDir()
	importPath := filepath.Join(dir, "templates.yaml")
	planPath := filepath.Join(dir, "plan.yaml")

	if err := os.WriteFile(importPath, []byte(`
templates:
  base:
    type: command
    command: bash
    args:
      - -lc
      - echo template
    env:
      FROM_TEMPLATE: "1"
`), 0o644); err != nil {
		t.Fatalf("WriteFile(import) error = %v", err)
	}

	if err := os.WriteFile(planPath, []byte(`
imports:
  - templates.yaml
steps:
  - id: build
    template: base
    args:
      - -lc
      - echo override
`), 0o644); err != nil {
		t.Fatalf("WriteFile(plan) error = %v", err)
	}

	input, err := loadPipelinePlan(planPath)
	if err != nil {
		t.Fatalf("loadPipelinePlan() error = %v", err)
	}

	if len(input.Steps) != 1 {
		t.Fatalf("len(input.Steps) = %d, want 1", len(input.Steps))
	}
	if input.Steps[0].Template != "" || input.Steps[0].Command != "bash" {
		t.Fatalf("template resolution failed: %+v", input.Steps[0])
	}
	if got := strings.Join(input.Steps[0].Args, " "); got != "-lc echo override" {
		t.Fatalf("step override not applied, got args %q", got)
	}
	if input.Params == nil || input.Env == nil {
		t.Fatalf("loadPipelinePlan() should default params/env maps: %+v", input)
	}
	if _, ok := input.Templates["base"]; !ok {
		t.Fatalf("imported templates missing from input: %+v", input.Templates)
	}
}

func TestLoadPipelinePlanDuplicateImportedTemplate(t *testing.T) {
	dir := t.TempDir()
	firstImport := filepath.Join(dir, "templates-a.yaml")
	secondImport := filepath.Join(dir, "templates-b.yaml")
	planPath := filepath.Join(dir, "plan.yaml")

	for _, path := range []string{firstImport, secondImport} {
		if err := os.WriteFile(path, []byte(`
templates:
  shared:
    type: command
    command: echo
`), 0o644); err != nil {
			t.Fatalf("WriteFile(%s) error = %v", path, err)
		}
	}

	if err := os.WriteFile(planPath, []byte(`
imports:
  - templates-a.yaml
  - templates-b.yaml
steps:
  - id: build
    type: command
    command: echo
`), 0o644); err != nil {
		t.Fatalf("WriteFile(plan) error = %v", err)
	}

	_, err := loadPipelinePlan(planPath)
	if err == nil || !strings.Contains(err.Error(), "duplicate template name") {
		t.Fatalf("loadPipelinePlan() error = %v, want duplicate template error", err)
	}
}

func TestLoadTemplateImportRequiresTemplates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty-import.yaml")
	if err := os.WriteFile(path, []byte("templates: {}\n"), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	_, err := loadTemplateImport(path)
	if err == nil || !strings.Contains(err.Error(), "has no templates") {
		t.Fatalf("loadTemplateImport() error = %v, want no templates error", err)
	}
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	original := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe() error = %v", err)
	}
	defer reader.Close()

	os.Stdout = writer
	defer func() {
		os.Stdout = original
	}()

	fn()

	if err := writer.Close(); err != nil {
		t.Fatalf("writer.Close() error = %v", err)
	}

	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("io.ReadAll() error = %v", err)
	}
	return string(data)
}
