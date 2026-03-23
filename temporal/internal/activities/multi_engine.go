package activities

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"go.temporal.io/sdk/activity"
)

// MultiEngineAgentTaskInput drives a multi-engine agent invocation with
// round-robin fallback and exponential backoff.
type MultiEngineAgentTaskInput struct {
	Name        string            `json:"name"`
	WorkflowID  string            `json:"workflowId"`
	RunID       string            `json:"runId"`
	StepID      string            `json:"stepId"`
	LogDir      string            `json:"logDir"`
	Prompt      string            `json:"prompt"`
	PromptFile  string            `json:"promptFile"`
	WorkingDir  string            `json:"workingDir"`
	Sandbox     string            `json:"sandbox"`
	Env         map[string]string `json:"env"`
	Params      map[string]string `json:"params"`
	TimeoutSecs int               `json:"timeoutSeconds"`
	// Multi-engine fields
	Engines     []AgentTaskEngine `json:"engines"`     // default: [cursor, gemini, opencode, codex]
	MaxRounds   int               `json:"maxRounds"`   // default: 3
	BackoffBase int               `json:"backoffBase"` // seconds for first inter-round sleep; default: 30
}

// DefaultExecEngines is the ordered list of engines tried by MultiEngineAgentTask
// when no explicit engine list is provided.
var DefaultExecEngines = []AgentTaskEngine{
	AgentEngineCursor,
	AgentEngineGemini,
	AgentEngineOpenCode,
	AgentEngineCodex,
}

var quotaPatterns = []string{
	"out of credits", "insufficient credits", "quota exceeded",
	"rate limit", "too many requests", "unauthorized",
	"payment required", "billing", "context length exceeded",
	"exhausted your capacity", "exhausted capacity",
}

// detectQuotaPattern returns the matched pattern (empty string if none).
func detectQuotaPattern(text string) string {
	lower := strings.ToLower(text)
	for _, p := range quotaPatterns {
		if strings.Contains(lower, p) {
			return p
		}
	}
	return ""
}

// MultiEngineAgentTask is a Temporal activity that tries multiple LLM engines
// in order, repeating for MaxRounds rounds with exponential backoff between rounds.
// All retrying is internal to this single activity — no Temporal retry policy needed.
func MultiEngineAgentTask(ctx context.Context, input MultiEngineAgentTaskInput) (RunCommandResult, error) {
	engines := input.Engines
	if len(engines) == 0 {
		engines = DefaultExecEngines
	}
	maxRounds := input.MaxRounds
	if maxRounds <= 0 {
		maxRounds = 3
	}
	backoffBase := input.BackoffBase
	if backoffBase <= 0 {
		backoffBase = 30
	}

	var lastResult RunCommandResult

	for round := 0; round < maxRounds; round++ {
		for _, engine := range engines {
			result, err := AgentTask(ctx, AgentTaskInput{
				Name:        fmt.Sprintf("%s-%s-r%d", input.Name, engine, round),
				WorkflowID:  input.WorkflowID,
				RunID:       input.RunID,
				StepID:      input.StepID,
				LogDir:      input.LogDir,
				Engine:      engine,
				Prompt:      input.Prompt,
				PromptFile:  input.PromptFile,
				WorkingDir:  input.WorkingDir,
				Sandbox:     input.Sandbox,
				Env:         input.Env,
				Params:      input.Params,
				TimeoutSecs: input.TimeoutSecs,
			})
			lastResult = result
			if err != nil {
				stderr := err.Error()
				if p := detectQuotaPattern(stderr); p != "" {
					slog.Warn("multi_engine: quota/credits issue", "engine", engine, "pattern", p)
				} else {
					slog.Warn("multi_engine: engine error", "engine", engine, "stderr", stderr)
				}
				continue
			}
			if result.ExitCode == 0 {
				return result, nil
			}
			combined := result.Stderr
			if len(combined) > 200 {
				combined = combined[:200]
			}
			if p := detectQuotaPattern(combined); p != "" {
				slog.Warn("multi_engine: quota/credits issue", "engine", engine, "pattern", p)
			} else {
				slog.Warn("multi_engine: engine failed", "engine", engine, "exitCode", result.ExitCode, "combined", combined)
			}
		}

		if round < maxRounds-1 {
			wait := backoffBase * (1 << uint(round)) // 30, 60, 120...
			slog.Info("multi_engine: all engines failed this round, sleeping", "round", round, "sleepSeconds", wait)
			select {
			case <-ctx.Done():
				return lastResult, ctx.Err()
			case <-time.After(time.Duration(wait) * time.Second):
				activity.RecordHeartbeat(ctx, fmt.Sprintf("waiting before engine round %d", round+1))
			}
		}
	}

	return lastResult, fmt.Errorf("multi_engine: all engines failed after %d rounds", maxRounds)
}
