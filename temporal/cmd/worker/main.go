package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"go.temporal.io/sdk/worker"
	"gopkg.in/yaml.v3"

	cmdinternal "temporal-orchestration/cmd/internal"
	"temporal-orchestration/internal/activities"
	"temporal-orchestration/internal/config"
	"temporal-orchestration/internal/workflows"
)

// workerConfig holds resolved configuration for the Temporal worker.
type workerConfig struct {
	Address                 string `yaml:"address"`
	Namespace               string `yaml:"namespace"`
	TaskQueue               string `yaml:"task_queue"`
	MaxConcurrentActivities int    `yaml:"max_concurrent_activities"`
	HealthPort              int    `yaml:"health_port"`
}

type cliOverrides struct {
	Address                 string
	Namespace               string
	TaskQueue               string
	MaxConcurrentActivities int
	HealthPort              int
}

func defaultConfig() workerConfig {
	return workerConfig{
		Address:                 config.DefaultAddress,
		Namespace:               config.DefaultNamespace,
		TaskQueue:               config.DefaultTaskQueue,
		MaxConcurrentActivities: 10,
		HealthPort:              8080,
	}
}

// resolveConfig reads configuration from defaults, optional YAML config, env vars, and CLI overrides.
func resolveConfig(configPath string, overrides cliOverrides) (workerConfig, error) {
	cfg := defaultConfig()
	if configPath != "" {
		data, err := os.ReadFile(configPath)
		if err != nil {
			return workerConfig{}, err
		}
		decoder := yaml.NewDecoder(bytes.NewReader(data))
		decoder.KnownFields(true)
		if err := decoder.Decode(&cfg); err != nil {
			return workerConfig{}, err
		}
	}

	if value := os.Getenv("TEMPORAL_ADDRESS"); value != "" {
		cfg.Address = value
	}
	if value := os.Getenv("TEMPORAL_NAMESPACE"); value != "" {
		cfg.Namespace = value
	}
	if value := os.Getenv("TEMPORAL_TASK_QUEUE"); value != "" {
		cfg.TaskQueue = value
	}
	if value, ok, err := config.EnvOrInt("TEMPORAL_MAX_CONCURRENT_ACTIVITIES"); err != nil {
		return workerConfig{}, err
	} else if ok {
		cfg.MaxConcurrentActivities = value
	}
	if value, ok, err := config.EnvOrInt("TEMPORAL_HEALTH_PORT"); err != nil {
		return workerConfig{}, err
	} else if ok {
		cfg.HealthPort = value
	}

	if overrides.Address != "" {
		cfg.Address = overrides.Address
	}
	if overrides.Namespace != "" {
		cfg.Namespace = overrides.Namespace
	}
	if overrides.TaskQueue != "" {
		cfg.TaskQueue = overrides.TaskQueue
	}
	if overrides.MaxConcurrentActivities >= 0 {
		cfg.MaxConcurrentActivities = overrides.MaxConcurrentActivities
	}
	if overrides.HealthPort >= 0 {
		cfg.HealthPort = overrides.HealthPort
	}

	return cfg, nil
}

func validateConfig(cfg workerConfig) error {
	if cfg.Address == "" {
		return fmt.Errorf("worker config: address must not be empty")
	}
	if cfg.Namespace == "" {
		return fmt.Errorf("worker config: namespace must not be empty")
	}
	if cfg.TaskQueue == "" {
		return fmt.Errorf("worker config: task_queue must not be empty")
	}
	if cfg.MaxConcurrentActivities <= 0 {
		return fmt.Errorf("worker config: max_concurrent_activities must be > 0, got %d", cfg.MaxConcurrentActivities)
	}
	return nil
}

func main() {
	configPath := flag.String("config", "", "Path to worker YAML config file")
	address := flag.String("address", "", "Temporal frontend address")
	namespace := flag.String("namespace", "", "Temporal namespace")
	taskQueue := flag.String("task-queue", "", "Temporal worker task queue")
	maxConcurrentActivities := flag.Int("max-concurrent-activities", -1, "Max concurrent activity executions")
	healthPort := flag.Int("health-port", -1, "HTTP port for /healthz (0 disables)")
	flag.Parse()

	cfg, err := resolveConfig(*configPath, cliOverrides{
		Address:                 *address,
		Namespace:               *namespace,
		TaskQueue:               *taskQueue,
		MaxConcurrentActivities: *maxConcurrentActivities,
		HealthPort:              *healthPort,
	})
	if err != nil {
		slog.Error("unable to resolve worker config", "config", *configPath, "error", err)
		os.Exit(1)
	}
	if err := validateConfig(cfg); err != nil {
		slog.Error("invalid worker config", "error", err)
		os.Exit(1)
	}

	c, err := cmdinternal.DialClient(cfg.Address, cfg.Namespace)
	if err != nil {
		slog.Error("unable to create Temporal client", "error", err)
		os.Exit(1)
	}
	defer c.Close()

	w := worker.New(c, cfg.TaskQueue, worker.Options{
		MaxConcurrentActivityExecutionSize: cfg.MaxConcurrentActivities,
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

	var workerReady atomic.Bool
	startHealthServer(cfg.HealthPort, &workerReady)
	workerReady.Store(true)

	slog.Info(
		"worker started",
		"taskQueue", cfg.TaskQueue,
		"address", cfg.Address,
		"namespace", cfg.Namespace,
		"maxConcurrentActivities", cfg.MaxConcurrentActivities,
		"healthPort", cfg.HealthPort,
	)
	if err := w.Run(worker.InterruptCh()); err != nil {
		slog.Error("worker failed", "error", err)
		os.Exit(1)
	}
}

func startHealthServer(port int, workerReady *atomic.Bool) {
	if port <= 0 {
		return
	}

	mux := http.NewServeMux()
	mux.Handle("/healthz", healthHandler(workerReady))
	addr := fmt.Sprintf(":%d", port)
	go func() {
		slog.Info("health endpoint listening", "addr", addr)
		if err := http.ListenAndServe(addr, mux); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("health endpoint failed", "addr", addr, "error", err)
		}
	}()
}

func healthHandler(workerReady *atomic.Bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if workerReady.Load() {
			fmt.Fprint(w, "ok")
			return
		}
		http.Error(w, "not ready", http.StatusServiceUnavailable)
	})
}

