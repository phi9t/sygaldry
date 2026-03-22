package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/sdk/client"
	"gopkg.in/yaml.v3"

	"temporal-orchestration/internal/config"
	"temporal-orchestration/internal/plan"
	"temporal-orchestration/internal/workflows"
)

type stringMapFlag map[string]string

func (f *stringMapFlag) String() string {
	if f == nil {
		return ""
	}
	keys := make([]string, 0, len(*f))
	for k := range *f {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf("%s=%s", key, (*f)[key]))
	}
	return strings.Join(parts, ",")
}

func (f *stringMapFlag) Set(value string) error {
	parts := strings.SplitN(value, "=", 2)
	if len(parts) != 2 {
		return fmt.Errorf("invalid -set value %q, expected key=value", value)
	}
	key := strings.TrimSpace(parts[0])
	if key == "" {
		return fmt.Errorf("invalid -set value %q, key is empty", value)
	}
	if *f == nil {
		*f = map[string]string{}
	}
	(*f)[key] = parts[1]
	return nil
}

type runOutput struct {
	WorkflowID string                    `json:"workflowId" yaml:"workflowId"`
	RunID      string                    `json:"runId" yaml:"runId"`
	Async      bool                      `json:"async" yaml:"async"`
	Result     *workflows.PipelineResult `json:"result,omitempty" yaml:"result,omitempty"`
}

type statusOutput struct {
	WorkflowID    string `json:"workflowId" yaml:"workflowId"`
	RunID         string `json:"runId" yaml:"runId"`
	Status        string `json:"status" yaml:"status"`
	TaskQueue     string `json:"taskQueue,omitempty" yaml:"taskQueue,omitempty"`
	StartTime     string `json:"startTime,omitempty" yaml:"startTime,omitempty"`
	ExecutionTime string `json:"executionTime,omitempty" yaml:"executionTime,omitempty"`
	CloseTime     string `json:"closeTime,omitempty" yaml:"closeTime,omitempty"`
	HistoryLength int64  `json:"historyLength" yaml:"historyLength"`
}

type planManifest struct {
	WorkflowID string             `json:"workflowId"`
	RunID      string             `json:"runId"`
	LogDir     string             `json:"logDir"`
	CreatedAt  string             `json:"createdAt"`
	Steps      []planManifestStep `json:"steps"`
}

