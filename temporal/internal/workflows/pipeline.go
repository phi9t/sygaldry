package workflows

import (
	"fmt"
	"sort"
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"

	"temporal-orchestration/internal/activities"
)

type When struct {
	Step   string `json:"step" yaml:"step"`
	Status string `json:"status" yaml:"status"`
}

type DownloadSpec struct {
	URL    string `json:"url" yaml:"url"`
	Output string `json:"output" yaml:"output"`
	Sha256 string `json:"sha256" yaml:"sha256"`
}

type DockerBuildSpec struct {
	Image      string            `json:"image" yaml:"image"`
	Context    string            `json:"context" yaml:"context"`
	Dockerfile string            `json:"dockerfile" yaml:"dockerfile"`
	BuildArgs  map[string]string `json:"buildArgs" yaml:"build_args"`
	Labels     map[string]string `json:"labels" yaml:"labels"`
	Platform   string            `json:"platform" yaml:"platform"`
	Target     string            `json:"target" yaml:"target"`
}

type DockerPushSpec struct {
	Image string `json:"image" yaml:"image"`
}

type PackageBuildSpec struct {
	Command    string            `json:"command" yaml:"command"`
	Args       []string          `json:"args" yaml:"args"`
	Env        map[string]string `json:"env" yaml:"env"`
	WorkingDir string            `json:"workingDir" yaml:"working_dir"`
}

type ContainerJobSpec struct {
	ProjectID    string            `json:"projectId" yaml:"project_id"`
	Entrypoint   string            `json:"entrypoint" yaml:"entrypoint"`
	Command      string            `json:"command" yaml:"command"`
	Env          map[string]string `json:"env" yaml:"env"`
	GPU          bool              `json:"gpu" yaml:"gpu"`
	LauncherPath string            `json:"launcherPath" yaml:"launcher_path"`
}

type HFDownloadDatasetSpec struct {
	DatasetID string `json:"datasetId" yaml:"dataset_id"`
	Config    string `json:"config" yaml:"config"`
	Split     string `json:"split" yaml:"split"`
	CacheDir  string `json:"cacheDir" yaml:"cache_dir"`
}

type HFDownloadModelSpec struct {
	ModelID  string `json:"modelId" yaml:"model_id"`
	CacheDir string `json:"cacheDir" yaml:"cache_dir"`
}

type PipelineStep struct {
	ID             string            `json:"id" yaml:"id"`
	Name           string            `json:"name" yaml:"name"`
	Type           string            `json:"type" yaml:"type"`
	DependsOn      []string          `json:"dependsOn" yaml:"depends_on"`
	When           *When             `json:"when" yaml:"when"`
	Command        string            `json:"command" yaml:"command"`
	Args           []string          `json:"args" yaml:"args"`
	Env            map[string]string `json:"env" yaml:"env"`
	WorkingDir     string            `json:"workingDir" yaml:"working_dir"`
	TimeoutSeconds int               `json:"timeoutSeconds" yaml:"timeout_seconds"`
	AllowFailure   bool              `json:"allowFailure" yaml:"allow_failure"`
	Download          *DownloadSpec          `json:"download" yaml:"download"`
	DockerBuild       *DockerBuildSpec       `json:"dockerBuild" yaml:"docker_build"`
	DockerPush        *DockerPushSpec        `json:"dockerPush" yaml:"docker_push"`
	PackageBuild      *PackageBuildSpec      `json:"packageBuild" yaml:"package_build"`
	ContainerJob      *ContainerJobSpec      `json:"containerJob" yaml:"container_job"`
	HFDownloadDataset *HFDownloadDatasetSpec `json:"hfDownloadDataset" yaml:"hf_download_dataset"`
	HFDownloadModel   *HFDownloadModelSpec   `json:"hfDownloadModel" yaml:"hf_download_model"`
}

type PipelineInput struct {
	LogDir string         `json:"logDir" yaml:"log_dir"`
	Steps  []PipelineStep `json:"steps" yaml:"steps"`
}

