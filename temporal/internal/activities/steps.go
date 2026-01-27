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
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
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

type structuredLogLine struct {
	Timestamp  string `json:"timestamp"`
	WorkflowID string `json:"workflowId"`
	RunID      string `json:"runId"`
	StepID     string `json:"stepId"`
	StepName   string `json:"stepName"`
	Stream     string `json:"stream"`
	Message    string `json:"message"`
	Partial    bool   `json:"partial"`
}

type structuredLogSink struct {
	file       *os.File
	workflowID string
	runID      string
	stepID     string
	stepName   string
	mu         sync.Mutex
}

func (s *structuredLogSink) write(stream, message string, partial bool) {
	if s == nil || s.file == nil {
		return
	}
	line := structuredLogLine{
		Timestamp:  time.Now().UTC().Format(time.RFC3339Nano),
		WorkflowID: s.workflowID,
		RunID:      s.runID,
		StepID:     s.stepID,
		StepName:   s.stepName,
		Stream:     stream,
		Message:    message,
		Partial:    partial,
	}
	data, err := json.Marshal(line)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.file.Write(append(data, '\n'))
}

type lineBufferWriter struct {
	sink   *structuredLogSink
	stream string
	buf    bytes.Buffer
}

func (w *lineBufferWriter) Write(p []byte) (int, error) {
	n := len(p)
	for len(p) > 0 {
		idx := bytes.IndexByte(p, '\n')
		if idx < 0 {
			_, _ = w.buf.Write(p)
			return n, nil
		}
		_, _ = w.buf.Write(p[:idx])
		line := strings.TrimSuffix(w.buf.String(), "\r")
		w.buf.Reset()
		w.sink.write(w.stream, line, false)
		p = p[idx+1:]
	}
	return n, nil
}

func (w *lineBufferWriter) FlushPartial() {
	if w.buf.Len() == 0 {
		return
	}
	line := strings.TrimSuffix(w.buf.String(), "\r")
	w.buf.Reset()
	w.sink.write(w.stream, line, true)
}

type logWriters struct {
	logDir                  string
	stdoutWriter            io.Writer
	stderrWriter            io.Writer
	stdoutPath              string
	stderrPath              string
	structuredPath          string
	stdoutStructuredWriter  *lineBufferWriter
	stderrStructuredWriter  *lineBufferWriter
	closers                 []io.Closer
}

func (lw *logWriters) Close() {
	for _, c := range lw.closers {
		c.Close()
	}
}

func (lw *logWriters) FlushPartial() {
	if lw.stdoutStructuredWriter != nil {
		lw.stdoutStructuredWriter.FlushPartial()
	}
	if lw.stderrStructuredWriter != nil {
		lw.stderrStructuredWriter.FlushPartial()
	}
}