type planManifestStep struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Type      string          `json:"type"`
	DependsOn []string        `json:"dependsOn,omitempty"`
	When      *workflows.When `json:"when,omitempty"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		log.Fatal(err)
	}
}

func run(args []string) error {
	subcommand, rest := parseSubcommand(args)
	switch subcommand {
	case "run":
		return runCommand(rest)
	case "validate":
		return validateCommand(rest)
	case "status":
		return statusCommand(rest)
	default:
		return fmt.Errorf("unknown subcommand %q", subcommand)
	}
}

func parseSubcommand(args []string) (string, []string) {
	if len(args) == 0 {
		return "run", args
	}
	candidate := args[0]
	switch candidate {
	case "run", "validate", "status":
		return candidate, args[1:]
	default:
		return "run", args
	}
}

func runCommand(args []string) error {
	flags := flag.NewFlagSet("run", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)

	workflowID := flags.String("workflow-id", "pipeline-"+time.Now().Format("20060102-150405"), "Workflow ID")
	planPath := flags.String("plan", "", "Path to YAML plan")
	taskQueue := flags.String("task-queue", config.EnvOr("TEMPORAL_TASK_QUEUE", config.DefaultTaskQueue), "Task queue")
	address := flags.String("address", config.EnvOr("TEMPORAL_ADDRESS", config.DefaultAddress), "Temporal host:port")
	namespace := flags.String("namespace", config.EnvOr("TEMPORAL_NAMESPACE", config.DefaultNamespace), "Temporal namespace")
	logDir := flags.String("log-dir", "", "Log directory for step outputs (overrides plan and TEMPORAL_LOG_DIR)")
	async := flags.Bool("async", false, "Start workflow and return immediately")
	output := flags.String("output", "yaml", "Output format: yaml|json")

	var setValues stringMapFlag
	flags.Var(&setValues, "set", "Override plan param (repeatable): -set key=value")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if *planPath == "" {
		return errors.New("-plan is required")
	}

	input, err := plan.Load(*planPath)
	if err != nil {
		return err
	}
	if input.Params == nil {
		input.Params = map[string]string{}
	}
	for key, value := range setValues {
		input.Params[key] = value
	}

	if *logDir != "" {
		input.LogDir = *logDir
	} else if input.LogDir == "" {
		if env := os.Getenv("TEMPORAL_LOG_DIR"); env != "" {
			input.LogDir = env
		}
	}

	if err := plan.Validate(&input); err != nil {
		return fmt.Errorf("plan validation failed: %w", err)
	}

	c, err := client.Dial(client.Options{HostPort: *address, Namespace: *namespace})
	if err != nil {
		return fmt.Errorf("unable to create Temporal client: %w", err)
	}
	defer c.Close()

	options := client.StartWorkflowOptions{
		ID:        *workflowID,
		TaskQueue: *taskQueue,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Hour)
	defer cancel()

	we, err := c.ExecuteWorkflow(ctx, options, workflows.Pipeline, input)
	if err != nil {
		return fmt.Errorf("unable to start workflow: %w", err)
	}

	runID := we.GetRunID()
	manifestLogDir := input.LogDir
	if manifestLogDir == "" {
		manifestLogDir = "logs"
	}
	if err := writePlanManifest(manifestLogDir, we.GetID(), runID, input.Steps); err != nil {
		log.Printf("warning: unable to write run manifest: %v", err)
	}

	if *async {
		return printOutput(*output, runOutput{
			WorkflowID: we.GetID(),
			RunID:      runID,
			Async:      true,
		})
	}

	var result workflows.PipelineResult
	if err := we.Get(ctx, &result); err != nil {
		return fmt.Errorf("workflow failed: %w", err)
	}

	return printOutput(*output, runOutput{
		WorkflowID: we.GetID(),
		RunID:      runID,
		Async:      false,
		Result:     &result,
	})
}

func validateCommand(args []string) error {
	flags := flag.NewFlagSet("validate", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)

	planPath := flags.String("plan", "", "Path to YAML plan")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *planPath == "" {
		return errors.New("-plan is required")
	}

	input, err := plan.Load(*planPath)
	if err != nil {
		return err
	}
	if err := plan.Validate(&input); err != nil {
		return fmt.Errorf("plan validation failed: %w", err)
	}

	types := map[string]bool{}
	for _, step := range input.Steps {
		types[step.Type] = true
	}
	typeList := make([]string, 0, len(types))
	for typ := range types {
		typeList = append(typeList, typ)
	}
	sort.Strings(typeList)
	fmt.Printf("Plan OK: %d steps, types: %v\n", len(input.Steps), typeList)
	return nil
}

func statusCommand(args []string) error {
	flags := flag.NewFlagSet("status", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)

	workflowID := flags.String("workflow-id", "", "Workflow ID")
	runID := flags.String("run-id", "", "Run ID (optional)")
	address := flags.String("address", config.EnvOr("TEMPORAL_ADDRESS", config.DefaultAddress), "Temporal host:port")
	namespace := flags.String("namespace", config.EnvOr("TEMPORAL_NAMESPACE", config.DefaultNamespace), "Temporal namespace")
	output := flags.String("output", "yaml", "Output format: yaml|json")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *workflowID == "" {
		return errors.New("-workflow-id is required")
	}

	c, err := client.Dial(client.Options{HostPort: *address, Namespace: *namespace})
	if err != nil {
		return fmt.Errorf("unable to create Temporal client: %w", err)
	}
	defer c.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	resp, err := c.DescribeWorkflowExecution(ctx, *workflowID, *runID)
	if err != nil {
		return fmt.Errorf("unable to describe workflow: %w", err)
	}

	info := resp.WorkflowExecutionInfo
	status := info.GetStatus().String()
	if info.GetStatus() == enumspb.WORKFLOW_EXECUTION_STATUS_UNSPECIFIED {
		status = "UNSPECIFIED"
	}

	out := statusOutput{
		WorkflowID:    info.GetExecution().GetWorkflowId(),
		RunID:         info.GetExecution().GetRunId(),
		Status:        status,
		TaskQueue:     info.GetTaskQueue(),
		HistoryLength: info.GetHistoryLength(),
	}
	if ts := info.GetStartTime(); ts != nil {
		out.StartTime = ts.AsTime().UTC().Format(time.RFC3339)
	}
	if ts := info.GetExecutionTime(); ts != nil {
		out.ExecutionTime = ts.AsTime().UTC().Format(time.RFC3339)
	}
	if ts := info.GetCloseTime(); ts != nil {
		out.CloseTime = ts.AsTime().UTC().Format(time.RFC3339)
	}
	return printOutput(*output, out)
}

func printOutput(mode string, payload any) error {
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

func writePlanManifest(logDir, workflowID, runID string, steps []workflows.PipelineStep) error {
	if logDir == "" {
		logDir = "logs"
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return err
	}

	manifest := planManifest{
		WorkflowID: workflowID,
		RunID:      runID,
		LogDir:     logDir,
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
		Steps:      make([]planManifestStep, 0, len(steps)),
	}
	for _, step := range steps {
		manifest.Steps = append(manifest.Steps, planManifestStep{
			ID:        step.ID,
			Name:      step.Name,
			Type:      step.Type,
			DependsOn: append([]string(nil), step.DependsOn...),
			When:      step.When,
		})
	}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}

	filename := fmt.Sprintf("%s_%s_plan.json", safeFilename(workflowID), safeFilename(runID))
	return os.WriteFile(filepath.Join(logDir, filename), data, 0o644)
}

func safeFilename(value string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", " ", "_", ":", "_", "\t", "_")
	return replacer.Replace(strings.TrimSpace(value))
}

