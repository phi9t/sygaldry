package workflows

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"

	"temporal-orchestration/internal/activities"
)

// ── Input / Output Types ─────────────────────────────────────────────────────

// RFCImplInput parameterises the parent RFC implementation workflow.
type RFCImplInput struct {
	RFCPath           string            `json:"rfcPath"`
	RepoDir           string            `json:"repoDir"`
	LogDir            string            `json:"logDir"`
	MaxParallelTasks  int               `json:"maxParallelTasks"`  // 0 = use task count
	MaxRetriesPerTask int               `json:"maxRetriesPerTask"` // default 3
	LandingMode       string            `json:"landingMode"`       // "direct" | "pr"
	BaseBranch        string            `json:"baseBranch"`        // default "main"
	ExecEngines       []string          `json:"execEngines"`       // default [cursor,gemini,opencode,codex]
	ClaudeModel       string            `json:"claudeModel"`
	GitOpsScript      string            `json:"gitOpsScript"`
	Env               map[string]string `json:"env"`
}

// RFCTaskSpec is one concrete task produced by the RFC decompose step.
type RFCTaskSpec struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	FilesHint   []string `json:"filesHint"`
	Priority    int      `json:"priority"`
}

// RFCTaskInput drives a single RFC task child workflow.
type RFCTaskInput struct {
	Task         RFCTaskSpec                  `json:"task"`
	RFCPath      string                       `json:"rfcPath"`
	RepoDir      string                       `json:"repoDir"`
	LogDir       string                       `json:"logDir"`
	WorktreePath string                       `json:"worktreePath"`
	BranchName   string                       `json:"branchName"`
	BaseBranch   string                       `json:"baseBranch"`
	LandingMode  string                       `json:"landingMode"`
	MaxRetries   int                          `json:"maxRetries"`
	ExecEngines  []activities.AgentTaskEngine `json:"execEngines"`
	ClaudeModel  string                       `json:"claudeModel"`
	GitOpsScript string                       `json:"gitOpsScript"`
	Env          map[string]string            `json:"env"`
}

// RFCTaskResult summarises the outcome of a single task child workflow.
type RFCTaskResult struct {
	TaskID     string `json:"taskId"`
	Title      string `json:"title"`
	Succeeded  bool   `json:"succeeded"`
	Retries    int    `json:"retries"`
	CommitSHA  string `json:"commitSha,omitempty"`
	PRUrl      string `json:"prUrl,omitempty"`
	FailReason string `json:"failReason,omitempty"`
}

// RFCImplResult summarises the outcome of the full RFC implementation run.
type RFCImplResult struct {
	Succeeded   bool            `json:"succeeded"`
	TaskResults []RFCTaskResult `json:"taskResults"`
}

// ── Parent Workflow ──────────────────────────────────────────────────────────

