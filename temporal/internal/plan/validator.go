package plan

import (
	"errors"
	"fmt"
	"sort"
	"strings"

	"temporal-orchestration/internal/workflows"
)

var allowedTypes = map[string]bool{
	"command":             true,
	"download":            true,
	"docker_build":        true,
	"docker_push":         true,
	"package_build":       true,
	"container_job":       true,
	"hf_download_dataset": true,
	"hf_download_model":   true,
	"agent_task":          true,
	"git_op":              true,
}

// AllowedTypes returns a copy of the set of valid step type strings.
func AllowedTypes() map[string]bool {
	out := make(map[string]bool, len(allowedTypes))
	for k, v := range allowedTypes {
		out[k] = v
	}
	return out
}

// Validate checks a PipelineInput for structural correctness: required fields,
// known types, valid depends_on references, valid when clauses, and cycle-free
// dependency graph. It sets step.Name = step.ID for steps with no explicit name.
func Validate(input *workflows.PipelineInput) error {
	if len(input.Steps) == 0 {
		return fmt.Errorf("plan must have at least one step")
	}

	var errs []error
	ids := map[string]bool{}
	for i := range input.Steps {
		step := &input.Steps[i]
		if step.ID == "" {
			errs = append(errs, fmt.Errorf("step %d is missing id", i))
			continue
		}
		if ids[step.ID] {
			errs = append(errs, fmt.Errorf("duplicate step id: %s", step.ID))
		}
		ids[step.ID] = true
		if step.Type == "" {
			errs = append(errs, fmt.Errorf("step %s is missing type", step.ID))
		} else if !allowedTypes[step.Type] {
			errs = append(errs, fmt.Errorf("step %s has unsupported type %s", step.ID, step.Type))
		} else {
			switch step.Type {
			case "command":
				if step.Command == "" {
					errs = append(errs, fmt.Errorf("step %s command is required", step.ID))
				}
			case "download":
				if step.Download == nil || step.Download.URL == "" || step.Download.Output == "" {
					errs = append(errs, fmt.Errorf("step %s download requires url and output", step.ID))
				}
			case "docker_build":
				if step.DockerBuild == nil || step.DockerBuild.Image == "" {
					errs = append(errs, fmt.Errorf("step %s docker_build requires image", step.ID))
				}
			case "docker_push":
				if step.DockerPush == nil || step.DockerPush.Image == "" {
					errs = append(errs, fmt.Errorf("step %s docker_push requires image", step.ID))
				}
			case "package_build":
				if step.PackageBuild == nil || step.PackageBuild.Command == "" {
					errs = append(errs, fmt.Errorf("step %s package_build requires command", step.ID))
				}
			case "container_job":
				if step.ContainerJob == nil || step.ContainerJob.Command == "" {
					errs = append(errs, fmt.Errorf("step %s container_job requires command", step.ID))
				}
			case "hf_download_dataset":
				if step.HFDownloadDataset == nil || step.HFDownloadDataset.DatasetID == "" {
					errs = append(errs, fmt.Errorf("step %s hf_download_dataset requires dataset_id", step.ID))
				}
			case "hf_download_model":
				if step.HFDownloadModel == nil || step.HFDownloadModel.ModelID == "" {
					errs = append(errs, fmt.Errorf("step %s hf_download_model requires model_id", step.ID))
				}
			case "agent_task":
				if step.AgentTask == nil {
					errs = append(errs, fmt.Errorf("step %s agent_task requires agent_task config", step.ID))
				} else {
					if step.AgentTask.Engine == "" {
						errs = append(errs, fmt.Errorf("step %s agent_task requires engine", step.ID))
					}
					if step.AgentTask.Prompt == "" && step.AgentTask.PromptFile == "" {
						errs = append(errs, fmt.Errorf("step %s agent_task requires prompt or prompt_file", step.ID))
					}
				}
			case "git_op":
				if step.GitOp == nil || step.GitOp.Op == "" {
					errs = append(errs, fmt.Errorf("step %s git_op requires op", step.ID))
				}
			}
		}
		if step.Name == "" {
			step.Name = step.ID
		}
	}

	if len(errs) == 0 {
		for _, step := range input.Steps {
			for _, dep := range step.DependsOn {
				if !ids[dep] {
					errs = append(errs, fmt.Errorf("step %s depends on unknown step %s", step.ID, dep))
				}
			}
			if step.When != nil {
				if step.When.Step == "" || (step.When.Status != "success" && step.When.Status != "failure") {
					errs = append(errs, fmt.Errorf("step %s has invalid when condition", step.ID))
				} else if !ids[step.When.Step] {
					errs = append(errs, fmt.Errorf("step %s when references unknown step %s", step.ID, step.When.Step))
				}
			}
		}

		if len(errs) == 0 {
			if cycle := detectDependencyCycle(input.Steps); cycle != "" {
				errs = append(errs, fmt.Errorf("dependency cycle detected: %s", cycle))
			}
		}
	}

	return errors.Join(errs...)
}

func detectDependencyCycle(steps []workflows.PipelineStep) string {
	type color int
	const (
		white color = iota
		gray
		black
	)

	byID := map[string]workflows.PipelineStep{}
	for _, step := range steps {
		byID[step.ID] = step
	}

	state := map[string]color{}
	stack := []string{}
	var cycle string

	var visit func(string) bool
	visit = func(id string) bool {
		state[id] = gray
		stack = append(stack, id)

		deps := append([]string(nil), byID[id].DependsOn...)
		sort.Strings(deps)
		for _, dep := range deps {
			switch state[dep] {
			case gray:
				cycle = renderCycle(stack, dep)
				return true
			case white:
				if visit(dep) {
					return true
				}
			}
		}

		state[id] = black
		stack = stack[:len(stack)-1]
		return false
	}

	ids := make([]string, 0, len(steps))
	for _, step := range steps {
		ids = append(ids, step.ID)
		state[step.ID] = white
	}
	sort.Strings(ids)
	for _, id := range ids {
		if state[id] == white && visit(id) {
			return cycle
		}
	}
	return ""
}

func renderCycle(stack []string, target string) string {
	start := 0
	for i, id := range stack {
		if id == target {
			start = i
			break
		}
	}
	path := append([]string(nil), stack[start:]...)
	path = append(path, target)
	return strings.Join(path, " -> ")
}
