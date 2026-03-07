package activities

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
)

// AgentTaskEngine identifies the CLI tool used to run an agent task.
type AgentTaskEngine string

const (
	AgentEngineClaude AgentTaskEngine = "claude"
	AgentEngineCodex  AgentTaskEngine = "codex"
	AgentEngineCursor AgentTaskEngine = "cursor"
	AgentEngineEcho   AgentTaskEngine = "echo" // no-op engine for dry-run/integration testing
)

// AgentTaskInput parameterises a single agent invocation.
type AgentTaskInput struct {
	Name        string            `json:"name"`
	WorkflowID  string            `json:"workflowId"`
	RunID       string            `json:"runId"`
	StepID      string            `json:"stepId"`
	LogDir      string            `json:"logDir"`
	Engine      AgentTaskEngine   `json:"engine"`
	Model       string            `json:"model"`
	Prompt      string            `json:"prompt"`
	PromptFile  string            `json:"promptFile"`
	WorkingDir  string            `json:"workingDir"`
	Sandbox     string            `json:"sandbox"` // codex-only; default "workspace-write"
	Env         map[string]string `json:"env"`
	Params      map[string]string `json:"params"`      // substituted into prompt as ${{ params.KEY }}
	TimeoutSecs int               `json:"timeoutSeconds"`
}

// AgentTask invokes claude, codex, cursor, or echo as a Temporal activity.
// It reuses runCommand() and returns RunCommandResult so the pipeline can
// treat it identically to any other command step.
func AgentTask(ctx context.Context, input AgentTaskInput) (RunCommandResult, error) {
	// Resolve prompt text.
	prompt := input.Prompt
	if input.PromptFile != "" {
		data, err := os.ReadFile(input.PromptFile)
		if err != nil {
			return RunCommandResult{ExitCode: -1}, fmt.Errorf("agent_task: reading prompt_file %q: %w", input.PromptFile, err)
		}
		prompt = string(data)
	}
	if strings.TrimSpace(prompt) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("agent_task: prompt or prompt_file is required")
	}

	// Substitute ${{ params.KEY }} tokens in the prompt text.
	// The pipeline template engine only expands struct fields; file contents are
	// expanded here so prompt files can reference pipeline params inline.
	if len(input.Params) > 0 {
		pairs := make([]string, 0, len(input.Params)*4)
		for k, v := range input.Params {
			pairs = append(pairs, "${{ params."+k+" }}", v)
			pairs = append(pairs, "${{params."+k+"}}", v)
		}
		prompt = strings.NewReplacer(pairs...).Replace(prompt)
	}

	// Build the subprocess env: merge Env with SAIL_PARAM_* vars for each param,
	// so agent subprocesses can also read params from the environment.
	mergedEnv := make(map[string]string, len(input.Env)+len(input.Params))
	for k, v := range input.Env {
		mergedEnv[k] = v
	}
	for k, v := range input.Params {
		mergedEnv["SAIL_PARAM_"+strings.ToUpper(k)] = v
	}

	engine := input.Engine
	if engine == "" {
		engine = AgentEngineClaude
	}

	var command string
	var args []string

	switch engine {
	case AgentEngineClaude:
		// claude -p "<prompt>" [--model <model>]
		command = "claude"
		args = []string{"-p", prompt}
		if input.Model != "" {
			args = append(args, "--model", input.Model)
		}

	case AgentEngineCodex:
		// codex exec --full-auto --json [-m <model>] [-s <sandbox>] [-C <workdir>] "<prompt>"
		command = "codex"
		sandbox := input.Sandbox
		if sandbox == "" {
			sandbox = "workspace-write"
		}
		args = []string{"exec", "--full-auto", "--json", "-s", sandbox}
		if input.Model != "" {
			args = append(args, "-m", input.Model)
		}
		if input.WorkingDir != "" {
			args = append(args, "-C", input.WorkingDir)
		}
		args = append(args, prompt)

	case AgentEngineCursor:
		// cursor --exec [--model <model>] "<prompt>"
		command = "cursor"
		args = []string{"--exec"}
		if input.Model != "" {
			args = append(args, "--model", input.Model)
		}
		args = append(args, prompt)

	case AgentEngineEcho:
		// echo "<prompt>" — exercises the full pipeline without burning LLM tokens
		command = "echo"
		args = []string{prompt}

	default:
		return RunCommandResult{ExitCode: -1}, fmt.Errorf(
			"agent_task: unsupported engine %q (must be claude, codex, cursor, or echo)", engine,
		)
	}

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     command,
		Args:        args,
		Env:         mergedEnv,
		WorkingDir:  input.WorkingDir,
		TimeoutSecs: input.TimeoutSecs,
	})
}
