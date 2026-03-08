package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"temporal-orchestration/internal/workflows"
)

func TestValidatePlanEmpty(t *testing.T) {
	input := &workflows.PipelineInput{Steps: nil}
	if err := validatePlan(input); err == nil {
		t.Error("expected error for empty plan")
	}
}

func TestValidatePlanMissingID(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{{Type: "command", Command: "echo"}},
	}
	if err := validatePlan(input); err == nil || !strings.Contains(err.Error(), "missing id") {
		t.Errorf("expected missing id error, got: %v", err)
	}
}

func TestValidatePlanDuplicateID(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{
			{ID: "a", Type: "command", Command: "echo"},
			{ID: "a", Type: "command", Command: "echo"},
		},
	}
	if err := validatePlan(input); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Errorf("expected duplicate id error, got: %v", err)
	}
}

func TestValidatePlanMissingType(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{{ID: "a", Command: "echo"}},
	}
	if err := validatePlan(input); err == nil || !strings.Contains(err.Error(), "missing type") {
		t.Errorf("expected missing type error, got: %v", err)
	}
}

func TestValidatePlanUnsupportedType(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{{ID: "a", Type: "bogus"}},
	}
	if err := validatePlan(input); err == nil || !strings.Contains(err.Error(), "unsupported type") {
		t.Errorf("expected unsupported type error, got: %v", err)
	}
}

func TestValidatePlanAllTypes(t *testing.T) {
	for typ := range allowedTypes {
		t.Run(typ, func(t *testing.T) {
			step := workflows.PipelineStep{ID: typ + "-step", Type: typ}
			// Provide required fields per type
			switch typ {
			case "command":
				step.Command = "echo"
			case "download":
				step.Download = &workflows.DownloadSpec{URL: "http://x", Output: "/tmp/x"}
			case "docker_build":
				step.DockerBuild = &workflows.DockerBuildSpec{Image: "img:latest"}
			case "docker_push":
				step.DockerPush = &workflows.DockerPushSpec{Image: "img:latest"}
			case "package_build":
				step.PackageBuild = &workflows.PackageBuildSpec{Command: "make"}
			case "container_job":
				step.ContainerJob = &workflows.ContainerJobSpec{Command: "python x.py"}
			case "hf_download_dataset":
				step.HFDownloadDataset = &workflows.HFDownloadDatasetSpec{DatasetID: "ns/ds"}
			case "hf_download_model":
				step.HFDownloadModel = &workflows.HFDownloadModelSpec{ModelID: "ns/model"}
			case "k8s_job":
				step.K8sJob = &workflows.K8sJobSpec{Command: "nvidia-smi"}
			case "agent_task":
				step.AgentTask = &workflows.AgentTaskSpec{Engine: "claude", Prompt: "hello"}
			case "git_op":
				step.GitOp = &workflows.GitOpSpec{Op: "branch"}
			}
			input := &workflows.PipelineInput{Steps: []workflows.PipelineStep{step}}
			if err := validatePlan(input); err != nil {
				t.Errorf("valid %s step failed: %v", typ, err)
			}
		})
	}
}

func TestValidatePlanMissingRequiredFields(t *testing.T) {
	tests := []struct {
		name string
		step workflows.PipelineStep
		want string
	}{
		{"command empty", workflows.PipelineStep{ID: "a", Type: "command"}, "command is required"},
		{"download nil", workflows.PipelineStep{ID: "a", Type: "download"}, "download requires url"},
		{"download missing url", workflows.PipelineStep{ID: "a", Type: "download", Download: &workflows.DownloadSpec{Output: "/tmp/x"}}, "download requires url"},
		{"download missing output", workflows.PipelineStep{ID: "a", Type: "download", Download: &workflows.DownloadSpec{URL: "http://x"}}, "download requires url"},
		{"docker_build nil", workflows.PipelineStep{ID: "a", Type: "docker_build"}, "docker_build requires image"},
		{"docker_push nil", workflows.PipelineStep{ID: "a", Type: "docker_push"}, "docker_push requires image"},
		{"package_build nil", workflows.PipelineStep{ID: "a", Type: "package_build"}, "package_build requires command"},
		{"container_job nil", workflows.PipelineStep{ID: "a", Type: "container_job"}, "container_job requires command"},
		{"hf_download_dataset nil", workflows.PipelineStep{ID: "a", Type: "hf_download_dataset"}, "hf_download_dataset requires dataset_id"},
		{"hf_download_model nil", workflows.PipelineStep{ID: "a", Type: "hf_download_model"}, "hf_download_model requires model_id"},
		{"k8s_job nil", workflows.PipelineStep{ID: "a", Type: "k8s_job"}, "k8s_job requires command"},
		{"agent_task nil", workflows.PipelineStep{ID: "a", Type: "agent_task"}, "agent_task requires agent_task config"},
		{"agent_task no engine", workflows.PipelineStep{ID: "a", Type: "agent_task", AgentTask: &workflows.AgentTaskSpec{Prompt: "hi"}}, "agent_task requires engine"},
		{"agent_task no prompt", workflows.PipelineStep{ID: "a", Type: "agent_task", AgentTask: &workflows.AgentTaskSpec{Engine: "claude"}}, "agent_task requires prompt or prompt_file"},
		{"git_op nil", workflows.PipelineStep{ID: "a", Type: "git_op"}, "git_op requires op"},
		{"git_op no op", workflows.PipelineStep{ID: "a", Type: "git_op", GitOp: &workflows.GitOpSpec{}}, "git_op requires op"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			input := &workflows.PipelineInput{Steps: []workflows.PipelineStep{tt.step}}
			err := validatePlan(input)
			if err == nil {
				t.Fatalf("expected error containing %q", tt.want)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %q, want containing %q", err.Error(), tt.want)
			}
		})
	}
}

