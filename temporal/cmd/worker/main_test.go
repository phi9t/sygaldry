package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func noCLIOverrides() cliOverrides {
	return cliOverrides{
		MaxConcurrentActivities: -1,
		HealthPort:              -1,
	}
}

// ---------------------------------------------------------------------------
// envOr
// ---------------------------------------------------------------------------

func TestEnvOr(t *testing.T) {
	tests := []struct {
		name     string
		key      string
		envValue string
		fallback string
		want     string
	}{
		{"uses fallback when unset", "TEST_ENVOR_UNSET_KEY_XYZ", "", "fallback", "fallback"},
		{"uses env when set", "TEST_ENVOR_SET_KEY", "from_env", "fallback", "from_env"},
		{"fallback for empty string", "TEST_ENVOR_EMPTY_KEY", "", "default", "default"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.envValue != "" {
				t.Setenv(tt.key, tt.envValue)
			}
			if got := envOr(tt.key, tt.fallback); got != tt.want {
				t.Errorf("envOr(%q, %q) = %q, want %q", tt.key, tt.fallback, got, tt.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// resolveConfig defaults
// ---------------------------------------------------------------------------

func TestResolveConfigDefaults(t *testing.T) {
	// Clear any env vars that might be set
	t.Setenv("TEMPORAL_ADDRESS", "")
	t.Setenv("TEMPORAL_NAMESPACE", "")
	t.Setenv("TEMPORAL_TASK_QUEUE", "")
	t.Setenv("TEMPORAL_MAX_CONCURRENT_ACTIVITIES", "")
	t.Setenv("TEMPORAL_HEALTH_PORT", "")

	cfg, err := resolveConfig("", noCLIOverrides())
	if err != nil {
		t.Fatalf("resolveConfig() error = %v", err)
	}

	if cfg.Address != "localhost:7233" {
		t.Errorf("Address = %q, want %q", cfg.Address, "localhost:7233")
	}
	if cfg.Namespace != "default" {
		t.Errorf("Namespace = %q, want %q", cfg.Namespace, "default")
	}
	if cfg.TaskQueue != "orchestration" {
		t.Errorf("TaskQueue = %q, want %q", cfg.TaskQueue, "orchestration")
	}
	if cfg.MaxConcurrentActivities != 10 {
		t.Errorf("MaxConcurrentActivities = %d, want 10", cfg.MaxConcurrentActivities)
	}
	if cfg.HealthPort != 8080 {
		t.Errorf("HealthPort = %d, want 8080", cfg.HealthPort)
	}
}

func TestResolveConfigFromEnv(t *testing.T) {
	t.Setenv("TEMPORAL_ADDRESS", "temporal.internal:7233")
	t.Setenv("TEMPORAL_NAMESPACE", "production")
	t.Setenv("TEMPORAL_TASK_QUEUE", "gpu-workers")
	t.Setenv("TEMPORAL_MAX_CONCURRENT_ACTIVITIES", "17")
	t.Setenv("TEMPORAL_HEALTH_PORT", "9090")

	cfg, err := resolveConfig("", noCLIOverrides())
	if err != nil {
		t.Fatalf("resolveConfig() error = %v", err)
	}

	if cfg.Address != "temporal.internal:7233" {
		t.Errorf("Address = %q, want %q", cfg.Address, "temporal.internal:7233")
	}
	if cfg.Namespace != "production" {
		t.Errorf("Namespace = %q, want %q", cfg.Namespace, "production")
	}
	if cfg.TaskQueue != "gpu-workers" {
		t.Errorf("TaskQueue = %q, want %q", cfg.TaskQueue, "gpu-workers")
	}
	if cfg.MaxConcurrentActivities != 17 {
		t.Errorf("MaxConcurrentActivities = %d, want 17", cfg.MaxConcurrentActivities)
	}
	if cfg.HealthPort != 9090 {
		t.Errorf("HealthPort = %d, want 9090", cfg.HealthPort)
	}
}

func TestResolveConfigPartialOverride(t *testing.T) {
	t.Setenv("TEMPORAL_ADDRESS", "custom:7233")
	t.Setenv("TEMPORAL_NAMESPACE", "")
	t.Setenv("TEMPORAL_TASK_QUEUE", "")
	t.Setenv("TEMPORAL_MAX_CONCURRENT_ACTIVITIES", "")
	t.Setenv("TEMPORAL_HEALTH_PORT", "")

	cfg, err := resolveConfig("", noCLIOverrides())
	if err != nil {
		t.Fatalf("resolveConfig() error = %v", err)
	}

	if cfg.Address != "custom:7233" {
		t.Errorf("Address = %q, want override", cfg.Address)
	}
	if cfg.Namespace != "default" {
		t.Errorf("Namespace = %q, want default fallback", cfg.Namespace)
	}
	if cfg.TaskQueue != "orchestration" {
		t.Errorf("TaskQueue = %q, want default fallback", cfg.TaskQueue)
	}
}

func TestResolveConfigFromFile(t *testing.T) {
	// Clear env vars that would override file values.
	for _, key := range []string{"TEMPORAL_ADDRESS", "TEMPORAL_NAMESPACE", "TEMPORAL_TASK_QUEUE", "TEMPORAL_MAX_CONCURRENT_ACTIVITIES", "TEMPORAL_HEALTH_PORT"} {
		t.Setenv(key, "")
	}

	configPath := filepath.Join(t.TempDir(), "worker.yaml")
	if err := os.WriteFile(configPath, []byte(
		"address: temporal.prod:7233\nnamespace: workers\ntask_queue: gpu\nmax_concurrent_activities: 5\nhealth_port: 7070\n",
	), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	cfg, err := resolveConfig(configPath, noCLIOverrides())
	if err != nil {
		t.Fatalf("resolveConfig() error = %v", err)
	}

	if cfg.Address != "temporal.prod:7233" || cfg.Namespace != "workers" || cfg.TaskQueue != "gpu" {
		t.Fatalf("unexpected file config: %+v", cfg)
	}
	if cfg.MaxConcurrentActivities != 5 || cfg.HealthPort != 7070 {
		t.Fatalf("unexpected numeric file config: %+v", cfg)
	}
}

func TestResolveConfigEnvOverridesFile(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "worker.yaml")
	if err := os.WriteFile(configPath, []byte(
		"address: temporal.prod:7233\nnamespace: workers\ntask_queue: gpu\nmax_concurrent_activities: 5\nhealth_port: 7070\n",
	), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	t.Setenv("TEMPORAL_ADDRESS", "override:7233")
	t.Setenv("TEMPORAL_HEALTH_PORT", "9999")

	cfg, err := resolveConfig(configPath, noCLIOverrides())
	if err != nil {
		t.Fatalf("resolveConfig() error = %v", err)
	}

	if cfg.Address != "override:7233" {
		t.Fatalf("Address = %q, want env override", cfg.Address)
	}
	if cfg.HealthPort != 9999 {
		t.Fatalf("HealthPort = %d, want env override", cfg.HealthPort)
	}
}

func TestResolveConfigCLIOverridesEnv(t *testing.T) {
	t.Setenv("TEMPORAL_ADDRESS", "env:7233")
	t.Setenv("TEMPORAL_HEALTH_PORT", "9090")

	cfg, err := resolveConfig("", cliOverrides{
		Address:    "cli:7233",
		MaxConcurrentActivities: -1,
		HealthPort: 6060,
	})
	if err != nil {
		t.Fatalf("resolveConfig() error = %v", err)
	}

	if cfg.Address != "cli:7233" {
		t.Fatalf("Address = %q, want cli override", cfg.Address)
	}
	if cfg.HealthPort != 6060 {
		t.Fatalf("HealthPort = %d, want cli override", cfg.HealthPort)
	}
}

func TestResolveConfigRejectsInvalidIntEnv(t *testing.T) {
	t.Setenv("TEMPORAL_HEALTH_PORT", "not-an-int")
	if _, err := resolveConfig("", noCLIOverrides()); err == nil {
		t.Fatal("resolveConfig() error = nil, want invalid integer error")
	}
}

func TestHealthHandlerNotReady(t *testing.T) {
	var ready atomic.Bool
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()

	healthHandler(&ready).ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
}

func TestHealthHandlerReady(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()

	healthHandler(&ready).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if rec.Body.String() != "ok" {
		t.Fatalf("body = %q, want %q", rec.Body.String(), "ok")
	}
}

// ---------------------------------------------------------------------------
// workerConfig struct
// ---------------------------------------------------------------------------

func TestWorkerConfigFields(t *testing.T) {
	cfg := workerConfig{
		Address:                 "a:7233",
		Namespace:               "ns",
		TaskQueue:               "tq",
		MaxConcurrentActivities: 4,
		HealthPort:              8080,
	}
	if cfg.Address != "a:7233" || cfg.Namespace != "ns" || cfg.TaskQueue != "tq" {
		t.Errorf("workerConfig fields not correctly set: %+v", cfg)
	}
	if cfg.MaxConcurrentActivities != 4 || cfg.HealthPort != 8080 {
		t.Errorf("workerConfig numeric fields not correctly set: %+v", cfg)
	}
}

func TestStartHealthServerZeroPort(t *testing.T) {
	// port <= 0 → function returns immediately (no listener started)
	var ready atomic.Bool
	startHealthServer(0, &ready)
	startHealthServer(-1, &ready)
}
