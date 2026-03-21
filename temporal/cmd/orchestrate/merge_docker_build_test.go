package main

import (
	"reflect"
	"testing"

	"temporal-orchestration/internal/workflows"
)

func TestMergeDockerBuildSpec(t *testing.T) {
	tests := []struct {
		name     string
		base     *workflows.DockerBuildSpec
		override *workflows.DockerBuildSpec
		want     *workflows.DockerBuildSpec
	}{
		{
			name: "nil base gets all override fields",
			base: nil,
			override: &workflows.DockerBuildSpec{
				Image:      "override-image",
				Context:    "override-context",
				Dockerfile: "override-dockerfile",
				BuildArgs:  map[string]string{"arg": "val"},
				Labels:     map[string]string{"label": "val"},
				Platform:   "linux/amd64",
				Target:     "builder",
			},
			want: &workflows.DockerBuildSpec{
				Image:      "override-image",
				Context:    "override-context",
				Dockerfile: "override-dockerfile",
				BuildArgs:  map[string]string{"arg": "val"},
				Labels:     map[string]string{"label": "val"},
				Platform:   "linux/amd64",
				Target:     "builder",
			},
		},
		{
			name: "base fields preserved when override empty",
			base: &workflows.DockerBuildSpec{
				Image:      "base-image",
				Context:    "base-context",
				Dockerfile: "base-dockerfile",
				BuildArgs:  map[string]string{"base-arg": "base-val"},
				Labels:     map[string]string{"base-label": "base-val"},
				Platform:   "linux/arm64",
				Target:     "final",
			},
			override: &workflows.DockerBuildSpec{},
			want: &workflows.DockerBuildSpec{
				Image:      "base-image",
				Context:    "base-context",
				Dockerfile: "base-dockerfile",
				BuildArgs:  map[string]string{"base-arg": "base-val"},
				Labels:     map[string]string{"base-label": "base-val"},
				Platform:   "linux/arm64",
				Target:     "final",
			},
		},
		{
			name: "override Image/Context/Dockerfile/Platform/Target replaces base",
			base: &workflows.DockerBuildSpec{
				Image:      "base-image",
				Context:    "base-context",
				Dockerfile: "base-dockerfile",
				Platform:   "linux/arm64",
				Target:     "base-target",
			},
			override: &workflows.DockerBuildSpec{
				Image:      "override-image",
				Context:    "override-context",
				Dockerfile: "override-dockerfile",
				Platform:   "linux/amd64",
				Target:     "override-target",
			},
			want: &workflows.DockerBuildSpec{
				Image:      "override-image",
				Context:    "override-context",
				Dockerfile: "override-dockerfile",
				Platform:   "linux/amd64",
				Target:     "override-target",
			},
		},
		{
			name: "override BuildArgs merges with base BuildArgs (override wins on conflict)",
			base: &workflows.DockerBuildSpec{
				BuildArgs: map[string]string{
					"keep":    "base",
					"replace": "base",
				},
			},
			override: &workflows.DockerBuildSpec{
				BuildArgs: map[string]string{
					"replace": "override",
					"new":     "override",
				},
			},
			want: &workflows.DockerBuildSpec{
				BuildArgs: map[string]string{
					"keep":    "base",
					"replace": "override",
					"new":     "override",
				},
			},
		},
		{
			name: "override Labels merges with base Labels",
			base: &workflows.DockerBuildSpec{
				Labels: map[string]string{
					"l1": "v1",
				},
			},
			override: &workflows.DockerBuildSpec{
				Labels: map[string]string{
					"l2": "v2",
				},
			},
			want: &workflows.DockerBuildSpec{
				Labels: map[string]string{
					"l1": "v1",
					"l2": "v2",
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mergeDockerBuildSpec(tt.base, tt.override)
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("mergeDockerBuildSpec() = %+v, want %+v", got, tt.want)
			}
		})
	}
}
