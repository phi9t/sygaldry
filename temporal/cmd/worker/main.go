package main

import (
	"log"
	"os"

	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"

	"temporal-orchestration/internal/activities"
	"temporal-orchestration/internal/workflows"
)

func main() {
	address := envOr("TEMPORAL_ADDRESS", "localhost:7233")
	namespace := envOr("TEMPORAL_NAMESPACE", "default")
	taskQueue := envOr("TEMPORAL_TASK_QUEUE", "orchestration")

	c, err := client.Dial(client.Options{HostPort: address, Namespace: namespace})
	if err != nil {
		log.Fatalf("unable to create Temporal client: %v", err)
	}
	defer c.Close()

	w := worker.New(c, taskQueue, worker.Options{})
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

	log.Printf("worker started on task queue %s", taskQueue)
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
