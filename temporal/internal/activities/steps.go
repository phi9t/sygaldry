package activities

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"go.temporal.io/sdk/activity"
)

type RunCommandInput struct {
	Name        string            `json:"name"`
	Command     string            `json:"command"`
	Args        []string          `json:"args"`
	Env         map[string]string `json:"env"`
	WorkingDir  string            `json:"workingDir"`
	TimeoutSecs int               `json:"timeoutSeconds"`
	WorkflowID  string            `json:"workflowId"`
	RunID       string            `json:"runId"`
	StepID      string            `json:"stepId"`
	LogDir      string            `json:"logDir"`
}

type RunCommandResult struct {
	ExitCode        int    `json:"exitCode"`
	Stdout          string `json:"stdout"`
	Stderr          string `json:"stderr"`
	DurationSec     int64  `json:"durationSec"`
	StdoutPath      string `json:"stdoutPath"`
	StderrPath      string `json:"stderrPath"`
	StructuredPath  string `json:"structuredPath"`
	StdoutTruncated bool   `json:"stdoutTruncated"`
	StderrTruncated bool   `json:"stderrTruncated"`
}

type StepEvent struct {
	Timestamp      string `json:"timestamp"`
	WorkflowID     string `json:"workflowId"`
	RunID          string `json:"runId"`
	StepID         string `json:"stepId"`
	StepName       string `json:"stepName"`
	Status         string `json:"status"`
	ExitCode       int    `json:"exitCode"`
	DurationSec    int64  `json:"durationSec"`
	StdoutPath     string `json:"stdoutPath"`
	StderrPath     string `json:"stderrPath"`
	StructuredPath string `json:"structuredPath"`
	Message        string `json:"message"`
}

type DownloadInput struct {
	Name        string `json:"name"`
	URL         string `json:"url"`
	OutputPath  string `json:"outputPath"`
	Sha256      string `json:"sha256"`
	TimeoutSecs int    `json:"timeoutSeconds"`
	WorkflowID  string `json:"workflowId"`
	RunID       string `json:"runId"`
	StepID      string `json:"stepId"`
	LogDir      string `json:"logDir"`
}

type DownloadResult struct {
	ExitCode       int    `json:"exitCode"`
	Stdout         string `json:"stdout"`
	Stderr         string `json:"stderr"`
	DurationSec    int64  `json:"durationSec"`
	StdoutPath     string `json:"stdoutPath"`
	StderrPath     string `json:"stderrPath"`
	StructuredPath string `json:"structuredPath"`
}

type DockerBuildInput struct {
	Name        string            `json:"name"`
	WorkflowID  string            `json:"workflowId"`
	RunID       string            `json:"runId"`
	StepID      string            `json:"stepId"`
	LogDir      string            `json:"logDir"`
	Image       string            `json:"image"`
	Context     string            `json:"context"`
	Dockerfile  string            `json:"dockerfile"`
	BuildArgs   map[string]string `json:"buildArgs"`
	Labels      map[string]string `json:"labels"`
	Platform    string            `json:"platform"`
	Target      string            `json:"target"`
	TimeoutSecs int               `json:"timeoutSeconds"`
}

type DockerPushInput struct {
	Name        string `json:"name"`
	WorkflowID  string `json:"workflowId"`
	RunID       string `json:"runId"`
	StepID      string `json:"stepId"`
	LogDir      string `json:"logDir"`
	Image       string `json:"image"`
	TimeoutSecs int    `json:"timeoutSeconds"`
}

type PackageBuildInput struct {
	Name        string            `json:"name"`
	WorkflowID  string            `json:"workflowId"`
	RunID       string            `json:"runId"`
	StepID      string            `json:"stepId"`
	LogDir      string            `json:"logDir"`
	Command     string            `json:"command"`
	Args        []string          `json:"args"`
	Env         map[string]string `json:"env"`
	WorkingDir  string            `json:"workingDir"`
	TimeoutSecs int               `json:"timeoutSeconds"`
}

type ContainerJobInput struct {
	Name        string            `json:"name"`
	WorkflowID  string            `json:"workflowId"`
	RunID       string            `json:"runId"`
	StepID      string            `json:"stepId"`
	LogDir      string            `json:"logDir"`
	ProjectID   string            `json:"projectId"`
	Entrypoint  string            `json:"entrypoint"`
	Command     string            `json:"command"`
	Env         map[string]string `json:"env"`
	GPU         bool              `json:"gpu"`
	TimeoutSecs int               `json:"timeoutSeconds"`
}