func TestValidatePlanDependencies(t *testing.T) {
	t.Run("valid dependency", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo"},
				{ID: "b", Type: "command", Command: "echo", DependsOn: []string{"a"}},
			},
		}
		if err := validatePlan(input); err != nil {
			t.Errorf("unexpected error: %v", err)
		}
	})

	t.Run("unknown dependency", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo", DependsOn: []string{"nonexistent"}},
			},
		}
		if err := validatePlan(input); err == nil || !strings.Contains(err.Error(), "unknown step") {
			t.Errorf("expected unknown step error, got: %v", err)
		}
	})
}

func TestValidatePlanWhenClause(t *testing.T) {
	t.Run("valid when", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo"},
				{ID: "b", Type: "command", Command: "echo", When: &workflows.When{Step: "a", Status: "success"}},
			},
		}
		if err := validatePlan(input); err != nil {
			t.Errorf("unexpected error: %v", err)
		}
	})

	t.Run("when with failure status", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo"},
				{ID: "b", Type: "command", Command: "echo", When: &workflows.When{Step: "a", Status: "failure"}},
			},
		}
		if err := validatePlan(input); err != nil {
			t.Errorf("unexpected error: %v", err)
		}
	})

	t.Run("when invalid status", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo"},
				{ID: "b", Type: "command", Command: "echo", When: &workflows.When{Step: "a", Status: "pending"}},
			},
		}
		if err := validatePlan(input); err == nil || !strings.Contains(err.Error(), "invalid when") {
			t.Errorf("expected invalid when error, got: %v", err)
		}
	})

	t.Run("when unknown step", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo", When: &workflows.When{Step: "ghost", Status: "success"}},
			},
		}
		if err := validatePlan(input); err == nil || !strings.Contains(err.Error(), "unknown step") {
			t.Errorf("expected unknown step error, got: %v", err)
		}
	})

	t.Run("when missing step field", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo", When: &workflows.When{Status: "success"}},
			},
		}
		if err := validatePlan(input); err == nil || !strings.Contains(err.Error(), "invalid when") {
			t.Errorf("expected invalid when error, got: %v", err)
		}
	})
}

func TestValidatePlanNameDefaulting(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{
			{ID: "my-step", Type: "command", Command: "echo"},
		},
	}
	if err := validatePlan(input); err != nil {
		t.Fatal(err)
	}
	if input.Steps[0].Name != "my-step" {
		t.Errorf("name not defaulted to id: got %q", input.Steps[0].Name)
	}
}

func TestEnvOr(t *testing.T) {
	t.Setenv("TEST_ENV_OR_KEY", "from_env")
	if got := envOr("TEST_ENV_OR_KEY", "fallback"); got != "from_env" {
		t.Errorf("envOr with set var = %q, want 'from_env'", got)
	}
	if got := envOr("TEST_ENV_OR_MISSING_KEY_XYZ", "fallback"); got != "fallback" {
		t.Errorf("envOr with missing var = %q, want 'fallback'", got)
	}
}

func TestValidatePlanDependencyCycle(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{
			{ID: "a", Type: "command", Command: "echo", DependsOn: []string{"c"}},
			{ID: "b", Type: "command", Command: "echo", DependsOn: []string{"a"}},
			{ID: "c", Type: "command", Command: "echo", DependsOn: []string{"b"}},
		},
	}
	err := validatePlan(input)
	if err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("expected cycle error, got: %v", err)
	}
}

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
