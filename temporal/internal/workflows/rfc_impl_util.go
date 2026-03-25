package workflows

import (
	"fmt"
	"path/filepath"
	"strings"

	"go.temporal.io/sdk/workflow"

	"temporal-orchestration/internal/activities"
)

// extractSetOutput parses ::set-output name=key::value from stdout.
// Returns empty string if key not found.
func extractSetOutput(stdout, key string) string {
	prefix := "::set-output name=" + key + "::"
	for _, line := range strings.Split(stdout, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

func rfcImplStatusSnapshot(status RFCImplStatus) RFCImplStatus {
	snapshot := status
	snapshot.TaskStates = cloneStepStates(status.TaskStates)
	return snapshot
}

func setRFCImplTasksPending(status *RFCImplStatus, tasks []RFCTaskSpec) {
	status.TaskStates = make(map[string]string, len(tasks))
	for _, task := range tasks {
		status.TaskStates[task.ID] = "pending"
	}
}

func setRFCImplTaskState(status *RFCImplStatus, taskID string, state string) {
	if status.TaskStates == nil {
		status.TaskStates = map[string]string{}
	}
	status.TaskStates[taskID] = state
}

func completeRFCImplStatus(ctx workflow.Context, status *RFCImplStatus, phase string) {
	status.Phase = phase
	completedAt := workflow.Now(ctx)
	status.CompletedAt = &completedAt
}

// rfcSafeID converts a workflow ID into a filesystem-safe string.
func rfcSafeID(id string) string {
	r := strings.NewReplacer("/", "_", "\\", "_", " ", "_", ":", "_", "\t", "_")
	return r.Replace(strings.TrimSpace(id))
}

func rfcTasksFilePath(tempDir, workflowID string) string {
	return filepath.Join(tempDir, fmt.Sprintf("rfc-impl-%s-tasks.json", rfcSafeID(workflowID)))
}

func rfcWorktreePath(tempDir, workflowID, taskID string) string {
	return filepath.Join(tempDir, fmt.Sprintf("rfc-impl-%s", rfcSafeID(workflowID)), taskID)
}

func rfcPlanFilePath(tempDir, workflowID, taskID string, attempt int) string {
	// Place inside the worktree so execute agents can read without external-directory
	// permission issues (the worktree is the agent's working directory).
	return filepath.Join(rfcWorktreePath(tempDir, workflowID, taskID), fmt.Sprintf(".rfc-plan-a%d.yaml", attempt))
}

// toAgentTaskEngines converts a []string to []activities.AgentTaskEngine.
func toAgentTaskEngines(ss []string) []activities.AgentTaskEngine {
	if len(ss) == 0 {
		return nil
	}
	result := make([]activities.AgentTaskEngine, len(ss))
	for i, s := range ss {
		result[i] = activities.AgentTaskEngine(s)
	}
	return result
}