type HFDownloadDatasetInput struct {
	Name        string `json:"name"`
	WorkflowID  string `json:"workflowId"`
	RunID       string `json:"runId"`
	StepID      string `json:"stepId"`
	LogDir      string `json:"logDir"`
	DatasetID   string `json:"datasetId"`
	Config      string `json:"config"`
	Split       string `json:"split"`
	CacheDir    string `json:"cacheDir"`
	TimeoutSecs int    `json:"timeoutSeconds"`
}

type HFDownloadModelInput struct {
	Name        string `json:"name"`
	WorkflowID  string `json:"workflowId"`
	RunID       string `json:"runId"`
	StepID      string `json:"stepId"`
	LogDir      string `json:"logDir"`
	ModelID     string `json:"modelId"`
	CacheDir    string `json:"cacheDir"`
	TimeoutSecs int    `json:"timeoutSeconds"`
}

type K8sJobInput struct {
	Name        string            `json:"name"`
	WorkflowID  string            `json:"workflowId"`
	RunID       string            `json:"runId"`
	StepID      string            `json:"stepId"`
	LogDir      string            `json:"logDir"`
	ProjectID   string            `json:"projectId"`
	Entrypoint  string            `json:"entrypoint"`
	Command     string            `json:"command"`
	Env         map[string]string `json:"env"`
	GPU         bool              `json:"gpu"`
	GPUCount    int               `json:"gpuCount"`
	Image       string            `json:"image"`
	Namespace   string            `json:"namespace"`
	TimeoutSecs int               `json:"timeoutSeconds"`
}

func RunCommand(ctx context.Context, input RunCommandInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.Command) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("command is required")
	}

	return runCommand(ctx, input)
}

func DownloadFile(ctx context.Context, input DownloadInput) (DownloadResult, error) {
	if strings.TrimSpace(input.URL) == "" {
		return DownloadResult{ExitCode: -1}, errors.New("url is required")
	}
	if strings.TrimSpace(input.OutputPath) == "" {
		return DownloadResult{ExitCode: -1}, errors.New("outputPath is required")
	}

	timeout := 2 * time.Hour
	if input.TimeoutSecs > 0 {
		timeout = time.Duration(input.TimeoutSecs) * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	lw := setupLogWriters(&stdout, &stderr, input.LogDir, input.WorkflowID, input.RunID, input.StepID, input.Name)
	defer lw.Close()

	emitEvent(lw.logDir, StepEvent{
		Timestamp:      time.Now().UTC().Format(time.RFC3339Nano),
		WorkflowID:     input.WorkflowID,
		RunID:          input.RunID,
		StepID:         input.StepID,
		StepName:       input.Name,
		Status:         "step_started",
		StructuredPath: lw.structuredPath,
	})

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, input.URL, nil)
	if err != nil {
		return DownloadResult{ExitCode: -1}, err
	}

	heartbeatCtx, cancelHeartbeat := context.WithCancel(ctx)
	defer cancelHeartbeat()
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-heartbeatCtx.Done():
				return
			case <-ticker.C:
				activity.RecordHeartbeat(ctx, "downloading")
			}
		}
	}()

	start := time.Now()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return DownloadResult{ExitCode: -1}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return DownloadResult{ExitCode: -1}, fmt.Errorf("unexpected status code %d", resp.StatusCode)
	}

	if err := os.MkdirAll(filepath.Dir(input.OutputPath), 0o755); err != nil {
		return DownloadResult{ExitCode: -1}, err
	}

	file, err := os.Create(input.OutputPath)
	if err != nil {
		return DownloadResult{ExitCode: -1}, err
	}
	defer file.Close()

	hash := sha256.New()
	writer := io.MultiWriter(file, hash)
	if _, err := io.Copy(writer, resp.Body); err != nil {
		return DownloadResult{ExitCode: -1}, err
	}

	if input.Sha256 != "" {
		actual := hex.EncodeToString(hash.Sum(nil))
		if !strings.EqualFold(actual, input.Sha256) {
			return DownloadResult{ExitCode: -1}, fmt.Errorf("sha256 mismatch: expected %s got %s", input.Sha256, actual)
		}
	}

	duration := time.Since(start).Seconds()
	_, _ = fmt.Fprintf(lw.stdoutWriter, "downloaded %s\n", input.OutputPath)
	lw.FlushPartial()
	emitEvent(lw.logDir, StepEvent{
		Timestamp:      time.Now().UTC().Format(time.RFC3339Nano),
		WorkflowID:     input.WorkflowID,
		RunID:          input.RunID,
		StepID:         input.StepID,
		StepName:       input.Name,
		Status:         "step_finished",
		ExitCode:       0,
		DurationSec:    int64(duration),
		StdoutPath:     lw.stdoutPath,
		StderrPath:     lw.stderrPath,
		StructuredPath: lw.structuredPath,
	})
	return DownloadResult{
		ExitCode:       0,
		Stdout:         stdout.String(),
		Stderr:         stderr.String(),
		DurationSec:    int64(duration),
		StdoutPath:     lw.stdoutPath,
		StderrPath:     lw.stderrPath,
		StructuredPath: lw.structuredPath,
	}, nil
}

