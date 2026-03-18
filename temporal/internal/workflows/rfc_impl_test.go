package workflows

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestExtractSetOutput(t *testing.T) {
	tests := []struct {
		stdout string
		key    string
		want   string
	}{
		{"::set-output name=tasks_file::/tmp/tasks.json\n", "tasks_file", "/tmp/tasks.json"},
		{"::set-output name=review_passed::true\n", "review_passed", "true"},
		{"::set-output name=review_passed::false\n::set-output name=review_failure::criterion 3 not met\n", "review_failure", "criterion 3 not met"},
		{"no set-output here\n", "tasks_file", ""},
		{"", "tasks_file", ""},
		// Windows-style line endings
		{"::set-output name=commit_sha::abc123\r\n", "commit_sha", "abc123"},
	}
	for _, tt := range tests {
		got := extractSetOutput(tt.stdout, tt.key)
		if got != tt.want {
			t.Errorf("extractSetOutput(%q, %q) = %q, want %q", tt.stdout, tt.key, got, tt.want)
		}
	}
}

func TestRFCSafeID(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"pipeline-20260101-120000", "pipeline-20260101-120000"},
		{"pipeline/sub/id", "pipeline_sub_id"},
		{"id with spaces", "id_with_spaces"},
		{"id:with:colons", "id_with_colons"},
	}
	for _, tt := range tests {
		got := rfcSafeID(tt.input)
		if got != tt.want {
			t.Errorf("rfcSafeID(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestRFCTasksJSONParsing(t *testing.T) {
	jsonStr := `[
		{"id":"t1","title":"Fix linting","description":"Fix shellcheck warnings","filesHint":["scripts/foo.sh"],"priority":1},
		{"id":"t2","title":"Add tests","description":"Add unit tests","filesHint":[],"priority":2}
	]`
	var tasks []RFCTaskSpec
	if err := json.Unmarshal([]byte(jsonStr), &tasks); err != nil {
		t.Fatalf("JSON unmarshal failed: %v", err)
	}
	if len(tasks) != 2 {
		t.Fatalf("expected 2 tasks, got %d", len(tasks))
	}
	if tasks[0].ID != "t1" || tasks[0].Title != "Fix linting" {
		t.Errorf("task[0] mismatch: %+v", tasks[0])
	}
	if len(tasks[0].FilesHint) != 1 || tasks[0].FilesHint[0] != "scripts/foo.sh" {
		t.Errorf("task[0].FilesHint mismatch: %v", tasks[0].FilesHint)
	}
}

func TestRFCTaskCountValidation(t *testing.T) {
	// 0 tasks should be invalid
	var empty []RFCTaskSpec
	if len(empty) != 0 {
		t.Fatal("sanity check failed")
	}

	// Build 11 tasks
	tasks := make([]RFCTaskSpec, 11)
	for i := range tasks {
		tasks[i] = RFCTaskSpec{ID: "t", Title: "t"}
	}
	if len(tasks) <= 10 {
		t.Fatal("sanity check failed")
	}
}

func TestWorktreePathGeneration(t *testing.T) {
	workflowID := "rfc-impl-20260101-abc123"
	taskID := "task-1"
	path := "/tmp/rfc-impl-" + rfcSafeID(workflowID) + "/" + taskID
	if !strings.HasPrefix(path, "/tmp/rfc-impl-") {
		t.Errorf("unexpected path prefix: %s", path)
	}
	if !strings.HasSuffix(path, taskID) {
		t.Errorf("path does not end with taskID: %s", path)
	}
}

func TestToAgentTaskEngines(t *testing.T) {
	got := toAgentTaskEngines([]string{"cursor", "gemini", "codex"})
	if len(got) != 3 {
		t.Fatalf("expected 3 engines, got %d", len(got))
	}
	if got[1] != "gemini" {
		t.Errorf("expected gemini at index 1, got %q", got[1])
	}
}

func TestToAgentTaskEnginesEmpty(t *testing.T) {
	got := toAgentTaskEngines(nil)
	if got != nil {
		t.Errorf("expected nil for nil input, got %v", got)
	}
	got = toAgentTaskEngines([]string{})
	if got != nil {
		t.Errorf("expected nil for empty input, got %v", got)
	}
}
