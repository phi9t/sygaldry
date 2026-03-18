# RFC-003: Temporal Production Readiness

**Status:** Draft — v3 (10-pass revision)
**Date:** 2026-03-16
**Priority:** High

---

## 1. Problem

Five concrete gaps between the current Temporal worker and a production deployment.

### Gap 1: Dead code registered in worker

`temporal/cmd/worker/main.go:44`:
```go
w.RegisterWorkflow(workflows.Orchestrate)  // dead — superseded by Pipeline
```

`temporal/internal/workflows/orchestration.go` (138 LOC) and `temporal/cmd/run/main.go` (87 LOC) define the legacy `Orchestrate` workflow and its runner. Neither is invoked by any current pipeline YAML. Both compile into the worker binary and inflate the registered workflow list.

### Gap 2: Unstructured logging

`temporal/cmd/worker/main.go:58`:
```go
log.Printf("worker started on task queue %s (address=%s, namespace=%s)", ...)
```

`temporal/internal/activities/steps.go:1-22` imports `"log"` and uses `log.Printf`/`log.Fatal` throughout. There is no structured log format, no fields, no log level control. In a multi-worker deployment, correlating activity logs to specific workflow runs requires grep-ing free text.

### Gap 3: Abrupt shutdown

`temporal/cmd/worker/main.go:60`:
```go
if err := w.Run(worker.InterruptCh()); err != nil {
```

`worker.InterruptCh()` creates a channel that closes on SIGINT/SIGTERM. `w.Run` returns immediately on signal, abandoning all in-flight activities. For ML training runs (hours), this causes silent partial execution that Temporal will retry unnecessarily.

### Gap 4: No config file

`temporal/cmd/worker/main.go:14-27`:
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

The worker accepts only three env vars. There is no `--config` flag, no YAML config file, no way to version-control worker settings alongside YAML pipeline plans.

### Gap 5: No liveness probe

The worker has no HTTP endpoint. Process supervisors (systemd, k3s) cannot determine whether the worker has connected to Temporal and is ready to execute tasks.

---

## 2. Phases

### Phase 1 — Remove dead code (do first, safest)

**Delete `temporal/cmd/run/`** (87 LOC):
```bash
git rm -r temporal/cmd/run/
```
This file imports `workflows.OrchestrationInput` and calls `workflows.Orchestrate`. Nothing in the repo invokes it.

**Delete `temporal/internal/workflows/orchestration.go`** (138 LOC):
```bash
git rm temporal/internal/workflows/orchestration.go
```
Deletes types `Step`, `OrchestrationInput`, `StepResult`, `OrchestrationResult` and function `Orchestrate`. All are only used by `cmd/run`.

**Unregister from worker** — `temporal/cmd/worker/main.go:44`:
```go
// DELETE this line:
w.RegisterWorkflow(workflows.Orchestrate)
```

**Verify**:
```bash
cd temporal && go build ./... && go test ./...
```
Expected: no compile errors, all 103 tests pass. The `workflows` import in `cmd/worker/main.go` still satisfies `workflows.Pipeline`.

---

### Phase 2 — Structured logging with `log/slog`

Zero new dependencies. `log/slog` is Go 1.21 stdlib.

**`temporal/cmd/worker/main.go`** — replace `log.Printf` with slog:

```go
// Add to imports:
import "log/slog"

func main() {
    cfg := resolveConfig()

    // Initialize structured logger based on LOG_FORMAT env var
    var handler slog.Handler
    if os.Getenv("LOG_FORMAT") == "json" {
        handler = slog.NewJSONHandler(os.Stdout, nil)
    } else {
        handler = slog.NewTextHandler(os.Stdout, nil)
    }
    slog.SetDefault(slog.New(handler))

    c, err := client.Dial(...)
    if err != nil {
        slog.Error("unable to create Temporal client", "address", cfg.Address, "err", err)
        os.Exit(1)
    }
    // ...
    slog.Info("worker started",
        "address", cfg.Address,
        "namespace", cfg.Namespace,
        "task_queue", cfg.TaskQueue,
    )
    // ...
}
```

**`temporal/internal/activities/steps.go`** — thread context fields into every log:

`RunCommandInput` already carries `WorkflowID`, `RunID`, `StepID` (lines 31-33). Use them:
```go
// At top of RunCommand():
logger := slog.With(
    "workflow_id", input.WorkflowID,
    "run_id",      input.RunID,
    "step_id",     input.StepID,
)
logger.Info("activity started", "command", input.Command)
// ...
logger.Info("activity completed", "exit_code", result.ExitCode, "duration_sec", result.DurationSec)
```

