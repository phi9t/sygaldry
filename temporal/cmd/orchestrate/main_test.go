package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"temporal-orchestration/internal/config"
)

func TestEnvOr(t *testing.T) {
	t.Setenv("TEST_ENV_OR_KEY", "from_env")
	if got := config.EnvOr("TEST_ENV_OR_KEY", "fallback"); got != "from_env" {
		t.Errorf("config.EnvOr with set var = %q, want 'from_env'", got)
	}
	if got := config.EnvOr("TEST_ENV_OR_MISSING_KEY_XYZ", "fallback"); got != "fallback" {
		t.Errorf("config.EnvOr with missing var = %q, want 'fallback'", got)
	}
}

func TestParseSubcommand(t *testing.T) {
	sub, args := parseSubcommand([]string{"validate", "-plan", "x"})
	if sub != "validate" {
		t.Fatalf("subcommand = %q, want validate", sub)
	}
	if len(args) != 2 {
		t.Fatalf("args len = %d, want 2", len(args))
	}

	sub, args = parseSubcommand([]string{"-plan", "x"})
	if sub != "run" {
		t.Fatalf("default subcommand = %q, want run", sub)
	}
	if len(args) != 2 {
		t.Fatalf("args len = %d, want 2", len(args))
	}
}

func TestStringMapFlag(t *testing.T) {
	var values stringMapFlag
	if err := values.Set("a=1"); err != nil {
		t.Fatalf("set failed: %v", err)
	}
	if err := values.Set("b=2"); err != nil {
		t.Fatalf("set failed: %v", err)
	}
	if values["a"] != "1" || values["b"] != "2" {
		t.Fatalf("unexpected values: %+v", values)
	}
	if err := values.Set("broken"); err == nil {
		t.Fatal("expected parse failure")
	}
}

func TestRunCommandMissingPlan(t *testing.T) {
	err := runCommand([]string{})
	if err == nil || err.Error() != "-plan is required" {
		t.Fatalf("expected '-plan is required', got: %v", err)
	}
}

func TestRunCommandPlanFileNotFound(t *testing.T) {
	err := runCommand([]string{"-plan", "/nonexistent/path/plan.yaml"})
	if err == nil || !strings.Contains(err.Error(), "unable to read plan file") {
		t.Fatalf("expected 'unable to read plan file', got: %v", err)
	}
}

func TestRunCommandInvalidPlan(t *testing.T) {
	dir := t.TempDir()
	planPath := filepath.Join(dir, "bad.yaml")
	if err := os.WriteFile(planPath, []byte("steps: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := runCommand([]string{"-plan", planPath})
	if err == nil || !strings.Contains(err.Error(), "plan validation failed") {
		t.Fatalf("expected 'plan validation failed', got: %v", err)
	}
}

func TestValidateCommandMissingPlan(t *testing.T) {
	err := validateCommand([]string{})
	if err == nil || err.Error() != "-plan is required" {
		t.Fatalf("expected '-plan is required', got: %v", err)
	}
}

func TestValidateCommandPlanFileNotFound(t *testing.T) {
	err := validateCommand([]string{"-plan", "/nonexistent/path/plan.yaml"})
	if err == nil || !strings.Contains(err.Error(), "unable to read plan file") {
		t.Fatalf("expected 'unable to read plan file', got: %v", err)
	}
}

func TestValidateCommandInvalidPlan(t *testing.T) {
	dir := t.TempDir()
	planPath := filepath.Join(dir, "bad.yaml")
	if err := os.WriteFile(planPath, []byte("steps: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := validateCommand([]string{"-plan", planPath})
	if err == nil || !strings.Contains(err.Error(), "plan validation failed") {
		t.Fatalf("expected 'plan validation failed', got: %v", err)
	}
}

func TestValidateCommandValidPlan(t *testing.T) {
	dir := t.TempDir()
	planPath := filepath.Join(dir, "good.yaml")
	yaml := `steps:
  - id: step1
    type: command
    command: echo hello
`
	if err := os.WriteFile(planPath, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
	err := validateCommand([]string{"-plan", planPath})
	if err != nil {
		t.Fatalf("expected no error for valid plan, got: %v", err)
	}
}

func TestRunDispatchToValidate(t *testing.T) {
	dir := t.TempDir()
	planPath := filepath.Join(dir, "plan.yaml")
	if err := os.WriteFile(planPath, []byte("steps:\n  - id: s1\n    type: command\n    command: echo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"validate", "-plan", planPath}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunDispatchToRunMissingPlan(t *testing.T) {
	err := run([]string{"run"})
	if err == nil || err.Error() != "-plan is required" {
		t.Fatalf("expected '-plan is required', got: %v", err)
	}
}

func TestRunDispatchDefaultSubcommand(t *testing.T) {
	err := run([]string{})
	if err == nil || err.Error() != "-plan is required" {
		t.Fatalf("expected '-plan is required', got: %v", err)
	}
}

func TestRunDispatchStatusMissingWorkflowID(t *testing.T) {
	err := run([]string{"status"})
	if err == nil || err.Error() != "-workflow-id is required" {
		t.Fatalf("expected '-workflow-id is required', got: %v", err)
	}
}
