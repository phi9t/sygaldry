package plan

import (
	"reflect"
	"testing"

	"temporal-orchestration/internal/maputil"
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

	merged := MergeStep(base, override)

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
			got := maputil.MergeStringMaps(tt.base, tt.override)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("mergeStringMaps() = %#v, want %#v", got, tt.want)
			}
		})
	}
}

func TestMergeStepGitOp(t *testing.T) {
	t.Run("nil base gets override fields", func(t *testing.T) {
		result := mergeGitOpSpec(nil, &workflows.GitOpSpec{
			Op:            "commit",
			RepoDir:       "/repo",
			Branch:        "feature",
			BaseBranch:    "main",
			CommitMessage: "msg",
			PRTitle:       "title",
			PRBody:        "body",
			GitOpsScript:  "script.sh",
		})
		if result.Op != "commit" {
			t.Errorf("op = %q, want %q", result.Op, "commit")
		}
		if result.RepoDir != "/repo" {
			t.Errorf("repo_dir = %q, want %q", result.RepoDir, "/repo")
		}
		if result.Branch != "feature" {
			t.Errorf("branch = %q, want %q", result.Branch, "feature")
		}
		if result.BaseBranch != "main" {
			t.Errorf("base_branch = %q, want %q", result.BaseBranch, "main")
		}
		if result.CommitMessage != "msg" {
			t.Errorf("commit_message = %q, want %q", result.CommitMessage, "msg")
		}
		if result.PRTitle != "title" {
			t.Errorf("pr_title = %q, want %q", result.PRTitle, "title")
		}
		if result.PRBody != "body" {
			t.Errorf("pr_body = %q, want %q", result.PRBody, "body")
		}
		if result.GitOpsScript != "script.sh" {
			t.Errorf("git_ops_script = %q, want %q", result.GitOpsScript, "script.sh")
		}
	})

	t.Run("base fields preserved when override empty", func(t *testing.T) {
		base := &workflows.GitOpSpec{Op: "push", Branch: "dev"}
		result := mergeGitOpSpec(base, &workflows.GitOpSpec{})
		if result.Op != "push" {
			t.Errorf("op = %q, want %q", result.Op, "push")
		}
		if result.Branch != "dev" {
			t.Errorf("branch = %q, want %q", result.Branch, "dev")
		}
	})

	t.Run("override fields replace base", func(t *testing.T) {
		base := &workflows.GitOpSpec{Op: "push", Branch: "dev", CommitMessage: "old"}
		result := mergeGitOpSpec(base, &workflows.GitOpSpec{Op: "commit", CommitMessage: "new"})
		if result.Op != "commit" {
			t.Errorf("op = %q, want %q", result.Op, "commit")
		}
		if result.Branch != "dev" {
			t.Errorf("branch = %q, want %q", result.Branch, "dev")
		}
		if result.CommitMessage != "new" {
			t.Errorf("commit_message = %q, want %q", result.CommitMessage, "new")
		}
	})

	t.Run("override env merges with base env", func(t *testing.T) {
		base := &workflows.GitOpSpec{Op: "push", Env: map[string]string{"A": "1"}}
		result := mergeGitOpSpec(base, &workflows.GitOpSpec{Env: map[string]string{"B": "2"}})
		if result.Env["A"] != "1" {
			t.Errorf("env[A] = %q, want %q", result.Env["A"], "1")
		}
		if result.Env["B"] != "2" {
			t.Errorf("env[B] = %q, want %q", result.Env["B"], "2")
		}
	})
}

func TestMergeStepContainerJob(t *testing.T) {
	t.Run("nil base gets override fields", func(t *testing.T) {
		result := mergeContainerJobSpec(nil, &workflows.ContainerJobSpec{
			ProjectID:  "proj",
			Entrypoint: "run-job.sh",
			Command:    "python train.py",
			Env:        map[string]string{"A": "1"},
			GPU:        true,
		})
		if result.ProjectID != "proj" {
			t.Errorf("project_id = %q, want %q", result.ProjectID, "proj")
		}
		if result.Command != "python train.py" {
			t.Errorf("command = %q, want %q", result.Command, "python train.py")
		}
		if result.Env["A"] != "1" {
			t.Errorf("env[A] = %q, want %q", result.Env["A"], "1")
		}
		if !result.GPU {
			t.Error("gpu = false, want true")
		}
	})

	t.Run("override merges env and preserves base values", func(t *testing.T) {
		base := &workflows.ContainerJobSpec{
			ProjectID:  "base-proj",
			Entrypoint: "base-entrypoint",
			Command:    "python base.py",
			Env:        map[string]string{"A": "1"},
		}
		result := mergeContainerJobSpec(base, &workflows.ContainerJobSpec{
			Command: "python override.py",
			Env:     map[string]string{"B": "2"},
			GPU:     true,
		})
		if result.ProjectID != "base-proj" {
			t.Errorf("project_id = %q, want %q", result.ProjectID, "base-proj")
		}
		if result.Entrypoint != "base-entrypoint" {
			t.Errorf("entrypoint = %q, want %q", result.Entrypoint, "base-entrypoint")
		}
		if result.Command != "python override.py" {
			t.Errorf("command = %q, want %q", result.Command, "python override.py")
		}
		if result.Env["A"] != "1" || result.Env["B"] != "2" {
			t.Errorf("env = %v, want merged A/B values", result.Env)
		}
		if !result.GPU {
			t.Error("gpu = false, want true")
		}
	})
}

