package activities

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Unit tests: pure helpers
// ---------------------------------------------------------------------------

func TestExitCode(t *testing.T) {
	if got := exitCode(nil); got != 0 {
		t.Errorf("exitCode(nil) = %d, want 0", got)
	}
}

func TestTruncate(t *testing.T) {
	tests := []struct {
		value     string
		maxBytes  int64
		want      string
		truncated bool
	}{
		{"hello", 10, "hello", false},
		{"hello", 5, "hello", false},
		{"hello", 3, "hel", true},
		{"", 10, "", false},
		{"abcdefghij", 0, "", true},
	}
	for _, tt := range tests {
		got, trunc := truncate(tt.value, tt.maxBytes)
		if got != tt.want || trunc != tt.truncated {
			t.Errorf("truncate(%q, %d) = (%q, %v), want (%q, %v)",
				tt.value, tt.maxBytes, got, trunc, tt.want, tt.truncated)
		}
	}
}

func TestSafeName(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"hello", "hello"},
		{"path/to/file", "path_to_file"},
		{"back\\slash", "back_slash"},
		{"has space", "has_space"},
		{"  trimmed  ", "trimmed"},
		{"", ""},
		{"multi/path\\with space", "multi_path_with_space"},
	}
	for _, tt := range tests {
		if got := safeName(tt.input); got != tt.want {
			t.Errorf("safeName(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

// ---------------------------------------------------------------------------
// Unit tests: logWriters
// ---------------------------------------------------------------------------

func TestSetupLogWriters(t *testing.T) {
	dir := t.TempDir()
	var stdout, stderr bytes.Buffer
	lw := setupLogWriters(&stdout, &stderr, dir, "wf-1", "run-1", "step-1", "test-step")
	defer lw.Close()

	if lw.logDir != dir {
		t.Errorf("logDir = %q, want %q", lw.logDir, dir)
	}
	if lw.stdoutPath == "" {
		t.Error("stdoutPath is empty")
	}
	if lw.stderrPath == "" {
		t.Error("stderrPath is empty")
	}
	if lw.structuredPath == "" {
		t.Error("structuredPath is empty")
	}
	if lw.stdoutStructuredWriter == nil {
		t.Error("stdoutStructuredWriter is nil")
	}
	if lw.stderrStructuredWriter == nil {
		t.Error("stderrStructuredWriter is nil")
	}
	if len(lw.closers) != 3 {
		t.Errorf("expected 3 closers, got %d", len(lw.closers))
	}
}

func TestSetupLogWritersPrefix(t *testing.T) {
	dir := t.TempDir()
	var stdout, stderr bytes.Buffer

	t.Run("stepID takes precedence over name", func(t *testing.T) {
		lw := setupLogWriters(&stdout, &stderr, dir, "wf", "run", "step", "name")
		defer lw.Close()
		if !strings.Contains(lw.stdoutPath, "wf_run_step_stdout.log") {
			t.Errorf("unexpected stdoutPath: %s", lw.stdoutPath)
		}
	})

	t.Run("name used when stepID empty", func(t *testing.T) {
		lw := setupLogWriters(&stdout, &stderr, dir, "wf", "run", "", "myname")
		defer lw.Close()
		if !strings.Contains(lw.stdoutPath, "wf_run_myname_stdout.log") {
			t.Errorf("unexpected stdoutPath: %s", lw.stdoutPath)
		}
	})

	t.Run("empty prefix defaults to step", func(t *testing.T) {
		lw := setupLogWriters(&stdout, &stderr, dir, "", "", "", "")
		defer lw.Close()
		if !strings.Contains(lw.stdoutPath, "step_stdout.log") {
			t.Errorf("unexpected stdoutPath: %s", lw.stdoutPath)
		}
	})
}

func TestSetupLogWritersFallback(t *testing.T) {
	var stdout, stderr bytes.Buffer
	lw := setupLogWriters(&stdout, &stderr, "", "wf", "", "", "")
	defer lw.Close()

	if lw.logDir == "" {
		t.Error("logDir should not be empty even with empty hint")
	}
}

func TestLogWritersWrite(t *testing.T) {
	dir := t.TempDir()
	var stdout, stderr bytes.Buffer
	lw := setupLogWriters(&stdout, &stderr, dir, "wf", "run", "step", "test")
	defer lw.Close()

	_, _ = lw.stdoutWriter.Write([]byte("hello stdout\n"))
	_, _ = lw.stderrWriter.Write([]byte("hello stderr\n"))
	lw.FlushPartial()

	if !strings.Contains(stdout.String(), "hello stdout") {
		t.Errorf("stdout buffer missing content: %q", stdout.String())
	}
	if !strings.Contains(stderr.String(), "hello stderr") {
		t.Errorf("stderr buffer missing content: %q", stderr.String())
	}

	// Check file was written
	data, err := os.ReadFile(lw.stdoutPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "hello stdout") {
		t.Errorf("stdout file missing content")
	}

	// Check structured JSONL was written
	data, err = os.ReadFile(lw.structuredPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) < 2 {
		t.Fatalf("expected at least 2 structured log lines, got %d", len(lines))
	}
	var entry structuredLogLine
	if err := json.Unmarshal([]byte(lines[0]), &entry); err != nil {
		t.Fatal(err)
	}
	if entry.Stream != "stdout" {
		t.Errorf("first line stream = %q, want stdout", entry.Stream)
	}
	if entry.Message != "hello stdout" {
		t.Errorf("first line message = %q, want 'hello stdout'", entry.Message)
	}
}

// ---------------------------------------------------------------------------
// Unit tests: lineBufferWriter
// ---------------------------------------------------------------------------

func TestLineBufferWriter(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "structured.jsonl")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	sink := &structuredLogSink{
		file:       file,
		workflowID: "wf",
		runID:      "run",
		stepID:     "step",
		stepName:   "test",
	}

	w := &lineBufferWriter{sink: sink, stream: "stdout"}

	// Write complete line
	_, _ = w.Write([]byte("line1\n"))
	// Write partial, then complete
	_, _ = w.Write([]byte("par"))
	_, _ = w.Write([]byte("tial\n"))
	// Write partial, flush
	_, _ = w.Write([]byte("remaining"))
	w.FlushPartial()

	file.Close()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 3 {
		t.Fatalf("expected 3 lines, got %d: %v", len(lines), lines)
	}

	// Check first line
	var entry structuredLogLine
	json.Unmarshal([]byte(lines[0]), &entry)
	if entry.Message != "line1" || entry.Partial {
		t.Errorf("line 0: message=%q partial=%v", entry.Message, entry.Partial)
	}

	// Check second line (reassembled partial)
	json.Unmarshal([]byte(lines[1]), &entry)
	if entry.Message != "partial" || entry.Partial {
		t.Errorf("line 1: message=%q partial=%v", entry.Message, entry.Partial)
	}

	// Check third line (flushed partial)
	json.Unmarshal([]byte(lines[2]), &entry)
	if entry.Message != "remaining" || !entry.Partial {
		t.Errorf("line 2: message=%q partial=%v", entry.Message, entry.Partial)
	}
}

func TestLineBufferWriterCarriageReturn(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "structured.jsonl")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	sink := &structuredLogSink{file: file, workflowID: "wf"}
	w := &lineBufferWriter{sink: sink, stream: "stdout"}

	_, _ = w.Write([]byte("progress 50%\r\n"))
	file.Close()

	data, _ := os.ReadFile(path)
	var entry structuredLogLine
	json.Unmarshal([]byte(strings.TrimSpace(string(data))), &entry)
	if entry.Message != "progress 50%" {
		t.Errorf("carriage return not stripped: %q", entry.Message)
	}
}

// ---------------------------------------------------------------------------
// Unit tests: emitEvent
// ---------------------------------------------------------------------------

func TestEmitEvent(t *testing.T) {
	dir := t.TempDir()
	emitEvent(dir, StepEvent{
		WorkflowID: "wf-1",
		RunID:      "run-1",
		StepID:     "step-1",
		Status:     "step_started",
	})
	emitEvent(dir, StepEvent{
		WorkflowID: "wf-1",
		RunID:      "run-1",
		StepID:     "step-1",
		Status:     "step_finished",
		ExitCode:   0,
	})

	data, err := os.ReadFile(filepath.Join(dir, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 event lines, got %d", len(lines))
	}

	var e1, e2 StepEvent
	json.Unmarshal([]byte(lines[0]), &e1)
	json.Unmarshal([]byte(lines[1]), &e2)

	if e1.Status != "step_started" {
		t.Errorf("event 0 status = %q", e1.Status)
	}
	if e2.Status != "step_finished" {
		t.Errorf("event 1 status = %q", e2.Status)
	}
	if e1.Timestamp == "" {
		t.Error("event 0 should have auto-generated timestamp")
	}
}

func TestEmitEventEmptyDir(t *testing.T) {
	// Should not panic
	emitEvent("", StepEvent{Status: "test"})
}

// ---------------------------------------------------------------------------
// Unit tests: input validation
// ---------------------------------------------------------------------------

func TestRunCommandValidation(t *testing.T) {
	_, err := RunCommand(context.Background(), RunCommandInput{Command: ""})
	if err == nil {
		t.Error("expected error for empty command")
	}
	_, err = RunCommand(context.Background(), RunCommandInput{Command: "   "})
	if err == nil {
		t.Error("expected error for whitespace-only command")
	}
}

func TestDownloadFileValidation(t *testing.T) {
	_, err := DownloadFile(context.Background(), DownloadInput{URL: "", OutputPath: "/tmp/x"})
	if err == nil {
		t.Error("expected error for empty URL")
	}
	_, err = DownloadFile(context.Background(), DownloadInput{URL: "http://x", OutputPath: ""})
	if err == nil {
		t.Error("expected error for empty outputPath")
	}
}

func TestDockerBuildValidation(t *testing.T) {
	_, err := DockerBuild(context.Background(), DockerBuildInput{Image: ""})
	if err == nil {
		t.Error("expected error for empty image")
	}
}

func TestDockerPushValidation(t *testing.T) {
	_, err := DockerPush(context.Background(), DockerPushInput{Image: ""})
	if err == nil {
		t.Error("expected error for empty image")
	}
}

func TestPackageBuildValidation(t *testing.T) {
	_, err := PackageBuild(context.Background(), PackageBuildInput{Command: ""})
	if err == nil {
		t.Error("expected error for empty command")
	}
}

func TestContainerJobValidation(t *testing.T) {
	_, err := ContainerJob(context.Background(), ContainerJobInput{Command: ""})
	if err == nil {
		t.Error("expected error for empty command")
	}
}

func TestHFDownloadDatasetValidation(t *testing.T) {
	_, err := HFDownloadDataset(context.Background(), HFDownloadDatasetInput{DatasetID: ""})
	if err == nil {
		t.Error("expected error for empty datasetId")
	}
}

func TestHFDownloadModelValidation(t *testing.T) {
	_, err := HFDownloadModel(context.Background(), HFDownloadModelInput{ModelID: ""})
	if err == nil {
		t.Error("expected error for empty modelId")
	}
}

// ---------------------------------------------------------------------------
// Integration tests: RunCommand with real commands
// ---------------------------------------------------------------------------

func TestRunCommandEcho(t *testing.T) {
	dir := t.TempDir()
	result, err := RunCommand(context.Background(), RunCommandInput{
		Command:    "echo",
		Args:       []string{"hello world"},
		WorkflowID: "test-wf",
		RunID:      "test-run",
		StepID:     "echo-step",
		LogDir:     dir,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode != 0 {
		t.Errorf("exit code = %d, want 0", result.ExitCode)
	}
	if !strings.Contains(result.Stdout, "hello world") {
		t.Errorf("stdout = %q, want 'hello world'", result.Stdout)
	}
	if result.StdoutPath == "" {
		t.Error("stdoutPath is empty")
	}

	// Verify log files exist
	if _, err := os.Stat(result.StdoutPath); err != nil {
		t.Errorf("stdout log file missing: %v", err)
	}
	if _, err := os.Stat(result.StderrPath); err != nil {
		t.Errorf("stderr log file missing: %v", err)
	}
	if _, err := os.Stat(result.StructuredPath); err != nil {
		t.Errorf("structured log file missing: %v", err)
	}

	// Verify events.jsonl
	eventsPath := filepath.Join(dir, "events.jsonl")
	data, err := os.ReadFile(eventsPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 {
		t.Errorf("expected 2 events, got %d", len(lines))
	}
}

func TestRunCommandNonZeroExit(t *testing.T) {
	dir := t.TempDir()
	result, err := RunCommand(context.Background(), RunCommandInput{
		Command:    "bash",
		Args:       []string{"-c", "exit 42"},
		WorkflowID: "test-wf",
		StepID:     "fail-step",
		LogDir:     dir,
	})
	// Non-zero exit should NOT return an error (workflow decides)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.ExitCode != 42 {
		t.Errorf("exit code = %d, want 42", result.ExitCode)
	}
}

func TestRunCommandStderr(t *testing.T) {
	dir := t.TempDir()
	result, err := RunCommand(context.Background(), RunCommandInput{
		Command:    "bash",
		Args:       []string{"-c", "echo err >&2"},
		WorkflowID: "test-wf",
		StepID:     "stderr-step",
		LogDir:     dir,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(result.Stderr, "err") {
		t.Errorf("stderr = %q, want 'err'", result.Stderr)
	}
}

func TestRunCommandEnvVars(t *testing.T) {
	dir := t.TempDir()
	result, err := RunCommand(context.Background(), RunCommandInput{
		Command:    "bash",
		Args:       []string{"-c", "echo $MY_VAR"},
		Env:        map[string]string{"MY_VAR": "test_value"},
		WorkflowID: "test-wf",
		StepID:     "env-step",
		LogDir:     dir,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(result.Stdout, "test_value") {
		t.Errorf("stdout = %q, want 'test_value'", result.Stdout)
	}
}

func TestRunCommandTruncation(t *testing.T) {
	dir := t.TempDir()
	// Set low max bytes
	t.Setenv("TEMPORAL_LOG_MAX_BYTES", "10")

	result, err := RunCommand(context.Background(), RunCommandInput{
		Command:    "bash",
		Args:       []string{"-c", "echo abcdefghijklmnopqrstuvwxyz"},
		WorkflowID: "test-wf",
		StepID:     "trunc-step",
		LogDir:     dir,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.StdoutTruncated {
		t.Error("expected stdout to be truncated")
	}
	if len(result.Stdout) != 10 {
		t.Errorf("stdout length = %d, want 10", len(result.Stdout))
	}

	// Full log should NOT be truncated
	data, _ := os.ReadFile(result.StdoutPath)
	if !strings.Contains(string(data), "abcdefghijklmnopqrstuvwxyz") {
		t.Error("full log file should contain complete output")
	}
}

func TestRunCommandTimeout(t *testing.T) {
	dir := t.TempDir()
	_, err := RunCommand(context.Background(), RunCommandInput{
		Command:     "sleep",
		Args:        []string{"60"},
		TimeoutSecs: 1,
		WorkflowID:  "test-wf",
		StepID:      "timeout-step",
		LogDir:      dir,
	})
	if err == nil {
		t.Error("expected timeout error")
	}
}

func TestRunCommandWorkingDir(t *testing.T) {
	dir := t.TempDir()
	result, err := RunCommand(context.Background(), RunCommandInput{
		Command:    "pwd",
		WorkingDir: "/tmp",
		WorkflowID: "test-wf",
		StepID:     "wd-step",
		LogDir:     dir,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(result.Stdout, "/tmp") {
		t.Errorf("stdout = %q, expected /tmp", result.Stdout)
	}
}

// ---------------------------------------------------------------------------
// Integration tests: DownloadFile
// ---------------------------------------------------------------------------

func TestDownloadFileInvalidURL(t *testing.T) {
	dir := t.TempDir()
	_, err := DownloadFile(context.Background(), DownloadInput{
		URL:        "http://127.0.0.1:1/nonexistent",
		OutputPath: filepath.Join(dir, "out.txt"),
		WorkflowID: "test-wf",
		StepID:     "dl-step",
		LogDir:     dir,
	})
	if err == nil {
		t.Error("expected error for invalid URL")
	}
}

// ---------------------------------------------------------------------------
// Integration tests: structured log content
// ---------------------------------------------------------------------------

func TestStructuredLogContent(t *testing.T) {
	dir := t.TempDir()
	result, err := RunCommand(context.Background(), RunCommandInput{
		Command:    "bash",
		Args:       []string{"-c", "echo line1; echo line2; echo err1 >&2"},
		WorkflowID: "wf-structured",
		RunID:      "run-structured",
		StepID:     "step-structured",
		LogDir:     dir,
	})
	if err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(result.StructuredPath)
	if err != nil {
		t.Fatal(err)
	}

	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) < 3 {
		t.Fatalf("expected at least 3 structured lines, got %d", len(lines))
	}

	stdoutCount := 0
	stderrCount := 0
	for _, line := range lines {
		var entry structuredLogLine
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("invalid JSONL line: %v", err)
		}
		// Verify required fields
		if entry.Timestamp == "" {
			t.Error("missing timestamp")
		}
		if entry.WorkflowID != "wf-structured" {
			t.Errorf("workflowId = %q", entry.WorkflowID)
		}
		if entry.RunID != "run-structured" {
			t.Errorf("runId = %q", entry.RunID)
		}
		if entry.StepID != "step-structured" {
			t.Errorf("stepId = %q", entry.StepID)
		}
		switch entry.Stream {
		case "stdout":
			stdoutCount++
		case "stderr":
			stderrCount++
		default:
			t.Errorf("unexpected stream: %q", entry.Stream)
		}
	}
	if stdoutCount < 2 {
		t.Errorf("expected at least 2 stdout lines, got %d", stdoutCount)
	}
	if stderrCount < 1 {
		t.Errorf("expected at least 1 stderr line, got %d", stderrCount)
	}
}
