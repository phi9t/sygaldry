package main

import (
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