func DockerBuild(ctx context.Context, input DockerBuildInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.Image) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("image is required")
	}
	contextDir := input.Context
	if strings.TrimSpace(contextDir) == "" {
		contextDir = "."
	}

	args := []string{"build", "-t", input.Image}
	if input.Dockerfile != "" {
		args = append(args, "-f", input.Dockerfile)
	}
	for key, value := range input.BuildArgs {
		args = append(args, "--build-arg", key+"="+value)
	}
	for key, value := range input.Labels {
		args = append(args, "--label", key+"="+value)
	}
	if input.Platform != "" {
		args = append(args, "--platform", input.Platform)
	}
	if input.Target != "" {
		args = append(args, "--target", input.Target)
	}
	args = append(args, contextDir)

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     "docker",
		Args:        args,
		WorkingDir:  ".",
		TimeoutSecs: input.TimeoutSecs,
	})
}

func DockerPush(ctx context.Context, input DockerPushInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.Image) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("image is required")
	}

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     "docker",
		Args:        []string{"push", input.Image},
		TimeoutSecs: input.TimeoutSecs,
	})
}

func PackageBuild(ctx context.Context, input PackageBuildInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.Command) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("command is required")
	}

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     input.Command,
		Args:        input.Args,
		Env:         input.Env,
		WorkingDir:  input.WorkingDir,
		TimeoutSecs: input.TimeoutSecs,
	})
}

func ContainerJob(ctx context.Context, input ContainerJobInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.Command) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("command is required")
	}

	launcher, err := resolveContainerLauncher()
	if err != nil {
		return RunCommandResult{ExitCode: -1}, err
	}
	if launcher.usesLegacyShim {
		slog.Warn("ContainerJob: falling back to legacy launch_container.sh", "launcher", launcher.path)
	}

	entrypoint := normalizeContainerEntrypointName(input.Entrypoint)
	if entrypoint == "" {
		entrypoint = "run-job"
	}

	args := []string{"--entrypoint", entrypoint, "--", "bash", "-lc", input.Command}

	env := make(map[string]string)
	for key, value := range input.Env {
		env[key] = value
	}
	if input.ProjectID != "" {
		env["SYGALDRY_PROJECT_ID"] = input.ProjectID
	}
	if !input.GPU {
		env["SYGALDRY_GPU"] = "false"
	}

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     launcher.path,
		Args:        args,
		Env:         env,
		TimeoutSecs: input.TimeoutSecs,
	})
}

type containerLauncher struct {
	path           string
	usesLegacyShim bool
}

func resolveContainerLauncher() (containerLauncher, error) {
	return resolveContainerLauncherWith(strings.TrimSpace(os.Getenv("SYGALDRY_HOME")), exec.LookPath)
}

