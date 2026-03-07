package activities

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGitOpMissingOp(t *testing.T) {
	input := GitOpInput{
		Name:    "test",
		Op:      "",
		RepoDir: "/tmp",
	}
	_, err := GitOp(context.Background(), input)
	if err == nil {
		t.Fatal("expected error for missing op, got nil")
	}
	if !strings.Contains(err.Error(), "op is required") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestGitOpUnsupportedOp(t *testing.T) {
	input := GitOpInput{
		Name:    "test",
		Op:      "rebase",
		RepoDir: "/tmp",
	}
	_, err := GitOp(context.Background(), input)
	if err == nil {
		t.Fatal("expected error for unsupported op, got nil")
	}
	if !strings.Contains(err.Error(), "unsupported op") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestGitOpValidOps(t *testing.T) {
	validOps := []string{"branch", "commit", "push", "create-pr", "reset", "delete-branch"}
	for _, op := range validOps {
		input := GitOpInput{
			Name:         "test",
			Op:           op,
			GitOpsScript: "/nonexistent/git_ops.sh", // will fail on exec, not on op validation
		}
		_, err := GitOp(context.Background(), input)
		// Should not fail with "unsupported op" – any error is fine
		if err != nil && strings.Contains(err.Error(), "unsupported op") {
			t.Errorf("op %q should be valid, got: %v", op, err)
		}
	}
}

func TestGitOpScriptResolution(t *testing.T) {
	// When no script is configured and SYGALDRY_HOME is not set, should fail
	// with a path resolution error.
	orig := os.Getenv("SYGALDRY_HOME")
	_ = os.Unsetenv("SYGALDRY_HOME")
	defer func() {
		if orig != "" {
			_ = os.Setenv("SYGALDRY_HOME", orig)
		}
	}()

	input := GitOpInput{
		Name: "test",
		Op:   "branch",
		// GitOpsScript intentionally empty so resolution kicks in
	}
	_, err := GitOp(context.Background(), input)
	if err == nil {
		t.Skip("git_ops.sh found on disk, skipping resolution error test")
	}
	if !strings.Contains(err.Error(), "git_ops.sh not found") {
		t.Errorf("expected path resolution error, got: %v", err)
	}
}

func TestGitOpScriptConfigured(t *testing.T) {
	// When GitOpsScript points to an executable script, it should be invoked.
	dir := t.TempDir()
	script := filepath.Join(dir, "git_ops.sh")
	content := "#!/bin/bash\necho \"op=$1\"\nexit 0\n"
	if err := os.WriteFile(script, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}

	input := GitOpInput{
		Name:         "test",
		Op:           "branch",
		Branch:       "agentic/test-branch",
		GitOpsScript: script,
		LogDir:       dir,
	}
	result, err := GitOp(context.Background(), input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.ExitCode != 0 {
		t.Errorf("expected exit code 0, got %d; stderr: %s", result.ExitCode, result.Stderr)
	}
	if !strings.Contains(result.Stdout, "op=branch") {
		t.Errorf("expected stdout to contain 'op=branch', got: %q", result.Stdout)
	}
}

func TestResolveGitOpsScriptPathConfigured(t *testing.T) {
	path, err := resolveGitOpsScriptPath("/some/explicit/path.sh", "")
	if err != nil {
		t.Fatal(err)
	}
	if path != "/some/explicit/path.sh" {
		t.Errorf("expected configured path, got %q", path)
	}
}

func TestResolveGitOpsScriptPathSygaldryHome(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "tools", "agentic", "git_ops.sh")
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!/bin/bash\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Setenv("SYGALDRY_HOME", dir)
	path, err := resolveGitOpsScriptPath("", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if path != script {
		t.Errorf("expected %q, got %q", script, path)
	}
}

func TestResolveGitOpsScriptPathRepoDir(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "tools", "agentic", "git_ops.sh")
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!/bin/bash\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	path, err := resolveGitOpsScriptPath("", dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if path != script {
		t.Errorf("expected %q, got %q", script, path)
	}
}
