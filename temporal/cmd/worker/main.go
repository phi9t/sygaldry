package main

import (
	"log"
	"os"

	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"

	"temporal-orchestration/internal/activities"
	"temporal-orchestration/internal/workflows"
)

// workerConfig holds resolved configuration for the Temporal worker.
type workerConfig struct {
	Address   string
	Namespace string
	TaskQueue string
}

// resolveConfig reads configuration from environment variables with defaults.
func resolveConfig() workerConfig {
	return workerConfig{
		Address:   envOr("TEMPORAL_ADDRESS", "localhost:7233"),
		Namespace: envOr("TEMPORAL_NAMESPACE", "default"),
		TaskQueue: envOr("TEMPORAL_TASK_QUEUE", "orchestration"),
	}
}

func main() {
	cfg := resolveConfig()

	c, err := client.Dial(client.Options{
		HostPort:  cfg.Address,
		Namespace: cfg.Namespace,
	})
	if err != nil {
		log.Fatalf("unable to create Temporal client (address=%s): %v",
			cfg.Address, err)
	}
	defer c.Close()

	w := worker.New(c, cfg.TaskQueue, worker.Options{})
	w.RegisterWorkflow(workflows.Orchestrate)
	w.RegisterWorkflow(workflows.Pipeline)
	w.RegisterActivity(activities.RunCommand)
	w.RegisterActivity(activities.DownloadFile)
	w.RegisterActivity(activities.DockerBuild)
	w.RegisterActivity(activities.DockerPush)
	w.RegisterActivity(activities.PackageBuild)
	w.RegisterActivity(activities.ContainerJob)
	w.RegisterActivity(activities.HFDownloadDataset)
	w.RegisterActivity(activities.HFDownloadModel)
	w.RegisterActivity(activities.K8sJob)
	w.RegisterActivity(activities.AgentTask)
	w.RegisterActivity(activities.GitOp)

	log.Printf("worker started on task queue %s (address=%s, namespace=%s)",
		cfg.TaskQueue, cfg.Address, cfg.Namespace)
	if err := w.Run(worker.InterruptCh()); err != nil {
		log.Fatalf("worker failed: %v", err)
	}
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