func resolveContainerLauncherWith(
	sygaldryHome string,
	lookPath func(string) (string, error),
) (containerLauncher, error) {
	checked := []string{}
	addChecked := func(candidate string) {
		if candidate != "" {
			checked = append(checked, candidate)
		}
	}
	check := func(candidate string, usesLegacyShim bool) (containerLauncher, bool) {
		addChecked(candidate)
		if candidate == "" {
			return containerLauncher{}, false
		}
		if _, err := os.Stat(candidate); err == nil {
			return containerLauncher{path: candidate, usesLegacyShim: usesLegacyShim}, true
		}
		return containerLauncher{}, false
	}

	if sygaldryHome != "" {
		for _, candidate := range []string{
			filepath.Join(sygaldryHome, "target", "release", "zephyr"),
			filepath.Join(sygaldryHome, "crates", "zephyr", "target", "release", "zephyr"),
		} {
			if launcher, ok := check(candidate, false); ok {
				return launcher, nil
			}
		}
	}

	if lookPath != nil {
		if candidate, err := lookPath("zephyr"); err == nil {
			addChecked(candidate)
			return containerLauncher{path: candidate}, nil
		}
		addChecked("PATH:zephyr")
	}

	candidates := []string{}
	if sygaldryHome != "" {
		candidates = append(candidates, filepath.Join(sygaldryHome, "container", "launch_container.sh"))
	}
	candidates = append(candidates,
		"../crates/zephyr/target/release/zephyr",
		"./crates/zephyr/target/release/zephyr",
		"/opt/sygaldry/crates/zephyr/target/release/zephyr",
		"../container/launch_container.sh",
		"./container/launch_container.sh",
		"/opt/sygaldry/container/launch_container.sh",
	)
	for _, candidate := range candidates {
		usesLegacyShim := strings.HasSuffix(candidate, "launch_container.sh")
		if launcher, ok := check(candidate, usesLegacyShim); ok {
			return launcher, nil
		}
	}

	return containerLauncher{}, fmt.Errorf(
		"container launcher not found; build or install zephyr, or ensure a launcher path exists (checked: %s)",
		strings.Join(checked, ", "),
	)
}

func normalizeContainerEntrypointName(name string) string {
	name = strings.TrimSpace(name)
	name = strings.TrimSuffix(name, ".sh")
	return name
}

func K8sJob(ctx context.Context, input K8sJobInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.Command) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("command is required")
	}

	namespace := input.Namespace
	if namespace == "" {
		namespace = "sygaldry"
	}
	projectID := input.ProjectID
	if projectID == "" {
		projectID = "default"
	}
	image := input.Image
	if image == "" {
		image = "sygaldry/zephyr:base"
	}
	gpuCount := input.GPUCount
	if gpuCount <= 0 {
		if input.GPU {
			gpuCount = 1
		}
	}
	entrypoint := input.Entrypoint
	if entrypoint == "" {
		entrypoint = "run-job.sh"
	}

	// Use kjob CLI to submit and monitor the job
	jobName := safeName(input.StepID)
	if jobName == "" {
		jobName = safeName(input.Name)
	}

	args := []string{
		"run",
		"--project-id", projectID,
		"--job", jobName,
		"--gpu", strconv.Itoa(gpuCount),
		"--image", image,
		"--namespace", namespace,
		"--", input.Command,
	}

	// Determine kjob path relative to SYGALDRY_HOME.
	// In container context the sygaldry repo is always mounted at /opt/sygaldry.
	sygaldryHome := os.Getenv("SYGALDRY_HOME")
	if sygaldryHome == "" {
		sygaldryHome = "/opt/sygaldry"
	}
	kjobPath := sygaldryHome + "/k3s/bin/kjob"
	if _, statErr := os.Stat(kjobPath); statErr != nil {
		return RunCommandResult{ExitCode: -1}, fmt.Errorf(
			"kjob not found at %s: set SYGALDRY_HOME to the sygaldry repo root (on host) or /opt/sygaldry (in container): %w",
			kjobPath, statErr,
		)
	}

	env := make(map[string]string)
	for key, value := range input.Env {
		env[key] = value
	}
	if projectID != "" {
		env["SYGALDRY_PROJECT_ID"] = projectID
	}
	if image != "" {
		env["SYGALDRY_IMAGE"] = image
	}
	if gpuCount > 0 {
		env["SYGALDRY_GPU_COUNT"] = strconv.Itoa(gpuCount)
	}

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     kjobPath,
		Args:        args,
		Env:         env,
		TimeoutSecs: input.TimeoutSecs,
	})
}

