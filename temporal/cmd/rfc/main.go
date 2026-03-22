package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.temporal.io/sdk/client"
	"gopkg.in/yaml.v3"

	"temporal-orchestration/internal/config"
	"temporal-orchestration/internal/workflows"
)

type rfcRunOutput struct {
	WorkflowID string                   `json:"workflowId" yaml:"workflowId"`
	RunID      string                   `json:"runId" yaml:"runId"`
	Async      bool                     `json:"async" yaml:"async"`
	Result     *workflows.RFCImplResult `json:"result,omitempty" yaml:"result,omitempty"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		slog.Error("fatal error", "error", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	flags := flag.NewFlagSet("rfc", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)

	rfcPath := flags.String("rfc", "", "Path to RFC markdown file (required)")
	repoDir := flags.String("repo-dir", "", "Repository root (default: SYGALDRY_HOME or auto-detected)")
	landingMode := flags.String("landing-mode", "direct", "Landing mode: direct|pr")
	maxParallel := flags.Int("max-parallel", 3, "Maximum parallel task workflows")
	maxRetries := flags.Int("max-retries", 3, "Maximum retries per task")
	enginesFlag := flags.String("engines", "cursor,gemini,opencode,codex", "Comma-separated executor engines")
	claudeModel := flags.String("claude-model", "claude-sonnet-4-6", "Claude model for plan/review steps")
	workflowID := flags.String("workflow-id", "", "Workflow ID (auto-generated if empty)")
	asyncMode := flags.Bool("async", false, "Return immediately without waiting for completion")
	logDir := flags.String("log-dir", "", "Override log directory")
	tempDir := flags.String("temp-dir", "", "Directory for RFC workflow temp files and worktrees (default: os temp dir)")
	address := flags.String("address", config.EnvOr("TEMPORAL_ADDRESS", config.DefaultAddress), "Temporal host:port")
	namespace := flags.String("namespace", config.EnvOr("TEMPORAL_NAMESPACE", config.DefaultNamespace), "Temporal namespace")
	taskQueue := flags.String("task-queue", config.EnvOr("TEMPORAL_TASK_QUEUE", config.DefaultTaskQueue), "Task queue")
	output := flags.String("output", "yaml", "Output format: yaml|json")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if *rfcPath == "" {
		return errors.New("-rfc is required")
	}

	// Resolve repo dir.
	resolvedRepoDir := *repoDir
	if resolvedRepoDir == "" {
		if home := os.Getenv("SYGALDRY_HOME"); home != "" {
			resolvedRepoDir = home
		} else {
			// Try to auto-detect from RFC path location.
			abs, err := filepath.Abs(*rfcPath)
			if err == nil {
				resolvedRepoDir = filepath.Dir(filepath.Dir(abs))
			}
		}
	}

	// Resolve workflow ID.
	wfID := *workflowID
	if wfID == "" {
		wfID = "rfc-impl-" + time.Now().UTC().Format("20060102-150405")
	}

	// Resolve log dir.
	resolvedLogDir := *logDir
	if resolvedLogDir == "" {
		if env := os.Getenv("TEMPORAL_LOG_DIR"); env != "" {
			resolvedLogDir = env
		} else {
			resolvedLogDir = "logs"
		}
	}
	resolvedTempDir := *tempDir
	if resolvedTempDir == "" {
		resolvedTempDir = os.TempDir()
	}

	// Parse engines.
	var engines []string
	for _, e := range strings.Split(*enginesFlag, ",") {
		e = strings.TrimSpace(e)
		if e != "" {
			engines = append(engines, e)
		}
	}

	input := workflows.RFCImplInput{
		RFCPath:           *rfcPath,
		RepoDir:           resolvedRepoDir,
		LogDir:            resolvedLogDir,
		TempDir:           resolvedTempDir,
		MaxParallelTasks:  *maxParallel,
		MaxRetriesPerTask: *maxRetries,
		LandingMode:       *landingMode,
		ExecEngines:       engines,
		ClaudeModel:       *claudeModel,
	}

	c, err := client.Dial(client.Options{HostPort: *address, Namespace: *namespace})
	if err != nil {
		return fmt.Errorf("unable to create Temporal client: %w", err)
	}
	defer c.Close()

	opts := client.StartWorkflowOptions{
		ID:        wfID,
		TaskQueue: *taskQueue,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Hour)
	defer cancel()

	we, err := c.ExecuteWorkflow(ctx, opts, workflows.RFCImpl, input)
	if err != nil {
		return fmt.Errorf("unable to start workflow: %w", err)
	}

	if *asyncMode {
		return printRFCOutput(*output, rfcRunOutput{
			WorkflowID: we.GetID(),
			RunID:      we.GetRunID(),
			Async:      true,
		})
	}

	var result workflows.RFCImplResult
	if err := we.Get(ctx, &result); err != nil {
		return fmt.Errorf("workflow failed: %w", err)
	}

	return printRFCOutput(*output, rfcRunOutput{
		WorkflowID: we.GetID(),
		RunID:      we.GetRunID(),
		Async:      false,
		Result:     &result,
	})
}

func printRFCOutput(mode string, payload any) error {
	switch mode {
	case "json":
		data, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			return fmt.Errorf("unable to serialize output: %w", err)
		}
		fmt.Println(string(data))
		return nil
	case "yaml":
		data, err := yaml.Marshal(payload)
		if err != nil {
			return fmt.Errorf("unable to serialize output: %w", err)
		}
		fmt.Print(string(data))
		return nil
	default:
		return fmt.Errorf("unsupported output format %q", mode)
	}
}