type PipelineStepResult struct {
	Name            string `json:"name"`
	ExitCode        int    `json:"exitCode"`
	Stdout          string `json:"stdout"`
	Stderr          string `json:"stderr"`
	StdoutPath      string `json:"stdoutPath"`
	StderrPath      string `json:"stderrPath"`
	StructuredPath  string `json:"structuredPath"`
	StdoutTruncated bool   `json:"stdoutTruncated"`
	StderrTruncated bool   `json:"stderrTruncated"`
	Succeeded       bool   `json:"succeeded"`
	DurationSec     int64  `json:"durationSec"`
	Error           string `json:"error"`
}

type StepOutcome struct {
	ID         string             `json:"id"`
	Name       string             `json:"name"`
	State      string             `json:"state"`
	Result     PipelineStepResult `json:"result"`
	SkipReason string             `json:"skipReason,omitempty"`
}

type PipelineResult struct {
	Succeeded bool          `json:"succeeded"`
	Steps     []StepOutcome `json:"steps"`
}

func Pipeline(ctx workflow.Context, input PipelineInput) (PipelineResult, error) {
	logger := workflow.GetLogger(ctx)
	info := workflow.GetInfo(ctx)
	logDir := "logs"
	if input.LogDir != "" {
		logDir = input.LogDir
	}
	outcomes := map[string]StepOutcome{}
	pending := map[string]PipelineStep{}
	order := make([]string, 0, len(input.Steps))

	for _, step := range input.Steps {
		pending[step.ID] = step
		order = append(order, step.ID)
	}

	baseOptions := workflow.ActivityOptions{
		StartToCloseTimeout: 2 * time.Hour,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    5 * time.Second,
			BackoffCoefficient: 2.0,
			MaximumInterval:    1 * time.Minute,
			MaximumAttempts:    3,
		},
	}

	for len(pending) > 0 {
		progressed := false
		runnable := make([]PipelineStep, 0)

		for id, step := range pending {
			if !depsCompleted(step, outcomes) {
				continue
			}
			if skip, reason := shouldSkip(step, outcomes); skip {
				outcomes[id] = StepOutcome{
					ID:         step.ID,
					Name:       stepName(step),
					State:      "skipped",
					Result:     PipelineStepResult{Name: stepName(step)},
					SkipReason: reason,
				}
				delete(pending, id)
				progressed = true
				continue
			}
			runnable = append(runnable, step)
		}

		if len(runnable) == 0 {
			if progressed {
				continue
			}
			return PipelineResult{Succeeded: false, Steps: ordered(outcomes, order)}, temporal.NewNonRetryableApplicationError("pipeline deadlock: check dependencies and conditions", "PipelineDeadlock", nil)
		}

		running := make([]runningStep, 0, len(runnable))
		for _, step := range runnable {
			logger.Info("running step", "id", step.ID, "type", step.Type)
			stepTimeout := baseOptions.StartToCloseTimeout
			if step.TimeoutSeconds > 0 {
				stepTimeout = time.Duration(step.TimeoutSeconds) * time.Second
			}
			stepCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
				StartToCloseTimeout: stepTimeout,
				RetryPolicy:         baseOptions.RetryPolicy,
				ActivityID:          step.ID,
			})
			workflow.UpsertSearchAttributes(ctx, map[string]interface{}{
				"CustomStringField":  stepName(step),
				"CustomKeywordField": step.ID,
			})

			activityFuture := startActivity(stepCtx, info, logDir, step)
			running = append(running, runningStep{step: step, ctx: stepCtx, future: activityFuture})
		}

		for _, run := range running {
			result, err := waitActivity(run)
			outcome := StepOutcome{
				ID:     run.step.ID,
				Name:   stepName(run.step),
				Result: result,
			}
			if err != nil {
				outcome.State = "failed"
				outcome.Result.Succeeded = false
				outcome.Result.Error = err.Error()
				outcomes[run.step.ID] = outcome
				delete(pending, run.step.ID)
				progressed = true
				if !run.step.AllowFailure {
					return PipelineResult{Succeeded: false, Steps: ordered(outcomes, order)}, err
				}
				continue
			}

			if result.ExitCode == 0 {
				outcome.State = "success"
			} else {
				outcome.State = "failed"
				outcome.Result.Succeeded = false
				if !run.step.AllowFailure {
					outcomes[run.step.ID] = outcome
					delete(pending, run.step.ID)
					progressed = true
					return PipelineResult{Succeeded: false, Steps: ordered(outcomes, order)}, temporal.NewNonRetryableApplicationError("step returned non-zero exit code", "StepFailed", nil)
				}
			}

			outcomes[run.step.ID] = outcome
			delete(pending, run.step.ID)
			progressed = true
		}

		if !progressed {
			return PipelineResult{Succeeded: false, Steps: ordered(outcomes, order)}, temporal.NewNonRetryableApplicationError("pipeline stalled", "PipelineStalled", nil)
		}
	}

	return PipelineResult{Succeeded: true, Steps: ordered(outcomes, order)}, nil
}