func HFDownloadDataset(ctx context.Context, input HFDownloadDatasetInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.DatasetID) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("datasetId is required")
	}

	config := input.Config
	if config == "" {
		config = "default"
	}
	split := input.Split
	if split == "" {
		split = "train[:100]"
	}
	cacheDir := resolveHFCacheDir(input.CacheDir)

	script := `
import importlib.util, sys
missing = [m for m in ('datasets',) if importlib.util.find_spec(m) is None]
if missing:
    sys.exit(f'hf_download_dataset: required Python package(s) not available: {", ".join(missing)}. Install via: uv pip install datasets')
import os
cache_dir = os.environ['_HF_CACHE_DIR']
dataset_id = os.environ['_HF_DATASET_ID']
config = os.environ['_HF_CONFIG']
split = os.environ['_HF_SPLIT']
os.environ['HF_HOME'] = cache_dir
from datasets import load_dataset
ds = load_dataset(dataset_id, config, split=split, cache_dir=cache_dir)
print(f'Downloaded {len(ds)} rows from {dataset_id}')
`

	env := map[string]string{
		"_HF_CACHE_DIR":  cacheDir,
		"_HF_DATASET_ID": input.DatasetID,
		"_HF_CONFIG":     config,
		"_HF_SPLIT":      split,
	}

	command, baseArgs := resolvePythonStepCommand([]string{"datasets"}, []string{"datasets"})
	args := append(baseArgs, "-c", script)

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     command,
		Args:        args,
		Env:         env,
		TimeoutSecs: input.TimeoutSecs,
	})
}

func HFDownloadModel(ctx context.Context, input HFDownloadModelInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.ModelID) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("modelId is required")
	}

	cacheDir := resolveHFCacheDir(input.CacheDir)

	script := `
import importlib.util, sys
missing = [m for m in ('huggingface_hub',) if importlib.util.find_spec(m) is None]
if missing:
    sys.exit(f'hf_download_model: required Python package(s) not available: {", ".join(missing)}. Install via: uv pip install huggingface_hub')
import os
cache_dir = os.environ['_HF_CACHE_DIR']
model_id = os.environ['_HF_MODEL_ID']
os.environ['HF_HOME'] = cache_dir
from huggingface_hub import snapshot_download
path = snapshot_download(model_id, cache_dir=cache_dir)
print(f'Downloaded {model_id} to {path}')
`

	env := map[string]string{
		"_HF_CACHE_DIR": cacheDir,
		"_HF_MODEL_ID":  input.ModelID,
	}

	command, baseArgs := resolvePythonStepCommand([]string{"huggingface_hub"}, []string{"huggingface_hub"})
	args := append(baseArgs, "-c", script)

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     command,
		Args:        args,
		Env:         env,
		TimeoutSecs: input.TimeoutSecs,
	})
}

func resolveHFCacheDir(configuredPath string) string {
	cacheDir := strings.TrimSpace(configuredPath)
	if cacheDir != "" {
		return cacheDir
	}
	cacheDir = strings.TrimSpace(os.Getenv("HF_HOME"))
	if cacheDir != "" {
		return cacheDir
	}
	return "/opt/hf_cache"
}

func resolvePythonStepCommand(requiredModules, uvDependencies []string) (string, []string) {
	allModulesAvailable := true
	for _, module := range requiredModules {
		if !pythonModuleAvailable(module) {
			allModulesAvailable = false
			break
		}
	}
	if allModulesAvailable {
		return "python3", nil
	}

	if _, err := exec.LookPath("uv"); err == nil {
		args := []string{"run"}
		for _, dep := range uvDependencies {
			args = append(args, "--with", dep)
		}
		args = append(args, "python3")
		return "uv", args
	}

	return "python3", nil
}

func pythonModuleAvailable(module string) bool {
	checkScript := "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec(sys.argv[1]) else 1)"
	cmd := exec.Command("python3", "-c", checkScript, module)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run() == nil
}