// RFCImpl decomposes an RFC into tasks and executes them in parallel child workflows.
func RFCImpl(ctx workflow.Context, input RFCImplInput) (RFCImplResult, error) {
	logger := workflow.GetLogger(ctx)

	// Apply defaults.
	if input.MaxRetriesPerTask <= 0 {
		input.MaxRetriesPerTask = 3
	}
	if input.BaseBranch == "" {
		input.BaseBranch = "main"
	}
	if input.LandingMode == "" {
		input.LandingMode = "direct"
	}

	info := workflow.GetInfo(ctx)
	workflowID := info.WorkflowExecution.ID
	runID := info.WorkflowExecution.RunID

	// Activity options for the decompose + read steps.
	shortAO := workflow.ActivityOptions{
		StartToCloseTimeout: 30 * time.Minute,
		RetryPolicy:         &temporal.RetryPolicy{MaximumAttempts: 1},
	}
	actCtx := workflow.WithActivityOptions(ctx, shortAO)

	// Step 1: Decompose RFC → tasks.json
	tasksFile := fmt.Sprintf("/tmp/rfc-impl-%s-tasks.json", rfcSafeID(workflowID))
	var decomposeResult activities.RunCommandResult
	err := workflow.ExecuteActivity(actCtx, activities.AgentTask, activities.AgentTaskInput{
		Name:       "rfc-decompose",
		WorkflowID: workflowID,
		RunID:      runID,
		StepID:     "decompose",
		LogDir:     input.LogDir,
		Engine:     activities.AgentEngineClaude,
		Model:      input.ClaudeModel,
		PromptFile: "tools/agentic/prompts/rfc_decompose.md",
		WorkingDir: input.RepoDir,
		Params: map[string]string{
			"rfc_path":   input.RFCPath,
			"tasks_file": tasksFile,
		},
		Env: input.Env,
	}).Get(ctx, &decomposeResult)
	if err != nil {
		return RFCImplResult{}, fmt.Errorf("rfc_impl: decompose activity failed: %w", err)
	}
	if decomposeResult.ExitCode != 0 {
		return RFCImplResult{Succeeded: false}, fmt.Errorf(
			"rfc_impl: decompose failed (exit %d): %s", decomposeResult.ExitCode, decomposeResult.Stderr)
	}

	// Use tasks_file from set-output if provided; fall back to computed path.
	if out := extractSetOutput(decomposeResult.Stdout, "tasks_file"); out != "" {
		tasksFile = out
	}

	// Step 2: Read tasks JSON.
	var tasksJSON string
	err = workflow.ExecuteActivity(actCtx, activities.ReadJSONFile, tasksFile).Get(ctx, &tasksJSON)
	if err != nil {
		return RFCImplResult{}, fmt.Errorf("rfc_impl: read tasks file failed: %w", err)
	}

	// Step 3: Unmarshal tasks — deterministic JSON parsing is safe in a workflow.
	var tasks []RFCTaskSpec
	if err := json.Unmarshal([]byte(tasksJSON), &tasks); err != nil {
		return RFCImplResult{}, fmt.Errorf("rfc_impl: invalid tasks JSON: %w", err)
	}
	if len(tasks) == 0 {
		return RFCImplResult{}, errors.New("rfc_impl: decompose returned 0 tasks")
	}
	if len(tasks) > 10 {
		return RFCImplResult{}, fmt.Errorf("rfc_impl: decompose returned %d tasks (max 10)", len(tasks))
	}
	logger.Info("RFC decomposed", "taskCount", len(tasks))

	// Step 4: Fan-out with bounded parallelism.
	maxParallel := input.MaxParallelTasks
	if maxParallel <= 0 || maxParallel > len(tasks) {
		maxParallel = len(tasks)
	}

	execEngines := toAgentTaskEngines(input.ExecEngines)

	sema := workflow.NewBufferedChannel(ctx, maxParallel)
	for i := 0; i < maxParallel; i++ {
		sema.Send(ctx, struct{}{})
	}
	resultCh := workflow.NewBufferedChannel(ctx, len(tasks))

	for _, t := range tasks {
		task := t // capture loop variable
		var token struct{}
		sema.Receive(ctx, &token)

		workflow.Go(ctx, func(ctx workflow.Context) {
			defer func() { sema.Send(ctx, token) }()

			taskInput := RFCTaskInput{
				Task:         task,
				RFCPath:      input.RFCPath,
				RepoDir:      input.RepoDir,
				LogDir:       input.LogDir,
				WorktreePath: fmt.Sprintf("/tmp/rfc-impl-%s/%s", rfcSafeID(workflowID), task.ID),
				BranchName:   fmt.Sprintf("rfc-impl-%s-%s", rfcSafeID(workflowID), task.ID),
				BaseBranch:   input.BaseBranch,
				LandingMode:  input.LandingMode,
				MaxRetries:   input.MaxRetriesPerTask,
				ExecEngines:  execEngines,
				ClaudeModel:  input.ClaudeModel,
				GitOpsScript: input.GitOpsScript,
				Env:          input.Env,
			}
			cwo := workflow.ChildWorkflowOptions{
				WorkflowID: fmt.Sprintf("%s-task-%s", workflowID, task.ID),
			}
			childCtx := workflow.WithChildOptions(ctx, cwo)

			var taskResult RFCTaskResult
			if err := workflow.ExecuteChildWorkflow(childCtx, RFCTaskWorkflow, taskInput).Get(ctx, &taskResult); err != nil {
				taskResult = RFCTaskResult{
					TaskID:     task.ID,
					Title:      task.Title,
					Succeeded:  false,
					FailReason: fmt.Sprintf("child workflow error: %v", err),
				}
			}
			resultCh.Send(ctx, taskResult)
		})
	}

	// Collect all results.
	allResults := make([]RFCTaskResult, 0, len(tasks))
	for i := 0; i < len(tasks); i++ {
		var r RFCTaskResult
		resultCh.Receive(ctx, &r)
		allResults = append(allResults, r)
	}

	allSucceeded := true
	for _, r := range allResults {
		if !r.Succeeded {
			allSucceeded = false
			break
		}
	}
	return RFCImplResult{Succeeded: allSucceeded, TaskResults: allResults}, nil
}

