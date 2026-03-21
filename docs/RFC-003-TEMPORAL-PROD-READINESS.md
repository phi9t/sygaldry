# RFC-003: Temporal Production Readiness

**Status:** Draft — v5 (Phases 1-3 complete)
**Date:** 2026-03-21
**Priority:** High

---

## 1. Problem

The remaining production-readiness gaps are now worker configuration and
liveness reporting.

Completed earlier phases, retained here only as evidence:

- `temporal/internal/activities/steps.go:12` now imports `"log/slog"`.
- `temporal/cmd/worker/main.go:44-46` now sets `DeadlockDetectionTimeout` and
  `WorkerStopTimeout`.
- `temporal/cmd/run/` and `temporal/internal/workflows/orchestration.go` are no
  longer present, and `temporal/cmd/worker/main.go:48-50` registers only
  `Pipeline`, `RFCImpl`, and `RFCTaskWorkflow`.

What is still missing:

### Gap 1: No config file

`temporal/cmd/worker/main.go:15-29`:
```go
type workerConfig struct {
    Address   string
    Namespace string
    TaskQueue string
}
func resolveConfig() workerConfig {
    return workerConfig{
        Address:   envOr("TEMPORAL_ADDRESS", "localhost:7233"),
        ...
    }
}
```

The worker still relies on env vars for settings such as address, namespace, and
task queue. There is no `--config` flag and no YAML config file that can live
next to deployment manifests or pipeline plans.

### Gap 2: No liveness probe

`temporal/cmd/worker/main.go:31-69` starts the worker and logs readiness, but
there is still no HTTP endpoint or readiness state export. Supervisors such as
`systemd` or K3s cannot cheaply confirm that the process is connected and ready
to execute activities.

---

## 2. Remaining Phases

### Phase 4 — Config file support

Add `--config` flag accepting a YAML file. Config precedence: file < env vars <
CLI flags.

```go
type workerConfig struct {
    Address                 string `yaml:"address"`
    Namespace               string `yaml:"namespace"`
    TaskQueue               string `yaml:"task_queue"`
    LogDir                  string `yaml:"log_dir"`
    LogMaxBytes             int    `yaml:"log_max_bytes"`
    MaxConcurrentActivities int    `yaml:"max_concurrent_activities"`
    HealthPort              int    `yaml:"health_port"`
}
```

Add a `resolveConfig(configPath string)` helper that starts from defaults, loads
YAML when present, then overlays env vars and CLI flags.

**`resolveConfig`** loads YAML first, then overlays env vars:
```go
func resolveConfig(configPath string) workerConfig {
    cfg := defaultConfig()
    if configPath != "" {
        loadYAML(configPath, &cfg)  // parse with gopkg.in/yaml.v3
    }
    overlayEnv(&cfg)  // env vars win over file
    return cfg
}
```

**Example config** (`temporal/config/worker.yaml`):
```yaml
address: "localhost:7233"
namespace: "default"
task_queue: "orchestration"
log_dir: "./logs"
log_max_bytes: 10000
max_concurrent_activities: 10
health_port: 8080
```

---

### Phase 5 — Health endpoint

Expose a simple HTTP endpoint, defaulting to `:8080`, that returns `200 OK` once
the worker is ready and `503` before initialization completes.

```go
var workerReady atomic.Bool

http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
    if workerReady.Load() {
        fmt.Fprint(w, "ok")
        return
    }
    http.Error(w, "not ready", http.StatusServiceUnavailable)
})
```

---

## 3. Files Changed

| File | Action |
|------|--------|
| `temporal/cmd/worker/main.go` | Add config file support and health endpoint |
| `temporal/go.mod` | Use `gopkg.in/yaml.v3` for config parsing |
| `temporal/config/worker.yaml` | Example worker config |

---

## 4. Verification

```bash
cd temporal
go build ./...
go run ./cmd/worker --config config/worker.yaml
go run ./cmd/worker &
curl -s http://localhost:8080/healthz
kill %1
```