type runningStep struct {
	step   PipelineStep
	ctx    workflow.Context
	future workflow.Future
}

func depsCompleted(step PipelineStep, outcomes map[string]StepOutcome) bool {
	for _, dep := range step.DependsOn {
		if _, ok := outcomes[dep]; !ok {
			return false
		}
	}
	return true
}

func shouldSkip(step PipelineStep, outcomes map[string]StepOutcome) (bool, string) {
	if step.When != nil {
		outcome, ok := outcomes[step.When.Step]
		if !ok {
			return false, ""
		}
		if step.When.Status == "success" && outcome.State == "success" {
			return false, ""
		}
		if step.When.Status == "failure" && outcome.State == "failed" {
			return false, ""
		}
		return true, fmt.Sprintf("when condition not met: %s is %s", step.When.Step, step.When.Status)
	}

	for _, dep := range step.DependsOn {
		if outcome, ok := outcomes[dep]; ok && outcome.State != "success" {
			return true, fmt.Sprintf("dependency %s did not succeed", dep)
		}
	}
	return false, ""
}

func startActivity(ctx workflow.Context, info *workflow.Info, logDir string, step PipelineStep) workflow.Future {
	switch step.Type {
	case "command":
		return workflow.ExecuteActivity(ctx, activities.RunCommand, activities.RunCommandInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			Command:     step.Command,
			Args:        step.Args,
			Env:         step.Env,
			WorkingDir:  step.WorkingDir,
			TimeoutSecs: step.TimeoutSeconds,
		})
	case "download":
		spec := step.Download
		if spec == nil {
			spec = &DownloadSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.DownloadFile, activities.DownloadInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			URL:         spec.URL,
			OutputPath:  spec.Output,
			Sha256:      spec.Sha256,
			TimeoutSecs: step.TimeoutSeconds,
		})
	case "docker_build":
		spec := step.DockerBuild
		if spec == nil {
			spec = &DockerBuildSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.DockerBuild, activities.DockerBuildInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			Image:       spec.Image,
			Context:     spec.Context,
			Dockerfile:  spec.Dockerfile,
			BuildArgs:   spec.BuildArgs,
			Labels:      spec.Labels,
			Platform:    spec.Platform,
			Target:      spec.Target,
			TimeoutSecs: step.TimeoutSeconds,
		})
	case "docker_push":
		spec := step.DockerPush
		if spec == nil {
			spec = &DockerPushSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.DockerPush, activities.DockerPushInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			Image:       spec.Image,
			TimeoutSecs: step.TimeoutSeconds,
		})
	case "package_build":
		spec := step.PackageBuild
		if spec == nil {
			spec = &PackageBuildSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.PackageBuild, activities.PackageBuildInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			Command:     spec.Command,
			Args:        spec.Args,
			Env:         spec.Env,
			WorkingDir:  spec.WorkingDir,
			TimeoutSecs: step.TimeoutSeconds,
		})
	case "container_job":
		spec := step.ContainerJob
		if spec == nil {
			spec = &ContainerJobSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.ContainerJob, activities.ContainerJobInput{
			Name:         stepName(step),
			WorkflowID:   info.WorkflowExecution.ID,
			RunID:        info.WorkflowExecution.RunID,
			StepID:       step.ID,
			LogDir:       logDir,
			ProjectID:    spec.ProjectID,
			Entrypoint:   spec.Entrypoint,
			Command:      spec.Command,
			Env:          spec.Env,
			GPU:          spec.GPU,
			LauncherPath: spec.LauncherPath,
			TimeoutSecs:  step.TimeoutSeconds,
		})
	case "hf_download_dataset":
		spec := step.HFDownloadDataset
		if spec == nil {
			spec = &HFDownloadDatasetSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.HFDownloadDataset, activities.HFDownloadDatasetInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			DatasetID:   spec.DatasetID,
			Config:      spec.Config,
			Split:       spec.Split,
			CacheDir:    spec.CacheDir,
			TimeoutSecs: step.TimeoutSeconds,
		})
	case "hf_download_model":
		spec := step.HFDownloadModel
		if spec == nil {
			spec = &HFDownloadModelSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.HFDownloadModel, activities.HFDownloadModelInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			ModelID:     spec.ModelID,
			CacheDir:    spec.CacheDir,
			TimeoutSecs: step.TimeoutSeconds,
		})
	default:
		return workflow.ExecuteActivity(ctx, activities.RunCommand, activities.RunCommandInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			Command:     step.Command,
			Args:        step.Args,
			Env:         step.Env,
			WorkingDir:  step.WorkingDir,
			TimeoutSecs: step.TimeoutSeconds,
		})
	}
}

