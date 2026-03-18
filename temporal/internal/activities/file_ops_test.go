package activities

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadJSONFileMissingPath(t *testing.T) {
	_, err := ReadJSONFile(context.Background(), "")
	if err == nil {
		t.Fatal("expected error for empty path")
	}
	if !strings.Contains(err.Error(), "path is required") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestReadJSONFileNotFound(t *testing.T) {
	_, err := ReadJSONFile(context.Background(), "/nonexistent/path/tasks.json")
	if err == nil {
		t.Fatal("expected error for nonexistent file")
	}
	if !strings.Contains(err.Error(), "read_json_file") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestReadJSONFileSuccess(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tasks.json")
	content := `[{"id":"task-1","title":"Fix tests"}]`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadJSONFile(context.Background(), path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != content {
		t.Errorf("content mismatch: got %q, want %q", got, content)
	}
}