// ── Child Workflow ───────────────────────────────────────────────────────────

// RFCTaskWorkflow implements the plan→execute→review loop for a single task.
func RFCTaskWorkflow(ctx workflow.Context, input RFCTaskInput) (RFCTaskResult, error) {
	logger := workflow.GetLogger(ctx)
	info := workflow.GetInfo(ctx)
	workflowID := info.WorkflowExecution.ID

	result := RFCTaskResult{TaskID: input.Task.ID, Title: input.Task.Title}

	noRetry := &temporal.RetryPolicy{MaximumAttempts: 1}

	gitAO := workflow.ActivityOptions{StartToCloseTimeout: 5 * time.Minute, RetryPolicy: noRetry}
	planAO := workflow.ActivityOptions{StartToCloseTimeout: 30 * time.Minute, RetryPolicy: noRetry}
	execAO := workflow.ActivityOptions{StartToCloseTimeout: 2 * time.Hour, RetryPolicy: noRetry}
	reviewAO := workflow.ActivityOptions{StartToCloseTimeout: 30 * time.Minute, RetryPolicy: noRetry}
	validateAO := workflow.ActivityOptions{StartToCloseTimeout: 15 * time.Minute, RetryPolicy: noRetry}
	landAO := workflow.ActivityOptions{StartToCloseTimeout: 10 * time.Minute, RetryPolicy: noRetry}

	// cleanup removes the worktree; errors are ignored.
	cleanup := func() {
		cleanCtx := workflow.WithActivityOptions(ctx, gitAO)
		_ = workflow.ExecuteActivity(cleanCtx, activities.GitOp, activities.GitOpInput{
			Name:         fmt.Sprintf("worktree-remove-%s", input.Task.ID),
			WorkflowID:   workflowID,
			StepID:       "worktree-remove",
			LogDir:       input.LogDir,
			Op:           "worktree-remove",
			RepoDir:      input.RepoDir,
			Branch:       input.BranchName,
			WorktreePath: input.WorktreePath,
			GitOpsScript: input.GitOpsScript,
			Env:          input.Env,
		}).Get(ctx, nil)
	}

	// 1. Add worktree.
	gitCtx := workflow.WithActivityOptions(ctx, gitAO)
	var worktreeResult activities.RunCommandResult
	if err := workflow.ExecuteActivity(gitCtx, activities.GitOp, activities.GitOpInput{
		Name:         fmt.Sprintf("worktree-add-%s", input.Task.ID),
		WorkflowID:   workflowID,
		StepID:       "worktree-add",
		LogDir:       input.LogDir,
		Op:           "worktree-add",
		RepoDir:      input.RepoDir,
		Branch:       input.BranchName,
		BaseBranch:   input.BaseBranch,
		WorktreePath: input.WorktreePath,
		GitOpsScript: input.GitOpsScript,
		Env:          input.Env,
	}).Get(ctx, &worktreeResult); err != nil || worktreeResult.ExitCode != 0 {
		result.FailReason = "worktree setup failed"
		return result, nil
	}

	// 2. Plan → Execute → Review loop.
	maxRetries := input.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 3
	}
	engines := input.ExecEngines
	if len(engines) == 0 {
		engines = []activities.AgentTaskEngine{
			activities.AgentEngineCursor,
			activities.AgentEngineGemini,
			activities.AgentEngineOpenCode,
			activities.AgentEngineCodex,
		}
	}

	var prevReviewFailure string

	for attempt := 0; attempt < maxRetries; attempt++ {
		logger.Info("RFCTask attempt", "task", input.Task.ID, "attempt", attempt)

		// a. Plan
		planFile := fmt.Sprintf("/tmp/rfc-task-%s-%s-a%d.yaml", rfcSafeID(workflowID), input.Task.ID, attempt)
		planCtx := workflow.WithActivityOptions(ctx, planAO)
		var planResult activities.RunCommandResult
		if err := workflow.ExecuteActivity(planCtx, activities.AgentTask, activities.AgentTaskInput{
			Name:       fmt.Sprintf("plan-%s-a%d", input.Task.ID, attempt),
			WorkflowID: workflowID,
			StepID:     fmt.Sprintf("plan-a%d", attempt),
			LogDir:     input.LogDir,
			Engine:     activities.AgentEngineClaude,
			Model:      input.ClaudeModel,
			PromptFile: filepath.Join(input.RepoDir, "tools/agentic/prompts/rfc_task_plan.md"),
			WorkingDir: input.WorktreePath,
			Params: map[string]string{
				"task_id":                 input.Task.ID,
				"task_title":              input.Task.Title,
				"task_description":        input.Task.Description,
				"files_hint":              strings.Join(input.Task.FilesHint, ", "),
				"plan_file":               planFile,
				"attempt_number":          fmt.Sprintf("%d", attempt),
				"previous_review_failure": prevReviewFailure,
				"rfc_path":                input.RFCPath,
			},
			Env: input.Env,
		}).Get(ctx, &planResult); err != nil || planResult.ExitCode != 0 {
			result.FailReason = fmt.Sprintf("planning failed at attempt %d", attempt)
			result.Retries = attempt
			cleanup()
			return result, nil
		}
		if out := extractSetOutput(planResult.Stdout, "plan_file"); out != "" {
			planFile = out
		}

		// b. Execute
		execCtx := workflow.WithActivityOptions(ctx, execAO)
		var execResult activities.RunCommandResult
		if err := workflow.ExecuteActivity(execCtx, activities.MultiEngineAgentTask, activities.MultiEngineAgentTaskInput{
			Name:       fmt.Sprintf("execute-%s-a%d", input.Task.ID, attempt),
			WorkflowID: workflowID,
			StepID:     fmt.Sprintf("execute-a%d", attempt),
			LogDir:     input.LogDir,
			PromptFile: filepath.Join(input.RepoDir, "tools/agentic/prompts/rfc_task_execute.md"),
			WorkingDir: input.WorktreePath,
			Params: map[string]string{
				"task_title":    input.Task.Title,
				"worktree_path": input.WorktreePath,
				"plan_file":     planFile,
			},
			Engines: engines,
			Env:     input.Env,
		}).Get(ctx, &execResult); err != nil || execResult.ExitCode != 0 {
			result.FailReason = "all engines failed"
			result.Retries = attempt
			cleanup()
			return result, nil
		}

		// c. Review
		reviewCtx := workflow.WithActivityOptions(ctx, reviewAO)
		var reviewResult activities.RunCommandResult
		_ = workflow.ExecuteActivity(reviewCtx, activities.AgentTask, activities.AgentTaskInput{
			Name:       fmt.Sprintf("review-%s-a%d", input.Task.ID, attempt),
			WorkflowID: workflowID,
			StepID:     fmt.Sprintf("review-a%d", attempt),
			LogDir:     input.LogDir,
			Engine:     activities.AgentEngineClaude,
			Model:      input.ClaudeModel,
			PromptFile: filepath.Join(input.RepoDir, "tools/agentic/prompts/rfc_task_review.md"),
			WorkingDir: input.WorktreePath,
			Params: map[string]string{
				"task_id":          input.Task.ID,
				"task_title":       input.Task.Title,
				"task_description": input.Task.Description,
				"worktree_path":    input.WorktreePath,
				"plan_file":        planFile,
				"base_branch":      input.BaseBranch,
			},
			Env: input.Env,
		}).Get(ctx, &reviewResult)

		if extractSetOutput(reviewResult.Stdout, "review_passed") == "true" {
			result.Succeeded = true
			result.Retries = attempt
			break
		}
		prevReviewFailure = extractSetOutput(reviewResult.Stdout, "review_failure")
		if attempt == maxRetries-1 {
			result.FailReason = fmt.Sprintf("review failed after %d attempts: %s", maxRetries, prevReviewFailure)
			result.Retries = attempt
		}
	}

	if !result.Succeeded {
		cleanup()
		return result, nil
	}

	// 3. Validate
	validateCtx := workflow.WithActivityOptions(ctx, validateAO)
	var validateResult activities.RunCommandResult
	_ = workflow.ExecuteActivity(validateCtx, activities.RunCommand, activities.RunCommandInput{
		Name:       fmt.Sprintf("validate-%s", input.Task.ID),
		WorkflowID: workflowID,
		StepID:     "validate",
		LogDir:     input.LogDir,
		Command:    "./validate_all.sh",
		Args:       []string{"--quick"},
		WorkingDir: input.WorktreePath,
		Env:        input.Env,
	}).Get(ctx, &validateResult)

	if validateResult.ExitCode != 0 {
		stderr := validateResult.Stderr
		if len(stderr) > 500 {
			stderr = stderr[:500]
		}
		result.Succeeded = false
		result.FailReason = fmt.Sprintf("validation failed: %s", stderr)
		cleanup()
		return result, nil
	}

	// 4. Commit
	commitCtx := workflow.WithActivityOptions(ctx, gitAO)
	var commitResult activities.RunCommandResult
	_ = workflow.ExecuteActivity(commitCtx, activities.GitOp, activities.GitOpInput{
		Name:          fmt.Sprintf("commit-%s", input.Task.ID),
		WorkflowID:    workflowID,
		StepID:        "commit",
		LogDir:        input.LogDir,
		Op:            "worktree-commit",
		RepoDir:       input.RepoDir,
		Branch:        input.BranchName,
		CommitMessage: fmt.Sprintf("rfc-impl: %s", input.Task.Title),
		WorktreePath:  input.WorktreePath,
		GitOpsScript:  input.GitOpsScript,
		Env:           input.Env,
	}).Get(ctx, &commitResult)

	if commitResult.ExitCode != 0 {
		result.Succeeded = false
		result.FailReason = "commit failed: no changes to commit"
		cleanup()
		return result, nil
	}
	result.CommitSHA = extractSetOutput(commitResult.Stdout, "commit_sha")

	// 5. Land
	landCtx := workflow.WithActivityOptions(ctx, landAO)
	if input.LandingMode == "direct" {
		var landResult activities.RunCommandResult
		_ = workflow.ExecuteActivity(landCtx, activities.GitOp, activities.GitOpInput{
			Name:         fmt.Sprintf("land-%s", input.Task.ID),
			WorkflowID:   workflowID,
			StepID:       "land",
			LogDir:       input.LogDir,
			Op:           "worktree-land",
			RepoDir:      input.RepoDir,
			Branch:       input.BranchName,
			BaseBranch:   input.BaseBranch,
			WorktreePath: input.WorktreePath,
			GitOpsScript: input.GitOpsScript,
			Env:          input.Env,
		}).Get(ctx, &landResult)
		if landResult.ExitCode != 0 {
			result.Succeeded = false
			result.FailReason = "land failed"
			cleanup()
			return result, nil
		}
	} else {
		var pushResult activities.RunCommandResult
		_ = workflow.ExecuteActivity(landCtx, activities.GitOp, activities.GitOpInput{
			Name:         fmt.Sprintf("push-%s", input.Task.ID),
			WorkflowID:   workflowID,
			StepID:       "push",
			LogDir:       input.LogDir,
			Op:           "push",
			RepoDir:      input.RepoDir,
			Branch:       input.BranchName,
			GitOpsScript: input.GitOpsScript,
			Env:          input.Env,
		}).Get(ctx, &pushResult)
		if pushResult.ExitCode != 0 {
			result.Succeeded = false
			result.FailReason = "push failed"
			cleanup()
			return result, nil
		}
		var prResult activities.RunCommandResult
		_ = workflow.ExecuteActivity(landCtx, activities.GitOp, activities.GitOpInput{
			Name:         fmt.Sprintf("pr-%s", input.Task.ID),
			WorkflowID:   workflowID,
			StepID:       "create-pr",
			LogDir:       input.LogDir,
			Op:           "create-pr",
			RepoDir:      input.RepoDir,
			Branch:       input.BranchName,
			BaseBranch:   input.BaseBranch,
			PRTitle:      fmt.Sprintf("rfc-impl: %s", input.Task.Title),
			PRBody:       fmt.Sprintf("RFC implementation: %s\n\n%s", input.Task.Title, input.Task.Description),
			GitOpsScript: input.GitOpsScript,
			Env:          input.Env,
		}).Get(ctx, &prResult)
		result.PRUrl = extractSetOutput(prResult.Stdout, "pr_url")
	}

	// 6. Cleanup worktree.
	cleanup()
	return result, nil
}

// ── Helpers ──────────────────────────────────────────────────────────────────

// extractSetOutput parses ::set-output name=key::value from stdout.
// Returns empty string if key not found.
func extractSetOutput(stdout, key string) string {
	prefix := "::set-output name=" + key + "::"
	for _, line := range strings.Split(stdout, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

// rfcSafeID converts a workflow ID into a filesystem-safe string.
func rfcSafeID(id string) string {
	r := strings.NewReplacer("/", "_", "\\", "_", " ", "_", ":", "_", "\t", "_")
	return r.Replace(strings.TrimSpace(id))
}

// toAgentTaskEngines converts a []string to []activities.AgentTaskEngine.
func toAgentTaskEngines(ss []string) []activities.AgentTaskEngine {
	if len(ss) == 0 {
		return nil
	}
	result := make([]activities.AgentTaskEngine, len(ss))
	for i, s := range ss {
		result[i] = activities.AgentTaskEngine(s)
	}
	return result
}
