package workflows

import (
	"bufio"
	"fmt"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"

	"temporal-orchestration/internal/activities"
)

type When struct {
	Step   string `json:"step" yaml:"step"`
	Status string `json:"status" yaml:"status"`
}

type RetrySpec struct {
	MaxAttempts            int     `json:"maxAttempts" yaml:"max_attempts"`
	InitialIntervalSeconds int     `json:"initialIntervalSeconds" yaml:"initial_interval_seconds"`
	BackoffCoefficient     float64 `json:"backoffCoefficient" yaml:"backoff_coefficient"`
	MaximumIntervalSeconds int     `json:"maximumIntervalSeconds" yaml:"maximum_interval_seconds"`
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

type K8sJobSpec struct {
	ProjectID  string            `json:"projectId" yaml:"project_id"`
	Entrypoint string            `json:"entrypoint" yaml:"entrypoint"`
	Command    string            `json:"command" yaml:"command"`
	Env        map[string]string `json:"env" yaml:"env"`
	GPU        bool              `json:"gpu" yaml:"gpu"`
	GPUCount   int               `json:"gpuCount" yaml:"gpu_count"`
	Image      string            `json:"image" yaml:"image"`
	Namespace  string            `json:"namespace" yaml:"namespace"`
}

type AgentTaskSpec struct {
	Engine     string            `json:"engine" yaml:"engine"`
	Model      string            `json:"model" yaml:"model"`
	Prompt     string            `json:"prompt" yaml:"prompt"`
	PromptFile string            `json:"promptFile" yaml:"prompt_file"`
	WorkingDir string            `json:"workingDir" yaml:"working_dir"`
	Sandbox    string            `json:"sandbox" yaml:"sandbox"`
	Env        map[string]string `json:"env" yaml:"env"`
	Params     map[string]string `json:"params" yaml:"params"`
}

type GitOpSpec struct {
	Op            string            `json:"op" yaml:"op"`
	RepoDir       string            `json:"repoDir" yaml:"repo_dir"`
	Branch        string            `json:"branch" yaml:"branch"`
	BaseBranch    string            `json:"baseBranch" yaml:"base_branch"`
	CommitMessage string            `json:"commitMessage" yaml:"commit_message"`
	PRTitle       string            `json:"prTitle" yaml:"pr_title"`
	PRBody        string            `json:"prBody" yaml:"pr_body"`
	GitOpsScript  string            `json:"gitOpsScript" yaml:"git_ops_script"`
	Env           map[string]string `json:"env" yaml:"env"`
}

type PipelineStep struct {
	ID             string            `json:"id" yaml:"id"`
	Name           string            `json:"name" yaml:"name"`
	Type           string            `json:"type" yaml:"type"`
	Template       string            `json:"template,omitempty" yaml:"template"`
	DependsOn      []string          `json:"dependsOn" yaml:"depends_on"`
	When           *When             `json:"when" yaml:"when"`
	Command        string            `json:"command" yaml:"command"`
	Args           []string          `json:"args" yaml:"args"`
	Env            map[string]string `json:"env" yaml:"env"`
	WorkingDir     string            `json:"workingDir" yaml:"working_dir"`
	TimeoutSeconds int               `json:"timeoutSeconds" yaml:"timeout_seconds"`
	AllowFailure   bool              `json:"allowFailure" yaml:"allow_failure"`
	Retry          *RetrySpec        `json:"retry,omitempty" yaml:"retry"`

	Download          *DownloadSpec          `json:"download" yaml:"download"`
	DockerBuild       *DockerBuildSpec       `json:"dockerBuild" yaml:"docker_build"`
	DockerPush        *DockerPushSpec        `json:"dockerPush" yaml:"docker_push"`
	PackageBuild      *PackageBuildSpec      `json:"packageBuild" yaml:"package_build"`
	ContainerJob      *ContainerJobSpec      `json:"containerJob" yaml:"container_job"`
	HFDownloadDataset *HFDownloadDatasetSpec `json:"hfDownloadDataset" yaml:"hf_download_dataset"`
	HFDownloadModel   *HFDownloadModelSpec   `json:"hfDownloadModel" yaml:"hf_download_model"`
	K8sJob            *K8sJobSpec            `json:"k8sJob" yaml:"k8s_job"`
	AgentTask         *AgentTaskSpec         `json:"agentTask" yaml:"agent_task"`
	GitOp             *GitOpSpec             `json:"gitOp" yaml:"git_op"`
}

type PipelineInput struct {
	LogDir    string                  `json:"logDir" yaml:"log_dir"`
	Params    map[string]string       `json:"params,omitempty" yaml:"params"`
	Env       map[string]string       `json:"env,omitempty" yaml:"env"`
	Imports   []string                `json:"imports,omitempty" yaml:"imports"`
	Templates map[string]PipelineStep `json:"templates,omitempty" yaml:"templates"`
	Steps     []PipelineStep          `json:"steps" yaml:"steps"`
}

type PipelineStepResult struct {
	Name            string            `json:"name"`
	ExitCode        int               `json:"exitCode"`
	Stdout          string            `json:"stdout"`
	Stderr          string            `json:"stderr"`
	StdoutPath      string            `json:"stdoutPath"`
	StderrPath      string            `json:"stderrPath"`
	StructuredPath  string            `json:"structuredPath"`
	StdoutTruncated bool              `json:"stdoutTruncated"`
	StderrTruncated bool              `json:"stderrTruncated"`
	Succeeded       bool              `json:"succeeded"`
	DurationSec     int64             `json:"durationSec"`
	Outputs         map[string]string `json:"outputs,omitempty"`
	Error           string            `json:"error"`
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

var outputPattern = regexp.MustCompile(`^::set-output\s+name=([A-Za-z_][A-Za-z0-9_-]*)::(.*)$`)
var templatePattern = regexp.MustCompile(`\$\{\{\s*([^}]+?)\s*\}\}`)

func Pipeline(ctx workflow.Context, input PipelineInput) (PipelineResult, error) {
	logger := workflow.GetLogger(ctx)
	info := workflow.GetInfo(ctx)
	logDir := "logs"
	if input.LogDir != "" {
		logDir = input.LogDir
	}

	outcomes := map[string]StepOutcome{}
	pending := map[string]PipelineStep{}
	running := map[string]runningStep{}
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

	for len(pending) > 0 || len(running) > 0 {
		progressed := false

		for _, id := range sortedStepIDs(pending) {
			step := pending[id]
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

			rendered, err := prepareStep(step, input, outcomes)
			if err != nil {
				outcome := StepOutcome{
					ID:    step.ID,
					Name:  stepName(step),
					State: "failed",
					Result: PipelineStepResult{
						Name:      stepName(step),
						Succeeded: false,
						Error:     err.Error(),
					},
				}
				outcomes[id] = outcome
				delete(pending, id)
				progressed = true
				if !step.AllowFailure {
					return PipelineResult{Succeeded: false, Steps: ordered(outcomes, order)}, temporal.NewNonRetryableApplicationError(err.Error(), "TemplateExpansionFailed", nil)
				}
				continue
			}

			logger.Info("running step", "id", rendered.ID, "type", rendered.Type)
			stepCtx := workflow.WithActivityOptions(ctx, activityOptionsForStep(baseOptions, rendered))
			workflow.UpsertSearchAttributes(ctx, map[string]interface{}{
				"CustomStringField":  stepName(rendered),
				"CustomKeywordField": rendered.ID,
			})
			activityFuture := startActivity(stepCtx, info, logDir, rendered)
			running[id] = runningStep{step: rendered, ctx: stepCtx, future: activityFuture}
			delete(pending, id)
			progressed = true
		}

		if len(running) == 0 {
			if progressed {
				continue
			}
			return PipelineResult{Succeeded: false, Steps: ordered(outcomes, order)}, temporal.NewNonRetryableApplicationError("pipeline deadlock: check dependencies and conditions", "PipelineDeadlock", nil)
		}

		completedID, completedResult, completedErr := awaitNextCompletion(ctx, running)
		run := running[completedID]
		delete(running, completedID)

		outcome, earlyReturn := resolveStepOutcome(run, completedResult, completedErr, outcomes, order)
		outcomes[run.step.ID] = outcome
		if earlyReturn != nil {
			return earlyReturn.PipelineResult, earlyReturn.err
		}
	}

	return PipelineResult{Succeeded: true, Steps: ordered(outcomes, order)}, nil
}

type runningStep struct {
	step   PipelineStep
	ctx    workflow.Context
	future workflow.Future
}

// pipelineEarlyReturn packages a result with its error for early pipeline exits.
type pipelineEarlyReturn struct {
	PipelineResult
	err error
}

// awaitNextCompletion blocks on the Temporal selector until one running activity finishes.
func awaitNextCompletion(ctx workflow.Context, running map[string]runningStep) (string, PipelineStepResult, error) {
	selector := workflow.NewSelector(ctx)
	var completedID string
	var completedResult PipelineStepResult
	var completedErr error
	for id, run := range running {
		idCopy := id
		runCopy := run
		selector.AddFuture(runCopy.future, func(f workflow.Future) {
			completedID = idCopy
			completedResult, completedErr = waitActivity(runCopy)
		})
	}
	selector.Select(ctx)
	return completedID, completedResult, completedErr
}

// resolveStepOutcome converts activity completion into a StepOutcome and optionally
// signals early pipeline termination (non-nil return).
func resolveStepOutcome(
	run runningStep,
	result PipelineStepResult,
	activityErr error,
	outcomes map[string]StepOutcome,
	order []string,
) (StepOutcome, *pipelineEarlyReturn) {
	outcome := StepOutcome{
		ID:     run.step.ID,
		Name:   stepName(run.step),
		Result: result,
	}

	if activityErr != nil {
		outcome.State = "failed"
		outcome.Result.Succeeded = false
		outcome.Result.Error = activityErr.Error()
		if !run.step.AllowFailure {
			outcomes[run.step.ID] = outcome
			return outcome, &pipelineEarlyReturn{
				PipelineResult: PipelineResult{Succeeded: false, Steps: ordered(outcomes, order)},
				err:            activityErr,
			}
		}
		return outcome, nil
	}

	if result.ExitCode == 0 {
		outcome.State = "success"
	} else {
		outcome.State = "failed"
		outcome.Result.Succeeded = false
		if !run.step.AllowFailure {
			outcomes[run.step.ID] = outcome
			return outcome, &pipelineEarlyReturn{
				PipelineResult: PipelineResult{Succeeded: false, Steps: ordered(outcomes, order)},
				err:            temporal.NewNonRetryableApplicationError("step returned non-zero exit code", "StepFailed", nil),
			}
		}
	}
	return outcome, nil
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

func activityOptionsForStep(base workflow.ActivityOptions, step PipelineStep) workflow.ActivityOptions {
	stepTimeout := base.StartToCloseTimeout
	if step.TimeoutSeconds > 0 {
		stepTimeout = time.Duration(step.TimeoutSeconds) * time.Second
	}

	retryPolicy := &temporal.RetryPolicy{}
	if base.RetryPolicy != nil {
		*retryPolicy = *base.RetryPolicy
	}
	if step.Retry != nil {
		if step.Retry.InitialIntervalSeconds > 0 {
			retryPolicy.InitialInterval = time.Duration(step.Retry.InitialIntervalSeconds) * time.Second
		}
		if step.Retry.BackoffCoefficient > 0 {
			retryPolicy.BackoffCoefficient = step.Retry.BackoffCoefficient
		}
		if step.Retry.MaximumIntervalSeconds > 0 {
			retryPolicy.MaximumInterval = time.Duration(step.Retry.MaximumIntervalSeconds) * time.Second
		}
		if step.Retry.MaxAttempts > 0 {
			retryPolicy.MaximumAttempts = int32(step.Retry.MaxAttempts)
		}
	}

	return workflow.ActivityOptions{
		StartToCloseTimeout: stepTimeout,
		HeartbeatTimeout:    30 * time.Second,
		RetryPolicy:         retryPolicy,
		ActivityID:          step.ID,
	}
}

func prepareStep(step PipelineStep, input PipelineInput, outcomes map[string]StepOutcome) (PipelineStep, error) {
	rendered := step

	planEnv := cloneMap(input.Env)
	rendered.Env = mergeStringMaps(planEnv, rendered.Env)
	if rendered.PackageBuild != nil {
		rendered.PackageBuild.Env = mergeStringMaps(planEnv, rendered.PackageBuild.Env)
	}
	if rendered.ContainerJob != nil {
		rendered.ContainerJob.Env = mergeStringMaps(planEnv, rendered.ContainerJob.Env)
	}
	if rendered.K8sJob != nil {
		rendered.K8sJob.Env = mergeStringMaps(planEnv, rendered.K8sJob.Env)
	}
	if rendered.AgentTask != nil {
		rendered.AgentTask.Env = mergeStringMaps(planEnv, rendered.AgentTask.Env)
	}
	if rendered.GitOp != nil {
		rendered.GitOp.Env = mergeStringMaps(planEnv, rendered.GitOp.Env)
	}

	envLookup := cloneMap(planEnv)
	envLookup = mergeStringMaps(envLookup, rendered.Env)
	if rendered.PackageBuild != nil {
		envLookup = mergeStringMaps(envLookup, rendered.PackageBuild.Env)
	}
	if rendered.ContainerJob != nil {
		envLookup = mergeStringMaps(envLookup, rendered.ContainerJob.Env)
	}
	if rendered.K8sJob != nil {
		envLookup = mergeStringMaps(envLookup, rendered.K8sJob.Env)
	}
	if rendered.AgentTask != nil {
		envLookup = mergeStringMaps(envLookup, rendered.AgentTask.Env)
	}
	if rendered.GitOp != nil {
		envLookup = mergeStringMaps(envLookup, rendered.GitOp.Env)
	}

	if err := expandStepTemplates(&rendered, outcomes, input.Params, envLookup); err != nil {
		return PipelineStep{}, err
	}
	return rendered, nil
}

func expandStepTemplates(step *PipelineStep, outcomes map[string]StepOutcome, params, env map[string]string) error {
	resolver := func(expr string) (string, error) {
		expr = strings.TrimSpace(expr)
		switch {
		case strings.HasPrefix(expr, "params."):
			key := strings.TrimPrefix(expr, "params.")
			if key == "" {
				return "", fmt.Errorf("invalid params expression %q", expr)
			}
			value, ok := params[key]
			if !ok {
				return "", fmt.Errorf("unknown param %q", key)
			}
			return value, nil
		case strings.HasPrefix(expr, "env."):
			key := strings.TrimPrefix(expr, "env.")
			if key == "" {
				return "", fmt.Errorf("invalid env expression %q", expr)
			}
			value, ok := env[key]
			if !ok {
				return "", fmt.Errorf("unknown env var %q", key)
			}
			return value, nil
		case strings.HasPrefix(expr, "steps."):
			parts := strings.Split(expr, ".")
			if len(parts) != 4 || parts[2] != "outputs" {
				return "", fmt.Errorf("invalid step output expression %q", expr)
			}
			stepID := parts[1]
			outputName := parts[3]
			outcome, ok := outcomes[stepID]
			if !ok {
				return "", fmt.Errorf("step %q not finished for expression %q", stepID, expr)
			}
			value, ok := outcome.Result.Outputs[outputName]
			if !ok {
				return "", fmt.Errorf("step %q has no output %q", stepID, outputName)
			}
			return value, nil
		default:
			return "", fmt.Errorf("unsupported template expression %q", expr)
		}
	}
	return expandTemplatesInValue(reflect.ValueOf(step).Elem(), resolver)
}

func expandTemplatesInValue(value reflect.Value, resolver func(string) (string, error)) error {
	if !value.IsValid() {
		return nil
	}

	switch value.Kind() {
	case reflect.Pointer:
		if value.IsNil() {
			return nil
		}
		return expandTemplatesInValue(value.Elem(), resolver)
	case reflect.Struct:
		for i := 0; i < value.NumField(); i++ {
			if err := expandTemplatesInValue(value.Field(i), resolver); err != nil {
				return err
			}
		}
		return nil
	case reflect.Slice:
		for i := 0; i < value.Len(); i++ {
			if err := expandTemplatesInValue(value.Index(i), resolver); err != nil {
				return err
			}
		}
		return nil
	case reflect.Map:
		if value.IsNil() {
			return nil
		}
		if value.Type().Key().Kind() != reflect.String {
			return nil
		}
		keys := value.MapKeys()
		keyNames := make([]string, 0, len(keys))
		for _, key := range keys {
			keyNames = append(keyNames, key.String())
		}
		sort.Strings(keyNames)
		for _, keyName := range keyNames {
			key := reflect.ValueOf(keyName)
			entry := value.MapIndex(key)
			if entry.Kind() == reflect.String {
				expanded, err := expandTemplateString(entry.String(), resolver)
				if err != nil {
					return err
				}
				value.SetMapIndex(key, reflect.ValueOf(expanded))
			}
		}
		return nil
	case reflect.String:
		if !value.CanSet() {
			return nil
		}
		expanded, err := expandTemplateString(value.String(), resolver)
		if err != nil {
			return err
		}
		value.SetString(expanded)
		return nil
	default:
		return nil
	}
}

func expandTemplateString(input string, resolver func(string) (string, error)) (string, error) {
	if !strings.Contains(input, "${{") {
		return input, nil
	}

	indices := templatePattern.FindAllStringSubmatchIndex(input, -1)
	if len(indices) == 0 {
		return input, nil
	}

	var out strings.Builder
	cursor := 0
	for _, match := range indices {
		out.WriteString(input[cursor:match[0]])
		expr := input[match[2]:match[3]]
		resolved, err := resolver(expr)
		if err != nil {
			return "", err
		}
		out.WriteString(resolved)
		cursor = match[1]
	}
	out.WriteString(input[cursor:])
	return out.String(), nil
}

func sortedStepIDs(steps map[string]PipelineStep) []string {
	ids := make([]string, 0, len(steps))
	for id := range steps {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func cloneMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return map[string]string{}
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func mergeStringMaps(base map[string]string, override map[string]string) map[string]string {
	result := cloneMap(base)
	for k, v := range override {
		result[k] = v
	}
	return result
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
	case "k8s_job":
		spec := step.K8sJob
		if spec == nil {
			spec = &K8sJobSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.K8sJob, activities.K8sJobInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			ProjectID:   spec.ProjectID,
			Entrypoint:  spec.Entrypoint,
			Command:     spec.Command,
			Env:         spec.Env,
			GPU:         spec.GPU,
			GPUCount:    spec.GPUCount,
			Image:       spec.Image,
			Namespace:   spec.Namespace,
			TimeoutSecs: step.TimeoutSeconds,
		})
	case "agent_task":
		spec := step.AgentTask
		if spec == nil {
			spec = &AgentTaskSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.AgentTask, activities.AgentTaskInput{
			Name:        stepName(step),
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.ID,
			LogDir:      logDir,
			Engine:      activities.AgentTaskEngine(spec.Engine),
			Model:       spec.Model,
			Prompt:      spec.Prompt,
			PromptFile:  spec.PromptFile,
			WorkingDir:  spec.WorkingDir,
			Sandbox:     spec.Sandbox,
			Env:         spec.Env,
			Params:      spec.Params,
			TimeoutSecs: step.TimeoutSeconds,
		})
	case "git_op":
		spec := step.GitOp
		if spec == nil {
			spec = &GitOpSpec{}
		}
		return workflow.ExecuteActivity(ctx, activities.GitOp, activities.GitOpInput{
			Name:          stepName(step),
			WorkflowID:    info.WorkflowExecution.ID,
			RunID:         info.WorkflowExecution.RunID,
			StepID:        step.ID,
			LogDir:        logDir,
			Op:            spec.Op,
			RepoDir:       spec.RepoDir,
			Branch:        spec.Branch,
			BaseBranch:    spec.BaseBranch,
			CommitMessage: spec.CommitMessage,
			PRTitle:       spec.PRTitle,
			PRBody:        spec.PRBody,
			GitOpsScript:  spec.GitOpsScript,
			Env:           spec.Env,
			TimeoutSecs:   step.TimeoutSeconds,
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
		outputs := parseStepOutputs(result.Stdout)
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
			Outputs:        outputs,
		}, err
	}

	var result activities.RunCommandResult
	err := run.future.Get(run.ctx, &result)
	outputs := parseStepOutputs(result.Stdout)
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
		Outputs:         outputs,
	}, err
}

func parseStepOutputs(stdout string) map[string]string {
	if stdout == "" {
		return nil
	}
	outputs := map[string]string{}
	scanner := bufio.NewScanner(strings.NewReader(stdout))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		matches := outputPattern.FindStringSubmatch(line)
		if len(matches) != 3 {
			continue
		}
		outputs[matches[1]] = matches[2]
	}
	if len(outputs) == 0 {
		return nil
	}
	return outputs
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