Replace all remaining `log.Printf` / `log.Fatal` calls in activities with `slog` equivalents.

**Structured output** (when `LOG_FORMAT=json`):
```json
{"time":"...","level":"INFO","msg":"worker started","address":"localhost:7233","namespace":"default","task_queue":"orchestration"}
{"time":"...","level":"INFO","msg":"activity started","workflow_id":"wf-abc","run_id":"run-xyz","step_id":"train","command":"python train.py"}
```

---

### Phase 3 — Graceful shutdown

Replace `temporal/cmd/worker/main.go:60` abrupt shutdown:

```go
// BEFORE:
if err := w.Run(worker.InterruptCh()); err != nil {
    log.Fatalf("worker failed: %v", err)
}

// AFTER:
sigCh := make(chan os.Signal, 1)
signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

go func() {
    sig := <-sigCh
    slog.Info("shutdown signal received, draining activities", "signal", sig.String())
    w.Stop()
}()

if err := w.Run(nil); err != nil {
    slog.Error("worker exited with error", "err", err)
    os.Exit(1)
}
slog.Info("worker shutdown complete")
```

Add `"os/signal"` and `"syscall"` to imports.

Bounded concurrency (add to `worker.Options{}`):
```go
w := worker.New(c, cfg.TaskQueue, worker.Options{
    MaxConcurrentActivityExecutionSize: cfg.MaxConcurrentActivities, // default 10
})
```

Add `MaxConcurrentActivities int` to `workerConfig` with default 10.

---

### Phase 4 — Config file support

Add `--config` flag accepting a YAML file. Config precedence: file < env vars < CLI flags.

**New struct fields** in `workerConfig`:
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

**Flag**:
```go
configPath := flag.String("config", "", "Path to YAML config file")
flag.Parse()
cfg := resolveConfig(*configPath)
```

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

Simple HTTP server on `TEMPORAL_HEALTH_PORT` (default 8080).

```go
var workerReady atomic.Bool

go func() {
    http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
        if workerReady.Load() {
            fmt.Fprint(w, "ok")
        } else {
            http.Error(w, "not ready", http.StatusServiceUnavailable)
        }
    })
    if cfg.HealthPort > 0 {
        addr := fmt.Sprintf(":%d", cfg.HealthPort)
        slog.Info("health endpoint listening", "addr", addr)
        _ = http.ListenAndServe(addr, nil)
    }
}()

// After worker.New() and before w.Run():
workerReady.Store(true)
slog.Info("worker ready")
```

Set `health_port: 0` to disable. Default: 8080.

---

## 3. Files Changed

| File | Action |
|------|--------|
| `temporal/cmd/run/` | Deleted |
| `temporal/internal/workflows/orchestration.go` | Deleted |
| `temporal/cmd/worker/main.go` | slog, graceful shutdown, config file flag, health endpoint |
| `temporal/internal/activities/steps.go` | Replace `log` with `slog`, thread workflow/run/step IDs |
| `temporal/go.mod` | Add `gopkg.in/yaml.v3` for Phase 4 |
| `temporal/config/worker.yaml` | New example config |

---

## 4. Verification

```bash
cd temporal

# Phase 1 — dead code removal
go build ./...
go test ./...         # all 103 tests must pass

# Phase 2 — structured logging
LOG_FORMAT=json TEMPORAL_ADDRESS=localhost:7233 go run ./cmd/worker &
# First line must be JSON: {"level":"INFO","msg":"worker started",...}
kill %1

# Phase 3 — graceful shutdown
go run ./cmd/worker &
sleep 2 && kill -TERM $!
# Must log: "shutdown signal received, draining activities"
# Must log: "worker shutdown complete"

# Phase 4 — config file
go run ./cmd/worker --config config/worker.yaml

# Phase 5 — health endpoint
go run ./cmd/worker &
curl -s http://localhost:8080/healthz    # → "ok"
kill %1
```

---

## 5. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| `orchestration.go` types referenced elsewhere | Low | `go build ./...` will catch compile errors immediately |
| slog changes log format consumed by log parsers | Low | JSON only when `LOG_FORMAT=json`; default is text |
| Graceful drain never completes | Medium | `MaxConcurrentActivities` bounds in-flight count; Temporal heartbeat timeout is backstop |
| yaml.v3 new dependency | Low | Standard library choice; already in many Go projects |
