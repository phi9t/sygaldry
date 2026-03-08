package main

import (
	"bytes"
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
	"k8s_job":             true,
	"agent_task":          true,
	"git_op":              true,
}

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

type templateImport struct {
	Templates map[string]workflows.PipelineStep `yaml:"templates"`
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
	taskQueue := flags.String("task-queue", envOr("TEMPORAL_TASK_QUEUE", "orchestration"), "Task queue")
	address := flags.String("address", envOr("TEMPORAL_ADDRESS", "localhost:7233"), "Temporal host:port")
	namespace := flags.String("namespace", envOr("TEMPORAL_NAMESPACE", "default"), "Temporal namespace")
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

	input, err := loadPipelinePlan(*planPath)
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

	if err := validatePlan(&input); err != nil {
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

	input, err := loadPipelinePlan(*planPath)
	if err != nil {
		return err
	}
	if err := validatePlan(&input); err != nil {
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
	address := flags.String("address", envOr("TEMPORAL_ADDRESS", "localhost:7233"), "Temporal host:port")
	namespace := flags.String("namespace", envOr("TEMPORAL_NAMESPACE", "default"), "Temporal namespace")
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

func loadPipelinePlan(planPath string) (workflows.PipelineInput, error) {
	data, err := os.ReadFile(planPath)
	if err != nil {
		return workflows.PipelineInput{}, fmt.Errorf("unable to read plan file: %w", err)
	}

	var input workflows.PipelineInput
	if err := decodeYAMLStrict(data, &input); err != nil {
		return workflows.PipelineInput{}, fmt.Errorf("unable to parse plan: %w", err)
	}

	if len(input.Imports) > 0 {
		if input.Templates == nil {
			input.Templates = map[string]workflows.PipelineStep{}
		}
		for _, importPath := range input.Imports {
			resolvedPath := importPath
			if !filepath.IsAbs(resolvedPath) {
				resolvedPath = filepath.Join(filepath.Dir(planPath), importPath)
			}
			importTemplates, err := loadTemplateImport(resolvedPath)
			if err != nil {
				return workflows.PipelineInput{}, err
			}
			for name, tmpl := range importTemplates {
				if _, exists := input.Templates[name]; exists {
					return workflows.PipelineInput{}, fmt.Errorf("duplicate template name %q from import %q", name, importPath)
				}
				input.Templates[name] = tmpl
			}
		}
	}

	resolvedSteps, err := resolveStepTemplates(input.Steps, input.Templates)
	if err != nil {
		return workflows.PipelineInput{}, err
	}
	input.Steps = resolvedSteps

	if input.Params == nil {
		input.Params = map[string]string{}
	}
	if input.Env == nil {
		input.Env = map[string]string{}
	}
	return input, nil
}

func decodeYAMLStrict(data []byte, target any) error {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(target); err != nil {
		return err
	}
	return nil
}

func loadTemplateImport(path string) (map[string]workflows.PipelineStep, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("unable to read import file %q: %w", path, err)
	}

	var imported templateImport
	if err := decodeYAMLStrict(data, &imported); err != nil {
		return nil, fmt.Errorf("unable to parse import file %q: %w", path, err)
	}
	if len(imported.Templates) == 0 {
		return nil, fmt.Errorf("import file %q has no templates", path)
	}
	return imported.Templates, nil
}

func resolveStepTemplates(steps []workflows.PipelineStep, templates map[string]workflows.PipelineStep) ([]workflows.PipelineStep, error) {
	if len(steps) == 0 {
		return nil, nil
	}
	resolved := make([]workflows.PipelineStep, 0, len(steps))
	for _, step := range steps {
		if step.Template == "" {
			resolved = append(resolved, step)
			continue
		}
		templateStep, ok := templates[step.Template]
		if !ok {
			return nil, fmt.Errorf("step %q references unknown template %q", step.ID, step.Template)
		}
		if templateStep.Template != "" {
			return nil, fmt.Errorf("template %q may not reference another template", step.Template)
		}
		merged := mergePipelineStep(templateStep, step)
		merged.Template = ""
		resolved = append(resolved, merged)
	}
	return resolved, nil
}

func mergePipelineStep(base, override workflows.PipelineStep) workflows.PipelineStep {
	merged := base

	if override.ID != "" {
		merged.ID = override.ID
	}
	if override.Name != "" {
		merged.Name = override.Name
	}
	if override.Type != "" {
		merged.Type = override.Type
	}
	if override.DependsOn != nil {
		merged.DependsOn = append([]string(nil), override.DependsOn...)
	}
	if override.When != nil {
		whenCopy := *override.When
		merged.When = &whenCopy
	}
	if override.Command != "" {
		merged.Command = override.Command
	}
	if override.Args != nil {
		merged.Args = append([]string(nil), override.Args...)
	}
	if override.Env != nil {
		merged.Env = mergeStringMaps(merged.Env, override.Env)
	}
	if override.WorkingDir != "" {
		merged.WorkingDir = override.WorkingDir
	}
	if override.TimeoutSeconds > 0 {
		merged.TimeoutSeconds = override.TimeoutSeconds
	}
	if override.AllowFailure {
		merged.AllowFailure = true
	}
	if override.Retry != nil {
		merged.Retry = mergeRetrySpec(merged.Retry, override.Retry)
	}

	if override.Download != nil {
		merged.Download = mergeDownloadSpec(merged.Download, override.Download)
	}
	if override.DockerBuild != nil {
		merged.DockerBuild = mergeDockerBuildSpec(merged.DockerBuild, override.DockerBuild)
	}
	if override.DockerPush != nil {
		merged.DockerPush = mergeDockerPushSpec(merged.DockerPush, override.DockerPush)
	}
	if override.PackageBuild != nil {
		merged.PackageBuild = mergePackageBuildSpec(merged.PackageBuild, override.PackageBuild)
	}
	if override.ContainerJob != nil {
		merged.ContainerJob = mergeContainerJobSpec(merged.ContainerJob, override.ContainerJob)
	}
	if override.HFDownloadDataset != nil {
		merged.HFDownloadDataset = mergeHFDownloadDatasetSpec(merged.HFDownloadDataset, override.HFDownloadDataset)
	}
	if override.HFDownloadModel != nil {
		merged.HFDownloadModel = mergeHFDownloadModelSpec(merged.HFDownloadModel, override.HFDownloadModel)
	}
	if override.K8sJob != nil {
		merged.K8sJob = mergeK8sJobSpec(merged.K8sJob, override.K8sJob)
	}
	if override.AgentTask != nil {
		merged.AgentTask = mergeAgentTaskSpec(merged.AgentTask, override.AgentTask)
	}
	if override.GitOp != nil {
		merged.GitOp = mergeGitOpSpec(merged.GitOp, override.GitOp)
	}

	return merged
}

func mergeRetrySpec(base, override *workflows.RetrySpec) *workflows.RetrySpec {
	if base == nil {
		base = &workflows.RetrySpec{}
	}
	merged := *base
	if override.MaxAttempts > 0 {
		merged.MaxAttempts = override.MaxAttempts
	}
	if override.InitialIntervalSeconds > 0 {
		merged.InitialIntervalSeconds = override.InitialIntervalSeconds
	}
	if override.BackoffCoefficient > 0 {
		merged.BackoffCoefficient = override.BackoffCoefficient
	}
	if override.MaximumIntervalSeconds > 0 {
		merged.MaximumIntervalSeconds = override.MaximumIntervalSeconds
	}
	return &merged
}

func mergeDownloadSpec(base, override *workflows.DownloadSpec) *workflows.DownloadSpec {
	if base == nil {
		base = &workflows.DownloadSpec{}
	}
	merged := *base
	if override.URL != "" {
		merged.URL = override.URL
	}
	if override.Output != "" {
		merged.Output = override.Output
	}
	if override.Sha256 != "" {
		merged.Sha256 = override.Sha256
	}
	return &merged
}

func mergeDockerBuildSpec(base, override *workflows.DockerBuildSpec) *workflows.DockerBuildSpec {
	if base == nil {
		base = &workflows.DockerBuildSpec{}
	}
	merged := *base
	if override.Image != "" {
		merged.Image = override.Image
	}
	if override.Context != "" {
		merged.Context = override.Context
	}
	if override.Dockerfile != "" {
		merged.Dockerfile = override.Dockerfile
	}
	if override.BuildArgs != nil {
		merged.BuildArgs = mergeStringMaps(merged.BuildArgs, override.BuildArgs)
	}
	if override.Labels != nil {
		merged.Labels = mergeStringMaps(merged.Labels, override.Labels)
	}
	if override.Platform != "" {
		merged.Platform = override.Platform
	}
	if override.Target != "" {
		merged.Target = override.Target
	}
	return &merged
}

func mergeDockerPushSpec(base, override *workflows.DockerPushSpec) *workflows.DockerPushSpec {
	if base == nil {
		base = &workflows.DockerPushSpec{}
	}
	merged := *base
	if override.Image != "" {
		merged.Image = override.Image
	}
	return &merged
}

func mergePackageBuildSpec(base, override *workflows.PackageBuildSpec) *workflows.PackageBuildSpec {
	if base == nil {
		base = &workflows.PackageBuildSpec{}
	}
	merged := *base
	if override.Command != "" {
		merged.Command = override.Command
	}
	if override.Args != nil {
		merged.Args = append([]string(nil), override.Args...)
	}
	if override.Env != nil {
		merged.Env = mergeStringMaps(merged.Env, override.Env)
	}
	if override.WorkingDir != "" {
		merged.WorkingDir = override.WorkingDir
	}
	return &merged
}

func mergeContainerJobSpec(base, override *workflows.ContainerJobSpec) *workflows.ContainerJobSpec {
	if base == nil {
		base = &workflows.ContainerJobSpec{}
	}
	merged := *base
	if override.ProjectID != "" {
		merged.ProjectID = override.ProjectID
	}
	if override.Entrypoint != "" {
		merged.Entrypoint = override.Entrypoint
	}
	if override.Command != "" {
		merged.Command = override.Command
	}
	if override.Env != nil {
		merged.Env = mergeStringMaps(merged.Env, override.Env)
	}
	if override.GPU {
		merged.GPU = true
	}
	if override.LauncherPath != "" {
		merged.LauncherPath = override.LauncherPath
	}
	return &merged
}

func mergeHFDownloadDatasetSpec(base, override *workflows.HFDownloadDatasetSpec) *workflows.HFDownloadDatasetSpec {
	if base == nil {
		base = &workflows.HFDownloadDatasetSpec{}
	}
	merged := *base
	if override.DatasetID != "" {
		merged.DatasetID = override.DatasetID
	}
	if override.Config != "" {
		merged.Config = override.Config
	}
	if override.Split != "" {
		merged.Split = override.Split
	}
	if override.CacheDir != "" {
		merged.CacheDir = override.CacheDir
	}
	return &merged
}

func mergeHFDownloadModelSpec(base, override *workflows.HFDownloadModelSpec) *workflows.HFDownloadModelSpec {
	if base == nil {
		base = &workflows.HFDownloadModelSpec{}
	}
	merged := *base
	if override.ModelID != "" {
		merged.ModelID = override.ModelID
	}
	if override.CacheDir != "" {
		merged.CacheDir = override.CacheDir
	}
	return &merged
}

func mergeK8sJobSpec(base, override *workflows.K8sJobSpec) *workflows.K8sJobSpec {
	if base == nil {
		base = &workflows.K8sJobSpec{}
	}
	merged := *base
	if override.ProjectID != "" {
		merged.ProjectID = override.ProjectID
	}
	if override.Entrypoint != "" {
		merged.Entrypoint = override.Entrypoint
	}
	if override.Command != "" {
		merged.Command = override.Command
	}
	if override.Env != nil {
		merged.Env = mergeStringMaps(merged.Env, override.Env)
	}
	if override.GPU {
		merged.GPU = true
	}
	if override.GPUCount > 0 {
		merged.GPUCount = override.GPUCount
	}
	if override.Image != "" {
		merged.Image = override.Image
	}
	if override.Namespace != "" {
		merged.Namespace = override.Namespace
	}
	return &merged
}

func mergeAgentTaskSpec(base, override *workflows.AgentTaskSpec) *workflows.AgentTaskSpec {
	if base == nil {
		base = &workflows.AgentTaskSpec{}
	}
	merged := *base
	if override.Engine != "" {
		merged.Engine = override.Engine
	}
	if override.Model != "" {
		merged.Model = override.Model
	}
	if override.Prompt != "" {
		merged.Prompt = override.Prompt
	}
	if override.PromptFile != "" {
		merged.PromptFile = override.PromptFile
	}
	if override.WorkingDir != "" {
		merged.WorkingDir = override.WorkingDir
	}
	if override.Sandbox != "" {
		merged.Sandbox = override.Sandbox
	}
	if override.Env != nil {
		merged.Env = mergeStringMaps(merged.Env, override.Env)
	}
	if override.Params != nil {
		merged.Params = mergeStringMaps(merged.Params, override.Params)
	}
	return &merged
}

func mergeGitOpSpec(base, override *workflows.GitOpSpec) *workflows.GitOpSpec {
	if base == nil {
		base = &workflows.GitOpSpec{}
	}
	merged := *base
	if override.Op != "" {
		merged.Op = override.Op
	}
	if override.RepoDir != "" {
		merged.RepoDir = override.RepoDir
	}
	if override.Branch != "" {
		merged.Branch = override.Branch
	}
	if override.BaseBranch != "" {
		merged.BaseBranch = override.BaseBranch
	}
	if override.CommitMessage != "" {
		merged.CommitMessage = override.CommitMessage
	}
	if override.PRTitle != "" {
		merged.PRTitle = override.PRTitle
	}
	if override.PRBody != "" {
		merged.PRBody = override.PRBody
	}
	if override.GitOpsScript != "" {
		merged.GitOpsScript = override.GitOpsScript
	}
	if override.Env != nil {
		merged.Env = mergeStringMaps(merged.Env, override.Env)
	}
	return &merged
}

func mergeStringMaps(base map[string]string, override map[string]string) map[string]string {
	result := map[string]string{}
	for key, value := range base {
		result[key] = value
	}
	for key, value := range override {
		result[key] = value
	}
	return result
}

func validatePlan(input *workflows.PipelineInput) error {
	if len(input.Steps) == 0 {
		return fmt.Errorf("plan must have at least one step")
	}

	ids := map[string]bool{}
	for i := range input.Steps {
		step := &input.Steps[i]
		if step.ID == "" {
			return fmt.Errorf("step %d is missing id", i)
		}
		if ids[step.ID] {
			return fmt.Errorf("duplicate step id: %s", step.ID)
		}
		ids[step.ID] = true
		if step.Type == "" {
			return fmt.Errorf("step %s is missing type", step.ID)
		}
		if !allowedTypes[step.Type] {
			return fmt.Errorf("step %s has unsupported type %s", step.ID, step.Type)
		}
		if step.Name == "" {
			step.Name = step.ID
		}
		switch step.Type {
		case "command":
			if step.Command == "" {
				return fmt.Errorf("step %s command is required", step.ID)
			}
		case "download":
			if step.Download == nil || step.Download.URL == "" || step.Download.Output == "" {
				return fmt.Errorf("step %s download requires url and output", step.ID)
			}
		case "docker_build":
			if step.DockerBuild == nil || step.DockerBuild.Image == "" {
				return fmt.Errorf("step %s docker_build requires image", step.ID)
			}
		case "docker_push":
			if step.DockerPush == nil || step.DockerPush.Image == "" {
				return fmt.Errorf("step %s docker_push requires image", step.ID)
			}
		case "package_build":
			if step.PackageBuild == nil || step.PackageBuild.Command == "" {
				return fmt.Errorf("step %s package_build requires command", step.ID)
			}
		case "container_job":
			if step.ContainerJob == nil || step.ContainerJob.Command == "" {
				return fmt.Errorf("step %s container_job requires command", step.ID)
			}
		case "hf_download_dataset":
			if step.HFDownloadDataset == nil || step.HFDownloadDataset.DatasetID == "" {
				return fmt.Errorf("step %s hf_download_dataset requires dataset_id", step.ID)
			}
		case "hf_download_model":
			if step.HFDownloadModel == nil || step.HFDownloadModel.ModelID == "" {
				return fmt.Errorf("step %s hf_download_model requires model_id", step.ID)
			}
		case "k8s_job":
			if step.K8sJob == nil || step.K8sJob.Command == "" {
				return fmt.Errorf("step %s k8s_job requires command", step.ID)
			}
		case "agent_task":
			if step.AgentTask == nil {
				return fmt.Errorf("step %s agent_task requires agent_task config", step.ID)
			}
			if step.AgentTask.Engine == "" {
				return fmt.Errorf("step %s agent_task requires engine", step.ID)
			}
			if step.AgentTask.Prompt == "" && step.AgentTask.PromptFile == "" {
				return fmt.Errorf("step %s agent_task requires prompt or prompt_file", step.ID)
			}
		case "git_op":
			if step.GitOp == nil || step.GitOp.Op == "" {
				return fmt.Errorf("step %s git_op requires op", step.ID)
			}
		}
	}

	for _, step := range input.Steps {
		for _, dep := range step.DependsOn {
			if !ids[dep] {
				return fmt.Errorf("step %s depends on unknown step %s", step.ID, dep)
			}
		}
		if step.When != nil {
			if step.When.Step == "" || (step.When.Status != "success" && step.When.Status != "failure") {
				return fmt.Errorf("step %s has invalid when condition", step.ID)
			}
			if !ids[step.When.Step] {
				return fmt.Errorf("step %s when references unknown step %s", step.ID, step.When.Step)
			}
		}
	}

	if cycle := detectDependencyCycle(input.Steps); cycle != "" {
		return fmt.Errorf("dependency cycle detected: %s", cycle)
	}
	return nil
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

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
