package workflows

import (
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"

	"temporal-orchestration/internal/activities"
)

type Step struct {
	Name           string            `json:"name"`
	Command        string            `json:"command"`
	Args           []string          `json:"args"`
	Env            map[string]string `json:"env"`
	WorkingDir     string            `json:"workingDir"`
	TimeoutSeconds int               `json:"timeoutSeconds"`
	AllowFailure   bool              `json:"allowFailure"`
}

type OrchestrationInput struct {
	LogDir string `json:"logDir"`
	Steps  []Step `json:"steps"`
}

type StepResult struct {
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

type OrchestrationResult struct {
	Succeeded bool         `json:"succeeded"`
	Steps     []StepResult `json:"steps"`
}

func Orchestrate(ctx workflow.Context, input OrchestrationInput) (OrchestrationResult, error) {
	logger := workflow.GetLogger(ctx)
	info := workflow.GetInfo(ctx)
	logDir := "logs"
	if input.LogDir != "" {
		logDir = input.LogDir
	}
	results := make([]StepResult, 0, len(input.Steps))

	baseOptions := workflow.ActivityOptions{
		StartToCloseTimeout: 2 * time.Hour,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    5 * time.Second,
			BackoffCoefficient: 2.0,
			MaximumInterval:    1 * time.Minute,
			MaximumAttempts:    3,
		},
	}
	for _, step := range input.Steps {
		logger.Info("running step", "name", step.Name, "command", step.Command)
		stepTimeout := baseOptions.StartToCloseTimeout
		if step.TimeoutSeconds > 0 {
			stepTimeout = time.Duration(step.TimeoutSeconds) * time.Second
		}
		stepCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
			StartToCloseTimeout: stepTimeout,
			RetryPolicy:         baseOptions.RetryPolicy,
			ActivityID:          step.Name,
		})
		workflow.UpsertSearchAttributes(ctx, map[string]interface{}{
			"CustomStringField":  step.Name,
			"CustomKeywordField": step.Name,
		})
		activityInput := activities.RunCommandInput{
			Name:        step.Name,
			WorkflowID:  info.WorkflowExecution.ID,
			RunID:       info.WorkflowExecution.RunID,
			StepID:      step.Name,
			LogDir:      logDir,
			Command:     step.Command,
			Args:        step.Args,
			Env:         step.Env,
			WorkingDir:  step.WorkingDir,
			TimeoutSecs: step.TimeoutSeconds,
		}

		var activityResult activities.RunCommandResult
		err := workflow.ExecuteActivity(stepCtx, activities.RunCommand, activityInput).Get(stepCtx, &activityResult)
		if err != nil {
			logger.Error("step failed", "name", step.Name, "error", err)
			results = append(results, StepResult{
				Name:            step.Name,
				ExitCode:        activityResult.ExitCode,
				Stdout:          activityResult.Stdout,
				Stderr:          activityResult.Stderr,
				StdoutPath:      activityResult.StdoutPath,
				StderrPath:      activityResult.StderrPath,
				StructuredPath:  activityResult.StructuredPath,
				StdoutTruncated: activityResult.StdoutTruncated,
				StderrTruncated: activityResult.StderrTruncated,
				Succeeded:       false,
				DurationSec:     activityResult.DurationSec,
				Error:           err.Error(),
			})
			if !step.AllowFailure {
				return OrchestrationResult{Succeeded: false, Steps: results}, err
			}
			continue
		}

		results = append(results, StepResult{
			Name:            step.Name,
			ExitCode:        activityResult.ExitCode,
			Stdout:          activityResult.Stdout,
			Stderr:          activityResult.Stderr,
			StdoutPath:      activityResult.StdoutPath,
			StderrPath:      activityResult.StderrPath,
			StructuredPath:  activityResult.StructuredPath,
			StdoutTruncated: activityResult.StdoutTruncated,
			StderrTruncated: activityResult.StderrTruncated,
			Succeeded:       activityResult.ExitCode == 0,
			DurationSec:     activityResult.DurationSec,
			Error:           "",
		})

		if activityResult.ExitCode != 0 && !step.AllowFailure {
			return OrchestrationResult{Succeeded: false, Steps: results}, temporal.NewNonRetryableApplicationError("step returned non-zero exit code", "StepFailed", nil)
		}
	}

	return OrchestrationResult{Succeeded: true, Steps: results}, nil
}
