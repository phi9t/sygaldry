package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"go.temporal.io/sdk/client"

	"temporal-orchestration/internal/workflows"
)

func main() {
	var (
		workflowID = flag.String("workflow-id", "orchestration-"+time.Now().Format("20060102-150405"), "Workflow ID")
		inputPath  = flag.String("input", "", "Path to JSON input file")
		taskQueue  = flag.String("task-queue", envOr("TEMPORAL_TASK_QUEUE", "orchestration"), "Task queue")
		address    = flag.String("address", envOr("TEMPORAL_ADDRESS", "localhost:7233"), "Temporal host:port")
		namespace  = flag.String("namespace", envOr("TEMPORAL_NAMESPACE", "default"), "Temporal namespace")
		logDir     = flag.String("log-dir", "", "Log directory for step outputs (overrides input and TEMPORAL_LOG_DIR)")
	)
	flag.Parse()

	if *inputPath == "" {
		log.Fatal("-input is required")
	}

	inputBytes, err := os.ReadFile(*inputPath)
	if err != nil {
		log.Fatalf("unable to read input file: %v", err)
	}

	var input workflows.OrchestrationInput
	if err := json.Unmarshal(inputBytes, &input); err != nil {
		log.Fatalf("unable to parse input: %v", err)
	}

	if *logDir != "" {
		input.LogDir = *logDir
	} else if input.LogDir == "" {
		if env := os.Getenv("TEMPORAL_LOG_DIR"); env != "" {
			input.LogDir = env
		}
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

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	defer cancel()

	we, err := c.ExecuteWorkflow(ctx, options, workflows.Orchestrate, input)
	if err != nil {
		log.Fatalf("unable to start workflow: %v", err)
	}

	var result workflows.OrchestrationResult
	if err := we.Get(ctx, &result); err != nil {
		log.Fatalf("workflow failed: %v", err)
	}

	output, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		log.Fatalf("unable to serialize result: %v", err)
	}

	fmt.Println(string(output))
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
