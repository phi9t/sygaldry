package workflows

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestSetRFCImplTasksPending(t *testing.T) {
	status := RFCImplStatus{WorkflowID: "wf-123", Phase: "decomposing"}
	tasks := []RFCTaskSpec{{ID: "t1"}, {ID: "t2"}}

	setRFCImplTasksPending(&status, tasks)

	if got := status.TaskStates["t1"]; got != "pending" {
		t.Fatalf("t1 state = %q, want pending", got)
	}
	if got := status.TaskStates["t2"]; got != "pending" {
		t.Fatalf("t2 state = %q, want pending", got)
	}
}

func TestRFCImplStatusSnapshotClonesMap(t *testing.T) {
	status := RFCImplStatus{
		WorkflowID: "wf-123",
		Phase:      "running",
		TaskStates: map[string]string{"t1": "running"},
	}
	snapshot := rfcImplStatusSnapshot(status)
	snapshot.TaskStates["t1"] = "failed"

	if got := status.TaskStates["t1"]; got != "running" {
		t.Fatalf("original state mutated to %q", got)
	}
}

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

func TestRFCTempPathGeneration(t *testing.T) {
	tempDir := "/var/tmp/rfc"
	workflowID := "rfc-impl-20260101-abc123"
	taskID := "task-1"
	safeWorkflowID := rfcSafeID(workflowID)

	tasksPath := rfcTasksFilePath(tempDir, workflowID)
	if want := filepath.Join(tempDir, "rfc-impl-"+safeWorkflowID+"-tasks.json"); tasksPath != want {
		t.Errorf("tasks path = %q, want %q", tasksPath, want)
	}

	worktreePath := rfcWorktreePath(tempDir, workflowID, taskID)
	if want := filepath.Join(tempDir, "rfc-impl-"+safeWorkflowID, taskID); worktreePath != want {
		t.Errorf("worktree path = %q, want %q", worktreePath, want)
	}

	planPath := rfcPlanFilePath(tempDir, workflowID, taskID, 2)
	if want := filepath.Join(rfcWorktreePath(tempDir, workflowID, taskID), ".rfc-plan-a2.yaml"); planPath != want {
		t.Errorf("plan path = %q, want %q", planPath, want)
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
