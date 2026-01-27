package main

import (
	"testing"
)

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

	// envOr treats empty as unset, so these will use fallbacks
	cfg := resolveConfig()

	if cfg.Address != "localhost:7233" {
		t.Errorf("Address = %q, want %q", cfg.Address, "localhost:7233")
	}
	if cfg.Namespace != "default" {
		t.Errorf("Namespace = %q, want %q", cfg.Namespace, "default")
	}
	if cfg.TaskQueue != "orchestration" {
		t.Errorf("TaskQueue = %q, want %q", cfg.TaskQueue, "orchestration")
	}
}

func TestResolveConfigFromEnv(t *testing.T) {
	t.Setenv("TEMPORAL_ADDRESS", "temporal.internal:7233")
	t.Setenv("TEMPORAL_NAMESPACE", "production")
	t.Setenv("TEMPORAL_TASK_QUEUE", "gpu-workers")

	cfg := resolveConfig()

	if cfg.Address != "temporal.internal:7233" {
		t.Errorf("Address = %q, want %q", cfg.Address, "temporal.internal:7233")
	}
	if cfg.Namespace != "production" {
		t.Errorf("Namespace = %q, want %q", cfg.Namespace, "production")
	}
	if cfg.TaskQueue != "gpu-workers" {
		t.Errorf("TaskQueue = %q, want %q", cfg.TaskQueue, "gpu-workers")
	}
}

func TestResolveConfigPartialOverride(t *testing.T) {
	t.Setenv("TEMPORAL_ADDRESS", "custom:7233")
	t.Setenv("TEMPORAL_NAMESPACE", "")
	t.Setenv("TEMPORAL_TASK_QUEUE", "")

	cfg := resolveConfig()

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

// ---------------------------------------------------------------------------
// workerConfig struct
// ---------------------------------------------------------------------------

func TestWorkerConfigFields(t *testing.T) {
	cfg := workerConfig{
		Address:   "a:7233",
		Namespace: "ns",
		TaskQueue: "tq",
	}
	if cfg.Address != "a:7233" || cfg.Namespace != "ns" || cfg.TaskQueue != "tq" {
		t.Errorf("workerConfig fields not correctly set: %+v", cfg)
	}
}
