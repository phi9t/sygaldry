package main

import (
	"log/slog"
	"os"
	"time"

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
		slog.Error("unable to create Temporal client", "address", cfg.Address, "error", err)
		os.Exit(1)
	}
	defer c.Close()

	w := worker.New(c, cfg.TaskQueue, worker.Options{
		DeadlockDetectionTimeout: 5 * time.Second,
		WorkerStopTimeout:        30 * time.Second,
	})
	w.RegisterWorkflow(workflows.Pipeline)
	w.RegisterWorkflow(workflows.RFCImpl)
	w.RegisterWorkflow(workflows.RFCTaskWorkflow)
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
	w.RegisterActivity(activities.MultiEngineAgentTask)
	w.RegisterActivity(activities.ReadJSONFile)

	slog.Info("worker started", "taskQueue", cfg.TaskQueue, "address", cfg.Address, "namespace", cfg.Namespace)
	if err := w.Run(worker.InterruptCh()); err != nil {
		slog.Error("worker failed", "error", err)
		os.Exit(1)
	}
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
