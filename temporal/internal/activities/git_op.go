package activities

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// GitOpInput parameterises a single git operation dispatched via git_ops.sh.
type GitOpInput struct {
	Name          string            `json:"name"`
	WorkflowID    string            `json:"workflowId"`
	RunID         string            `json:"runId"`
	StepID        string            `json:"stepId"`
	LogDir        string            `json:"logDir"`
	Op            string            `json:"op"`            // branch | commit | push | create-pr | reset | delete-branch
	RepoDir       string            `json:"repoDir"`       // repository root
	Branch        string            `json:"branch"`        // target branch name
	BaseBranch    string            `json:"baseBranch"`    // base branch for branch/pr creation
	CommitMessage string            `json:"commitMessage"` // used by commit op
	PRTitle       string            `json:"prTitle"`       // used by create-pr op
	PRBody        string            `json:"prBody"`        // used by create-pr op
	GitOpsScript  string            `json:"gitOpsScript"`  // auto-resolved if empty
	Env           map[string]string `json:"env"`
	TimeoutSecs   int               `json:"timeoutSeconds"` // default 300
}

// GitOp dispatches to tools/agentic/git_ops.sh for one of six git operations.
// It returns RunCommandResult so the pipeline can inspect exit code and stdout.
func GitOp(ctx context.Context, input GitOpInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.Op) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("git_op: op is required")
	}

	validOps := map[string]bool{
		"branch":        true,
		"commit":        true,
		"push":          true,
		"create-pr":     true,
		"reset":         true,
		"delete-branch": true,
	}
	if !validOps[input.Op] {
		return RunCommandResult{ExitCode: -1}, fmt.Errorf(
			"git_op: unsupported op %q (must be one of: branch, commit, push, create-pr, reset, delete-branch)",
			input.Op,
		)
	}

	scriptPath, err := resolveGitOpsScriptPath(input.GitOpsScript)
	if err != nil {
		return RunCommandResult{ExitCode: -1}, err
	}

	timeout := input.TimeoutSecs
	if timeout <= 0 {
		timeout = 300
	}

	args := []string{input.Op}
	if input.RepoDir != "" {
		args = append(args, "--repo-dir", input.RepoDir)
	}
	if input.Branch != "" {
		args = append(args, "--branch", input.Branch)
	}
	if input.BaseBranch != "" {
		args = append(args, "--base-branch", input.BaseBranch)
	}
	if input.CommitMessage != "" {
		args = append(args, "--commit-message", input.CommitMessage)
	}
	if input.PRTitle != "" {
		args = append(args, "--pr-title", input.PRTitle)
	}
	if input.PRBody != "" {
		args = append(args, "--pr-body", input.PRBody)
	}

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     scriptPath,
		Args:        args,
		Env:         input.Env,
		WorkingDir:  input.RepoDir,
		TimeoutSecs: timeout,
	})
}

// resolveGitOpsScriptPath finds tools/agentic/git_ops.sh relative to known locations.
func resolveGitOpsScriptPath(configuredPath string) (string, error) {
	if strings.TrimSpace(configuredPath) != "" {
		return configuredPath, nil
	}

	var candidates []string
	if home := strings.TrimSpace(os.Getenv("SYGALDRY_HOME")); home != "" {
		candidates = append(candidates, filepath.Join(home, "tools", "agentic", "git_ops.sh"))
	}
	candidates = append(candidates,
		"../tools/agentic/git_ops.sh",
		"./tools/agentic/git_ops.sh",
		"/opt/sygaldry/tools/agentic/git_ops.sh",
	)
	for _, candidate := range candidates {
		if _, statErr := os.Stat(candidate); statErr == nil {
			return candidate, nil
		}
	}
	return "", fmt.Errorf(
		"git_ops.sh not found; set git_op.git_ops_script or SYGALDRY_HOME (checked: %s)",
		strings.Join(candidates, ", "),
	)
}
