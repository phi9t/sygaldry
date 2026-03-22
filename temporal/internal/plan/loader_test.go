package plan

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"temporal-orchestration/internal/workflows"
)

func TestDecodeYAMLStrictUnknownField(t *testing.T) {
	var input workflows.PipelineInput
	err := decodeYAMLStrict([]byte(`
steps:
  - id: s1
    type: command
    command: echo
    bogus: true
`), &input)
	if err == nil {
		t.Fatal("expected strict decode to fail on unknown field")
	}
}

func TestResolveStepTemplates(t *testing.T) {
	steps := []workflows.PipelineStep{
		{
			ID:       "build",
			Template: "base",
			Args:     []string{"-lc", "echo override"},
		},
	}
	templates := map[string]workflows.PipelineStep{
		"base": {
			Type:    "command",
			Command: "bash",
			Args:    []string{"-lc", "echo template"},
			Env:     map[string]string{"A": "1"},
		},
	}

	resolved, err := resolveStepTemplates(steps, templates)
	if err != nil {
		t.Fatalf("resolveStepTemplates failed: %v", err)
	}
	if len(resolved) != 1 {
		t.Fatalf("unexpected resolved len %d", len(resolved))
	}
	if resolved[0].Type != "command" || resolved[0].Command != "bash" {
		t.Fatalf("template defaults not applied: %+v", resolved[0])
	}
	if got := strings.Join(resolved[0].Args, " "); got != "-lc echo override" {
		t.Fatalf("step override for args not applied: %q", got)
	}
}

func TestLoadTemplateImport(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tmpl.yaml")
	if err := os.WriteFile(path, []byte(`
templates:
  t:
    type: command
    command: echo
`), 0o644); err != nil {
		t.Fatal(err)
	}
	templates, err := loadTemplateImport(path)
	if err != nil {
		t.Fatalf("loadTemplateImport failed: %v", err)
	}
	if _, ok := templates["t"]; !ok {
		t.Fatalf("template t not loaded: %+v", templates)
	}
}

func TestLoadImportsAndDefaults(t *testing.T) {
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

	input, err := Load(planPath)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
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
		t.Fatalf("Load() should default params/env maps: %+v", input)
	}
	if _, ok := input.Templates["base"]; !ok {
		t.Fatalf("imported templates missing from input: %+v", input.Templates)
	}
}

func TestLoadDuplicateImportedTemplate(t *testing.T) {
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

	_, err := Load(planPath)
	if err == nil || !strings.Contains(err.Error(), "duplicate template name") {
		t.Fatalf("Load() error = %v, want duplicate template error", err)
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

func TestLoad(t *testing.T) {
	t.Run("valid plan", func(t *testing.T) {
		dir := t.TempDir()
		planPath := filepath.Join(dir, "plan.yaml")
		if err := os.WriteFile(planPath, []byte("steps:\n  - id: s1\n    type: command\n    command: echo\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		input, err := Load(planPath)
		if err != nil {
			t.Fatalf("Load failed: %v", err)
		}
		if len(input.Steps) != 1 || input.Steps[0].ID != "s1" {
			t.Errorf("unexpected steps: %+v", input.Steps)
		}
	})

	t.Run("file not found", func(t *testing.T) {
		_, err := Load("/nonexistent/path/plan.yaml")
		if err == nil || !strings.Contains(err.Error(), "unable to read plan file") {
			t.Fatalf("expected 'unable to read plan file', got: %v", err)
		}
	})

	t.Run("unknown yaml field rejected", func(t *testing.T) {
		dir := t.TempDir()
		planPath := filepath.Join(dir, "plan.yaml")
		if err := os.WriteFile(planPath, []byte("steps:\n  - id: s1\n    type: command\n    command: echo\n    bogus: true\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		_, err := Load(planPath)
		if err == nil || !strings.Contains(err.Error(), "unable to parse plan") {
			t.Fatalf("expected parse error, got: %v", err)
		}
	})

	t.Run("params and env initialized when absent", func(t *testing.T) {
		dir := t.TempDir()
		planPath := filepath.Join(dir, "plan.yaml")
		if err := os.WriteFile(planPath, []byte("steps:\n  - id: s1\n    type: command\n    command: echo\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		input, err := Load(planPath)
		if err != nil {
			t.Fatal(err)
		}
		if input.Params == nil {
			t.Error("Params should be initialized to empty map")
		}
		if input.Env == nil {
			t.Error("Env should be initialized to empty map")
		}
	})
}
