package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

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
}

func main() {
	var (
		workflowID = flag.String("workflow-id", "pipeline-"+time.Now().Format("20060102-150405"), "Workflow ID")
		planPath   = flag.String("plan", "", "Path to YAML plan")
		taskQueue  = flag.String("task-queue", envOr("TEMPORAL_TASK_QUEUE", "orchestration"), "Task queue")
		address    = flag.String("address", envOr("TEMPORAL_ADDRESS", "localhost:7233"), "Temporal host:port")
		namespace  = flag.String("namespace", envOr("TEMPORAL_NAMESPACE", "default"), "Temporal namespace")
		logDir     = flag.String("log-dir", "", "Log directory for step outputs (overrides plan and TEMPORAL_LOG_DIR)")
	)
	flag.Parse()

	if *planPath == "" {
		log.Fatal("-plan is required")
	}

	inputBytes, err := os.ReadFile(*planPath)
	if err != nil {
		log.Fatalf("unable to read plan file: %v", err)
	}

	var input workflows.PipelineInput
	if err := yaml.Unmarshal(inputBytes, &input); err != nil {
		log.Fatalf("unable to parse plan: %v", err)
	}

	if *logDir != "" {
		input.LogDir = *logDir
	} else if input.LogDir == "" {
		if env := os.Getenv("TEMPORAL_LOG_DIR"); env != "" {
			input.LogDir = env
		}
	}

	if err := validatePlan(&input); err != nil {
		log.Fatalf("plan validation failed: %v", err)
	}

	c, err := client.Dial(client.Options{HostPort: *address, Namespace: *namespace})
	if err != nil {
		log.Fatalf("unable to create Temporal client: %v", err)
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
		log.Fatalf("unable to start workflow: %v", err)
	}

	var result workflows.PipelineResult
	if err := we.Get(ctx, &result); err != nil {
		log.Fatalf("workflow failed: %v", err)
	}

	output, err := yaml.Marshal(result)
	if err != nil {
		log.Fatalf("unable to serialize result: %v", err)
	}

	fmt.Println(string(output))
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

	return nil
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