func waitActivity(run runningStep) (PipelineStepResult, error) {
	name := stepName(run.step)

	if run.step.Type == "download" {
		var result activities.DownloadResult
		err := run.future.Get(run.ctx, &result)
		return PipelineStepResult{
			Name:           name,
			ExitCode:       result.ExitCode,
			Stdout:         result.Stdout,
			Stderr:         result.Stderr,
			StdoutPath:     result.StdoutPath,
			StderrPath:     result.StderrPath,
			StructuredPath: result.StructuredPath,
			Succeeded:      result.ExitCode == 0,
			DurationSec:    result.DurationSec,
		}, err
	}

	var result activities.RunCommandResult
	err := run.future.Get(run.ctx, &result)
	return PipelineStepResult{
		Name:            name,
		ExitCode:        result.ExitCode,
		Stdout:          result.Stdout,
		Stderr:          result.Stderr,
		StdoutPath:      result.StdoutPath,
		StderrPath:      result.StderrPath,
		StructuredPath:  result.StructuredPath,
		StdoutTruncated: result.StdoutTruncated,
		StderrTruncated: result.StderrTruncated,
		Succeeded:       result.ExitCode == 0,
		DurationSec:     result.DurationSec,
	}, err
}

func ordered(outcomes map[string]StepOutcome, order []string) []StepOutcome {
	ordered := make([]StepOutcome, 0, len(outcomes))
	seen := map[string]bool{}
	for _, id := range order {
		if outcome, ok := outcomes[id]; ok {
			ordered = append(ordered, outcome)
			seen[id] = true
		}
	}

	if len(outcomes) != len(ordered) {
		extra := make([]string, 0)
		for id := range outcomes {
			if !seen[id] {
				extra = append(extra, id)
			}
		}
		sort.Strings(extra)
		for _, id := range extra {
			ordered = append(ordered, outcomes[id])
		}
	}

	return ordered
}

func stepName(step PipelineStep) string {
	if step.Name != "" {
		return step.Name
	}
	return step.ID
}
