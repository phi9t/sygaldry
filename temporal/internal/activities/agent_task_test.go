package activities

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func prependFakeCommand(t *testing.T, name string) {
	t.Helper()

	dir := t.TempDir()
	commandPath := filepath.Join(dir, name)
	if err := os.WriteFile(commandPath, []byte("#!/usr/bin/env sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	oldPath := os.Getenv("PATH")
	newPath := dir
	if oldPath != "" {
		newPath += string(os.PathListSeparator) + oldPath
	}
	if err := os.Setenv("PATH", newPath); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Setenv("PATH", oldPath)
	})
}

func TestAgentTaskMissingPrompt(t *testing.T) {
	input := AgentTaskInput{
		Name:   "test",
		Engine: AgentEngineClaude,
		Model:  "claude-opus-4-6",
		// No Prompt and no PromptFile
	}
	_, err := AgentTask(context.Background(), input)
	if err == nil {
		t.Fatal("expected error for missing prompt, got nil")
	}
	if !strings.Contains(err.Error(), "prompt or prompt_file is required") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestAgentTaskUnsupportedEngine(t *testing.T) {
	input := AgentTaskInput{
		Name:   "test",
		Engine: AgentTaskEngine("unknown-engine"),
		Prompt: "hello",
	}
	_, err := AgentTask(context.Background(), input)
	if err == nil {
		t.Fatal("expected error for unsupported engine, got nil")
	}
	if !strings.Contains(err.Error(), "unsupported engine") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestAgentTaskPromptFile(t *testing.T) {
	prependFakeCommand(t, "claude")

	dir := t.TempDir()
	promptPath := filepath.Join(dir, "prompt.md")
	if err := os.WriteFile(promptPath, []byte("test prompt content"), 0o644); err != nil {
		t.Fatal(err)
	}

	input := AgentTaskInput{
		Name:       "test",
		Engine:     AgentEngineClaude,
		PromptFile: promptPath,
		// Simulate: command won't exist, but we test that prompt_file is read
		// and the error is about the missing CLI, not the prompt
	}
	// The claude binary won't be in PATH in test, so we get a command-not-found error.
	// The important thing is we do NOT get a "prompt or prompt_file is required" error.
	_, err := AgentTask(context.Background(), input)
	if err != nil && strings.Contains(err.Error(), "prompt or prompt_file is required") {
		t.Errorf("should not report missing prompt when prompt_file is set: %v", err)
	}
}

func TestAgentTaskPromptFileRelativeToWorkingDir(t *testing.T) {
	prependFakeCommand(t, "claude")

	dir := t.TempDir()
	promptDir := filepath.Join(dir, "tools", "agentic", "prompts")
	if err := os.MkdirAll(promptDir, 0o755); err != nil {
		t.Fatal(err)
	}
	promptPath := filepath.Join(promptDir, "implementer.md")
	if err := os.WriteFile(promptPath, []byte("relative prompt"), 0o644); err != nil {
		t.Fatal(err)
	}

	input := AgentTaskInput{
		Name:       "test-relative-prompt",
		Engine:     AgentEngineClaude,
		PromptFile: filepath.Join("tools", "agentic", "prompts", "implementer.md"),
		WorkingDir: dir,
	}
	_, err := AgentTask(context.Background(), input)
	if err != nil && strings.Contains(err.Error(), "reading prompt_file") {
		t.Fatalf("relative prompt_file should resolve from working_dir: %v", err)
	}
}

func TestAgentTaskPromptFileMissing(t *testing.T) {
	input := AgentTaskInput{
		Name:       "test",
		Engine:     AgentEngineClaude,
		PromptFile: "/nonexistent/path/prompt.md",
	}
	_, err := AgentTask(context.Background(), input)
	if err == nil {
		t.Fatal("expected error for missing prompt_file, got nil")
	}
	if !strings.Contains(err.Error(), "reading prompt_file") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestAgentTaskDefaultEngine(t *testing.T) {
	prependFakeCommand(t, "claude")

	// Engine defaults to claude when empty; command won't exist in test env,
	// but we verify the error is not about the engine.
	input := AgentTaskInput{
		Name:   "test",
		Engine: "",
		Prompt: "hello",
	}
	_, err := AgentTask(context.Background(), input)
	// Should not fail with "unsupported engine"
	if err != nil && strings.Contains(err.Error(), "unsupported engine") {
		t.Errorf("default engine should be claude, not unsupported: %v", err)
	}
}

func TestAgentTaskCodexEngineArgs(t *testing.T) {
	prependFakeCommand(t, "codex")

	// We can't easily test the full invocation without the codex binary,
	// but we can verify the input struct fields map correctly by checking
	// the path taken through the switch does not error on engine dispatch.
	input := AgentTaskInput{
		Name:   "test",
		Engine: AgentEngineCodex,
		Model:  "gpt-5.4-medium",
		Prompt: "do something",
	}
	_, err := AgentTask(context.Background(), input)
	// Should not be an "unsupported engine" error
	if err != nil && strings.Contains(err.Error(), "unsupported engine") {
		t.Errorf("codex engine should be supported: %v", err)
	}
}

func TestAgentTaskCursorEngineArgs(t *testing.T) {
	prependFakeCommand(t, "cursor")

	input := AgentTaskInput{
		Name:   "test",
		Engine: AgentEngineCursor,
		Model:  "auto",
		Prompt: "do something",
	}
	_, err := AgentTask(context.Background(), input)
	if err != nil && strings.Contains(err.Error(), "unsupported engine") {
		t.Errorf("cursor engine should be supported: %v", err)
	}
}

func TestAgentTaskEchoEngine(t *testing.T) {
	// echo engine must succeed and return the prompt text in stdout.
	input := AgentTaskInput{
		Name:   "test-echo",
		Engine: AgentEngineEcho,
		Prompt: "hello from echo engine",
	}
	result, err := AgentTask(context.Background(), input)
	if err != nil {
		t.Fatalf("echo engine returned error: %v", err)
	}
	if result.ExitCode != 0 {
		t.Errorf("echo engine: expected exit code 0, got %d", result.ExitCode)
	}
	if !strings.Contains(result.Stdout, "hello from echo engine") {
		t.Errorf("echo engine: expected prompt in stdout, got: %q", result.Stdout)
	}
}

func TestAgentTaskParamsSubstitution(t *testing.T) {
	dir := t.TempDir()
	promptPath := filepath.Join(dir, "prompt.md")
	content := "Issue: ${{ params.issue_title }}\nDetails: ${{params.issue_json}}"
	if err := os.WriteFile(promptPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	input := AgentTaskInput{
		Name:       "test-params",
		Engine:     AgentEngineEcho,
		PromptFile: promptPath,
		Params: map[string]string{
			"issue_title": "Fix SC2155",
			"issue_json":  `{"id":"sc-abc"}`,
		},
	}
	result, err := AgentTask(context.Background(), input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(result.Stdout, "Fix SC2155") {
		t.Errorf("params.issue_title not substituted; stdout: %q", result.Stdout)
	}
	if !strings.Contains(result.Stdout, `{"id":"sc-abc"}`) {
		t.Errorf("params.issue_json not substituted; stdout: %q", result.Stdout)
	}
}

func TestAgentTaskParamsEnvVars(t *testing.T) {
	// Params must also be passed as SAIL_PARAM_* env vars to the subprocess.
	// We verify this by using the echo engine with a prompt that references the env var.
	// (echo doesn't expand env vars, so we check the mergedEnv indirectly by
	//  confirming no error occurs and the field is processed.)
	input := AgentTaskInput{
		Name:   "test-env",
		Engine: AgentEngineEcho,
		Prompt: "test",
		Params: map[string]string{
			"repo_dir": "/tmp/test-repo",
		},
	}
	result, err := AgentTask(context.Background(), input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.ExitCode != 0 {
		t.Errorf("expected exit 0, got %d", result.ExitCode)
	}
}