func TestMergeStepDockerPush(t *testing.T) {
	t.Run("nil base gets override image", func(t *testing.T) {
		result := mergeDockerPushSpec(nil, &workflows.DockerPushSpec{Image: "myrepo/img:latest"})
		if result.Image != "myrepo/img:latest" {
			t.Errorf("image = %q, want %q", result.Image, "myrepo/img:latest")
		}
	})

	t.Run("base image preserved when override empty", func(t *testing.T) {
		base := &workflows.DockerPushSpec{Image: "base/img:v1"}
		result := mergeDockerPushSpec(base, &workflows.DockerPushSpec{})
		if result.Image != "base/img:v1" {
			t.Errorf("image = %q, want %q", result.Image, "base/img:v1")
		}
	})

	t.Run("override image replaces base", func(t *testing.T) {
		base := &workflows.DockerPushSpec{Image: "base/img:v1"}
		result := mergeDockerPushSpec(base, &workflows.DockerPushSpec{Image: "override/img:v2"})
		if result.Image != "override/img:v2" {
			t.Errorf("image = %q, want %q", result.Image, "override/img:v2")
		}
	})
}

func TestMergeStepPackageBuild(t *testing.T) {
	t.Run("nil base gets override fields", func(t *testing.T) {
		result := mergePackageBuildSpec(nil, &workflows.PackageBuildSpec{
			Command:    "make",
			Args:       []string{"all"},
			WorkingDir: "/src",
		})
		if result.Command != "make" {
			t.Errorf("command = %q, want %q", result.Command, "make")
		}
		if len(result.Args) != 1 || result.Args[0] != "all" {
			t.Errorf("args = %v, want [all]", result.Args)
		}
		if result.WorkingDir != "/src" {
			t.Errorf("working_dir = %q, want %q", result.WorkingDir, "/src")
		}
	})

	t.Run("base fields preserved when override empty", func(t *testing.T) {
		base := &workflows.PackageBuildSpec{Command: "cmake", WorkingDir: "/build"}
		result := mergePackageBuildSpec(base, &workflows.PackageBuildSpec{})
		if result.Command != "cmake" {
			t.Errorf("command = %q, want %q", result.Command, "cmake")
		}
		if result.WorkingDir != "/build" {
			t.Errorf("working_dir = %q, want %q", result.WorkingDir, "/build")
		}
	})

	t.Run("override command replaces base", func(t *testing.T) {
		base := &workflows.PackageBuildSpec{Command: "make"}
		result := mergePackageBuildSpec(base, &workflows.PackageBuildSpec{Command: "ninja"})
		if result.Command != "ninja" {
			t.Errorf("command = %q, want %q", result.Command, "ninja")
		}
	})

	t.Run("override args replace base args", func(t *testing.T) {
		base := &workflows.PackageBuildSpec{Args: []string{"old"}}
		result := mergePackageBuildSpec(base, &workflows.PackageBuildSpec{Args: []string{"new1", "new2"}})
		if len(result.Args) != 2 || result.Args[0] != "new1" || result.Args[1] != "new2" {
			t.Errorf("args = %v, want [new1 new2]", result.Args)
		}
	})

	t.Run("override env merges with base env", func(t *testing.T) {
		base := &workflows.PackageBuildSpec{Env: map[string]string{"A": "1"}}
		result := mergePackageBuildSpec(base, &workflows.PackageBuildSpec{Env: map[string]string{"B": "2"}})
		if result.Env["A"] != "1" {
			t.Errorf("env[A] = %q, want %q", result.Env["A"], "1")
		}
		if result.Env["B"] != "2" {
			t.Errorf("env[B] = %q, want %q", result.Env["B"], "2")
		}
	})
}

func TestMergeStep(t *testing.T) {
	t.Run("override id wins", func(t *testing.T) {
		base := workflows.PipelineStep{ID: "base-id", Type: "command", Command: "echo base"}
		override := workflows.PipelineStep{ID: "override-id"}
		got := MergeStep(base, override)
		if got.ID != "override-id" {
			t.Errorf("id = %q, want override-id", got.ID)
		}
		if got.Command != "echo base" {
			t.Errorf("command should be preserved from base, got %q", got.Command)
		}
	})

	t.Run("base fields kept when override empty", func(t *testing.T) {
		base := workflows.PipelineStep{ID: "a", Type: "command", Command: "echo", WorkingDir: "/tmp"}
		got := MergeStep(base, workflows.PipelineStep{})
		if got.Command != "echo" || got.WorkingDir != "/tmp" {
			t.Errorf("base fields not preserved: %+v", got)
		}
	})
}
