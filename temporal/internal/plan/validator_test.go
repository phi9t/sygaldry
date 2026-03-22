package plan

import (
	"strings"
	"testing"

	"temporal-orchestration/internal/workflows"
)

func TestValidateEmpty(t *testing.T) {
	input := &workflows.PipelineInput{Steps: nil}
	if err := Validate(input); err == nil {
		t.Error("expected error for empty plan")
	}
}

func TestValidateMissingID(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{{Type: "command", Command: "echo"}},
	}
	if err := Validate(input); err == nil || !strings.Contains(err.Error(), "missing id") {
		t.Errorf("expected missing id error, got: %v", err)
	}
}

func TestValidateDuplicateID(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{
			{ID: "a", Type: "command", Command: "echo"},
			{ID: "a", Type: "command", Command: "echo"},
		},
	}
	if err := Validate(input); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Errorf("expected duplicate id error, got: %v", err)
	}
}

func TestValidateMissingType(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{{ID: "a", Command: "echo"}},
	}
	if err := Validate(input); err == nil || !strings.Contains(err.Error(), "missing type") {
		t.Errorf("expected missing type error, got: %v", err)
	}
}

func TestValidateUnsupportedType(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{{ID: "a", Type: "bogus"}},
	}
	if err := Validate(input); err == nil || !strings.Contains(err.Error(), "unsupported type") {
		t.Errorf("expected unsupported type error, got: %v", err)
	}
}

func TestValidateAllTypes(t *testing.T) {
	for typ := range allowedTypes {
		t.Run(typ, func(t *testing.T) {
			step := workflows.PipelineStep{ID: typ + "-step", Type: typ}
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
			if err := Validate(input); err != nil {
				t.Errorf("valid %s step failed: %v", typ, err)
			}
		})
	}
}

func TestValidateMissingRequiredFields(t *testing.T) {
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
			err := Validate(input)
			if err == nil {
				t.Fatalf("expected error containing %q", tt.want)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %q, want containing %q", err.Error(), tt.want)
			}
		})
	}
}

func TestValidateDependencies(t *testing.T) {
	t.Run("valid dependency", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo"},
				{ID: "b", Type: "command", Command: "echo", DependsOn: []string{"a"}},
			},
		}
		if err := Validate(input); err != nil {
			t.Errorf("unexpected error: %v", err)
		}
	})

	t.Run("unknown dependency", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo", DependsOn: []string{"nonexistent"}},
			},
		}
		if err := Validate(input); err == nil || !strings.Contains(err.Error(), "unknown step") {
			t.Errorf("expected unknown step error, got: %v", err)
		}
	})
}

func TestValidateWhenClause(t *testing.T) {
	t.Run("valid when", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo"},
				{ID: "b", Type: "command", Command: "echo", When: &workflows.When{Step: "a", Status: "success"}},
			},
		}
		if err := Validate(input); err != nil {
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
		if err := Validate(input); err != nil {
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
		if err := Validate(input); err == nil || !strings.Contains(err.Error(), "invalid when") {
			t.Errorf("expected invalid when error, got: %v", err)
		}
	})

	t.Run("when unknown step", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo", When: &workflows.When{Step: "ghost", Status: "success"}},
			},
		}
		if err := Validate(input); err == nil || !strings.Contains(err.Error(), "unknown step") {
			t.Errorf("expected unknown step error, got: %v", err)
		}
	})

	t.Run("when missing step field", func(t *testing.T) {
		input := &workflows.PipelineInput{
			Steps: []workflows.PipelineStep{
				{ID: "a", Type: "command", Command: "echo", When: &workflows.When{Status: "success"}},
			},
		}
		if err := Validate(input); err == nil || !strings.Contains(err.Error(), "invalid when") {
			t.Errorf("expected invalid when error, got: %v", err)
		}
	})
}

func TestValidateNameDefaulting(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{
			{ID: "my-step", Type: "command", Command: "echo"},
		},
	}
	if err := Validate(input); err != nil {
		t.Fatal(err)
	}
	if input.Steps[0].Name != "my-step" {
		t.Errorf("name not defaulted to id: got %q", input.Steps[0].Name)
	}
}

func TestValidateDependencyCycle(t *testing.T) {
	input := &workflows.PipelineInput{
		Steps: []workflows.PipelineStep{
			{ID: "a", Type: "command", Command: "echo", DependsOn: []string{"c"}},
			{ID: "b", Type: "command", Command: "echo", DependsOn: []string{"a"}},
			{ID: "c", Type: "command", Command: "echo", DependsOn: []string{"b"}},
		},
	}
	err := Validate(input)
	if err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("expected cycle error, got: %v", err)
	}
}

func TestAllowedTypes(t *testing.T) {
	types := AllowedTypes()
	if len(types) == 0 {
		t.Fatal("AllowedTypes returned empty map")
	}
	// Known required types
	for _, required := range []string{"command", "container_job", "hf_download_model"} {
		if !types[required] {
			t.Errorf("AllowedTypes missing expected type %q", required)
		}
	}
	// Returned map must be a copy — mutations must not affect subsequent calls
	types["injected_fake_type"] = true
	fresh := AllowedTypes()
	if fresh["injected_fake_type"] {
		t.Error("AllowedTypes returned the internal map instead of a copy")
	}
}
