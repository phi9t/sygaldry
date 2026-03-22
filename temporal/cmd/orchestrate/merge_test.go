package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"

	"temporal-orchestration/internal/plan"
	"temporal-orchestration/internal/workflows"
)

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

	input, err := plan.Load(planPath)
	if err != nil {
		t.Fatalf("plan.Load() error = %v", err)
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
		t.Fatalf("plan.Load() should default params/env maps: %+v", input)
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

	_, err := plan.Load(planPath)
	if err == nil || !strings.Contains(err.Error(), "duplicate template name") {
		t.Fatalf("plan.Load() error = %v, want duplicate template error", err)
	}
}

func TestLoadTemplateImportRequiresTemplates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty-import.yaml")
	if err := os.WriteFile(path, []byte("templates: {}\n"), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	// Import a plan that references this empty template file
	dir := t.TempDir()
	planPath := filepath.Join(dir, "plan.yaml")
	if err := os.WriteFile(planPath, []byte(`
imports:
  - `+path+`
steps:
  - id: s1
    type: command
    command: echo
`), 0o644); err != nil {
		t.Fatalf("WriteFile(plan) error = %v", err)
	}

	_, err := plan.Load(planPath)
	if err == nil || !strings.Contains(err.Error(), "has no templates") {
		t.Fatalf("plan.Load() error = %v, want no templates error", err)
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