func runCommand(ctx context.Context, input RunCommandInput) (RunCommandResult, error) {
	timeout := 2 * time.Hour
	if input.TimeoutSecs > 0 {
		timeout = time.Duration(input.TimeoutSecs) * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, input.Command, input.Args...)
	if input.WorkingDir != "" {
		cmd.Dir = input.WorkingDir
	}
	if len(input.Env) > 0 {
		cmd.Env = mergedCommandEnv(input.Env)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	lw := setupLogWriters(&stdout, &stderr, input.LogDir, input.WorkflowID, input.RunID, input.StepID, input.Name)
	defer lw.Close()

	cmd.Stdout = lw.stdoutWriter
	cmd.Stderr = lw.stderrWriter

	heartbeatCtx, cancelHeartbeat := context.WithCancel(ctx)
	defer cancelHeartbeat()
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-heartbeatCtx.Done():
				return
			case <-ticker.C:
				activity.RecordHeartbeat(ctx, "running")
			}
		}
	}()

	start := time.Now()
	emitEvent(lw.logDir, StepEvent{
		Timestamp:      time.Now().UTC().Format(time.RFC3339Nano),
		WorkflowID:     input.WorkflowID,
		RunID:          input.RunID,
		StepID:         input.StepID,
		StepName:       input.Name,
		Status:         "step_started",
		StructuredPath: lw.structuredPath,
		Message:        input.Command,
	})
	err := cmd.Run()
	duration := time.Since(start).Seconds()

	lw.FlushPartial()

	result := RunCommandResult{
		ExitCode:       exitCode(err),
		Stdout:         stdout.String(),
		Stderr:         stderr.String(),
		DurationSec:    int64(duration),
		StdoutPath:     lw.stdoutPath,
		StderrPath:     lw.stderrPath,
		StructuredPath: lw.structuredPath,
	}

	if maxLogBytes > 0 {
		result.Stdout, result.StdoutTruncated = truncate(result.Stdout, maxLogBytes)
		result.Stderr, result.StderrTruncated = truncate(result.Stderr, maxLogBytes)
	}

	emitEvent(lw.logDir, StepEvent{
		Timestamp:      time.Now().UTC().Format(time.RFC3339Nano),
		WorkflowID:     input.WorkflowID,
		RunID:          input.RunID,
		StepID:         input.StepID,
		StepName:       input.Name,
		Status:         "step_finished",
		ExitCode:       result.ExitCode,
		DurationSec:    result.DurationSec,
		StdoutPath:     result.StdoutPath,
		StderrPath:     result.StderrPath,
		StructuredPath: result.StructuredPath,
	})

	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(ctx.Err(), context.Canceled) {
			return result, err
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			// Non-zero exit code: return result without error so the workflow can decide.
			return result, nil
		}
		return result, err
	}

	return result, nil
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}

func truncate(value string, maxBytes int64) (string, bool) {
	if int64(len(value)) <= maxBytes {
		return value, false
	}
	return value[:maxBytes], true
}

func safeName(value string) string {
	value = strings.TrimSpace(value)
	value = strings.ReplaceAll(value, "/", "_")
	value = strings.ReplaceAll(value, "\\", "_")
	value = strings.ReplaceAll(value, " ", "_")
	return value
}

func mergedCommandEnv(overrides map[string]string) []string {
	base := map[string]string{}
	for _, entry := range os.Environ() {
		parts := strings.SplitN(entry, "=", 2)
		if len(parts) != 2 {
			continue
		}
		base[parts[0]] = parts[1]
	}
	for key, value := range overrides {
		if value == "" {
			delete(base, key)
		} else {
			base[key] = value
		}
	}

	keys := make([]string, 0, len(base))
	for key := range base {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	merged := make([]string, 0, len(keys))
	for _, key := range keys {
		merged = append(merged, key+"="+base[key])
	}
	return merged
}

func emitEvent(logDir string, event StepEvent) {
	if logDir == "" {
		return
	}
	if !filepath.IsAbs(logDir) {
		if cwd, err := os.Getwd(); err == nil {
			logDir = filepath.Join(cwd, logDir)
		}
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		slog.Warn("emitEvent: failed to create log dir", "logDir", logDir, "error", err)
		return
	}
	path := filepath.Join(logDir, "events.jsonl")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		slog.Warn("emitEvent: failed to open event log", "path", path, "error", err)
		return
	}
	defer file.Close()

	if event.Timestamp == "" {
		event.Timestamp = time.Now().UTC().Format(time.RFC3339Nano)
	}
	data, err := json.Marshal(event)
	if err != nil {
		slog.Warn("emitEvent: failed to marshal event", "step_id", event.StepID, "error", err)
		return
	}
	if _, err := file.Write(append(data, '\n')); err != nil {
		slog.Warn("emitEvent: failed to write event", "step_id", event.StepID, "error", err)
	}
}