func setupLogWriters(stdout, stderr *bytes.Buffer, logDirHint, workflowID, runID, stepID, name string) *logWriters {
	lw := &logWriters{
		stdoutWriter: stdout,
		stderrWriter: stderr,
	}

	logDir := strings.TrimSpace(logDirHint)
	if logDir == "" {
		logDir = os.Getenv("TEMPORAL_LOG_DIR")
	}
	if logDir == "" {
		logDir = "./logs"
	}
	if !filepath.IsAbs(logDir) {
		if cwd, cwdErr := os.Getwd(); cwdErr == nil {
			logDir = filepath.Join(cwd, logDir)
		}
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		logDir = "/tmp/temporal-logs"
		_ = os.MkdirAll(logDir, 0o755)
	}
	lw.logDir = logDir

	prefix := safeName(workflowID)
	if runID != "" {
		prefix += "_" + safeName(runID)
	}
	if stepID != "" {
		prefix += "_" + safeName(stepID)
	} else if name != "" {
		prefix += "_" + safeName(name)
	}
	if prefix == "" {
		prefix = "step"
	}

	lw.stdoutPath = filepath.Join(logDir, prefix+"_stdout.log")
	lw.stderrPath = filepath.Join(logDir, prefix+"_stderr.log")

	if file, err := os.Create(lw.stdoutPath); err == nil {
		lw.closers = append(lw.closers, file)
		lw.stdoutWriter = io.MultiWriter(lw.stdoutWriter, file)
	} else {
		stderr.WriteString(fmt.Sprintf("log write failed (stdout): %v\n", err))
	}
	if file, err := os.Create(lw.stderrPath); err == nil {
		lw.closers = append(lw.closers, file)
		lw.stderrWriter = io.MultiWriter(lw.stderrWriter, file)
	} else {
		stderr.WriteString(fmt.Sprintf("log write failed (stderr): %v\n", err))
	}

	structuredCandidate := filepath.Join(logDir, prefix+"_structured.jsonl")
	if file, err := os.Create(structuredCandidate); err == nil {
		lw.closers = append(lw.closers, file)
		lw.structuredPath = structuredCandidate
		sink := &structuredLogSink{
			file:       file,
			workflowID: workflowID,
			runID:      runID,
			stepID:     stepID,
			stepName:   name,
		}
		lw.stdoutStructuredWriter = &lineBufferWriter{sink: sink, stream: "stdout"}
		lw.stderrStructuredWriter = &lineBufferWriter{sink: sink, stream: "stderr"}
		lw.stdoutWriter = io.MultiWriter(lw.stdoutWriter, lw.stdoutStructuredWriter)
		lw.stderrWriter = io.MultiWriter(lw.stderrWriter, lw.stderrStructuredWriter)
	} else {
		stderr.WriteString(fmt.Sprintf("log write failed (structured): %v\n", err))
	}

	return lw
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
	Name         string            `json:"name"`
	WorkflowID   string            `json:"workflowId"`
	RunID        string            `json:"runId"`
	StepID       string            `json:"stepId"`
	LogDir       string            `json:"logDir"`
	ProjectID    string            `json:"projectId"`
	Entrypoint   string            `json:"entrypoint"`
	Command      string            `json:"command"`
	Env          map[string]string `json:"env"`
	GPU          bool              `json:"gpu"`
	TimeoutSecs  int               `json:"timeoutSeconds"`
	LauncherPath string            `json:"launcherPath"`
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

	launcherPath := input.LauncherPath
	if launcherPath == "" {
		launcherPath = "./container/launch_container.sh"
	}

	entrypoint := input.Entrypoint
	if entrypoint == "" {
		entrypoint = "run-job.sh"
	}

	args := []string{"--entrypoint", entrypoint, "--", input.Command}

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
		Command:     launcherPath,
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
	cacheDir := input.CacheDir
	if cacheDir == "" {
		cacheDir = "/opt/hf_cache"
	}

	script := `
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

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     "python3",
		Args:        []string{"-c", script},
		Env:         env,
		TimeoutSecs: input.TimeoutSecs,
	})
}

func HFDownloadModel(ctx context.Context, input HFDownloadModelInput) (RunCommandResult, error) {
	if strings.TrimSpace(input.ModelID) == "" {
		return RunCommandResult{ExitCode: -1}, errors.New("modelId is required")
	}

	cacheDir := input.CacheDir
	if cacheDir == "" {
		cacheDir = "/opt/hf_cache"
	}

	script := `
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

	return runCommand(ctx, RunCommandInput{
		Name:        input.Name,
		WorkflowID:  input.WorkflowID,
		RunID:       input.RunID,
		StepID:      input.StepID,
		LogDir:      input.LogDir,
		Command:     "python3",
		Args:        []string{"-c", script},
		Env:         env,
		TimeoutSecs: input.TimeoutSecs,
	})
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
		env := os.Environ()
		for key, value := range input.Env {
			env = append(env, key+"="+value)
		}
		cmd.Env = env
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	lw := setupLogWriters(&stdout, &stderr, input.LogDir, input.WorkflowID, input.RunID, input.StepID, input.Name)
	defer lw.Close()

	cmd.Stdout = lw.stdoutWriter
	cmd.Stderr = lw.stderrWriter

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

	maxBytes := int64(10_000)
	if value := os.Getenv("TEMPORAL_LOG_MAX_BYTES"); value != "" {
		if parsed, parseErr := strconv.ParseInt(value, 10, 64); parseErr == nil && parsed > 0 {
			maxBytes = parsed
		}
	}

	if maxBytes > 0 {
		result.Stdout, result.StdoutTruncated = truncate(result.Stdout, maxBytes)
		result.Stderr, result.StderrTruncated = truncate(result.Stderr, maxBytes)
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

func emitEvent(logDir string, event StepEvent) {
	if logDir == "" {
		return
	}
	if !filepath.IsAbs(logDir) {
		if cwd, err := os.Getwd(); err == nil {
			logDir = filepath.Join(cwd, logDir)
		}
	}
	_ = os.MkdirAll(logDir, 0o755)
	path := filepath.Join(logDir, "events.jsonl")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer file.Close()

	if event.Timestamp == "" {
		event.Timestamp = time.Now().UTC().Format(time.RFC3339Nano)
	}
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	_, _ = file.Write(append(data, '\n'))
}
