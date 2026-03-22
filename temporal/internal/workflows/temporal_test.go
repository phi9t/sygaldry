package workflows

import (
	"testing"

	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/suite"
	"go.temporal.io/sdk/testsuite"
	"go.temporal.io/sdk/workflow"

	"temporal-orchestration/internal/activities"
)

// ─── suite setup ─────────────────────────────────────────────────────────────

type temporalSuite struct {
	suite.Suite
	testsuite.WorkflowTestSuite
}

func TestTemporalSuite(t *testing.T) {
	suite.Run(t, new(temporalSuite))
}

// ─── helper workflows ─────────────────────────────────────────────────────────

// testCompletePipelineStatusWF is a thin wrapper that lets completePipelineStatus
// execute inside a real workflow context provided by the test environment.
func testCompletePipelineStatusWF(ctx workflow.Context, phase string) (PipelineStatus, error) {
	status := PipelineStatus{
		Phase:           "running",
		CurrentStepID:   "s1",
		CurrentStepName: "Step One",
	}
	completePipelineStatus(ctx, &status, phase)
	return status, nil
}

// testCompleteRFCImplStatusWF is a thin wrapper for completeRFCImplStatus.
func testCompleteRFCImplStatusWF(ctx workflow.Context, phase string) (RFCImplStatus, error) {
	status := RFCImplStatus{Phase: "running"}
	completeRFCImplStatus(ctx, &status, phase)
	return status, nil
}

// testUpsertSearchAttrsWF is a thin wrapper for upsertPipelineSearchAttributes.
func testUpsertSearchAttrsWF(ctx workflow.Context) error {
	upsertPipelineSearchAttributes(ctx, "wf-id-1", PipelineStep{ID: "s1", Name: "my step"})
	return nil
}

// ─── completePipelineStatus ───────────────────────────────────────────────────

func (s *temporalSuite) Test_CompletePipelineStatus_Done() {
	env := s.NewTestWorkflowEnvironment()
	env.RegisterWorkflow(testCompletePipelineStatusWF)
	env.ExecuteWorkflow(testCompletePipelineStatusWF, "done")

	s.True(env.IsWorkflowCompleted())
	var got PipelineStatus
	s.NoError(env.GetWorkflowResult(&got))
	s.Equal("done", got.Phase)
	s.NotNil(got.CompletedAt)
	s.Empty(got.CurrentStepID)
	s.Empty(got.CurrentStepName)
}

func (s *temporalSuite) Test_CompletePipelineStatus_Running() {
	env := s.NewTestWorkflowEnvironment()
	env.RegisterWorkflow(testCompletePipelineStatusWF)
	env.ExecuteWorkflow(testCompletePipelineStatusWF, "running")

	s.True(env.IsWorkflowCompleted())
	var got PipelineStatus
	s.NoError(env.GetWorkflowResult(&got))
	s.Equal("running", got.Phase)
	s.Equal("s1", got.CurrentStepID, "running phase must not clear step ID")
}

// ─── completeRFCImplStatus ────────────────────────────────────────────────────

func (s *temporalSuite) Test_CompleteRFCImplStatus() {
	env := s.NewTestWorkflowEnvironment()
	env.RegisterWorkflow(testCompleteRFCImplStatusWF)
	env.ExecuteWorkflow(testCompleteRFCImplStatusWF, "succeeded")

	s.True(env.IsWorkflowCompleted())
	var got RFCImplStatus
	s.NoError(env.GetWorkflowResult(&got))
	s.Equal("succeeded", got.Phase)
	s.NotNil(got.CompletedAt)
}

// ─── upsertPipelineSearchAttributes ──────────────────────────────────────────

func (s *temporalSuite) Test_UpsertPipelineSearchAttributes() {
	env := s.NewTestWorkflowEnvironment()
	env.RegisterWorkflow(testUpsertSearchAttrsWF)
	env.ExecuteWorkflow(testUpsertSearchAttrsWF)

	s.True(env.IsWorkflowCompleted())
	s.NoError(env.GetWorkflowError())
}

// ─── Pipeline (covers startActivity, waitActivity, awaitNextCompletion) ───────

func (s *temporalSuite) Test_Pipeline_Empty() {
	env := s.NewTestWorkflowEnvironment()
	env.RegisterWorkflow(Pipeline)
	env.ExecuteWorkflow(Pipeline, PipelineInput{Steps: []PipelineStep{}})

	s.True(env.IsWorkflowCompleted())
	var result PipelineResult
	s.NoError(env.GetWorkflowResult(&result))
	s.True(result.Succeeded)
	s.Empty(result.Steps)
}

func (s *temporalSuite) Test_Pipeline_SingleCommandSuccess() {
	env := s.NewTestWorkflowEnvironment()
	env.RegisterWorkflow(Pipeline)
	env.OnActivity(activities.RunCommand, mock.Anything, mock.Anything).
		Return(activities.RunCommandResult{ExitCode: 0, Stdout: "ok"}, nil).
		Once()

	env.ExecuteWorkflow(Pipeline, PipelineInput{
		Steps: []PipelineStep{
			{ID: "s1", Type: "command", Command: "echo", Args: []string{"ok"}},
		},
	})

	s.True(env.IsWorkflowCompleted())
	var result PipelineResult
	s.NoError(env.GetWorkflowResult(&result))
	s.True(result.Succeeded)
	s.Len(result.Steps, 1)
	s.Equal("s1", result.Steps[0].ID)
}

// ─── RFCImpl ─────────────────────────────────────────────────────────────────

func (s *temporalSuite) Test_RFCImpl_MissingTempDir() {
	env := s.NewTestWorkflowEnvironment()
	env.RegisterWorkflow(RFCImpl)
	env.ExecuteWorkflow(RFCImpl, RFCImplInput{
		RFCPath: "docs/RFC-001.md",
		RepoDir: "/repo",
		TempDir: "", // required — missing triggers immediate error
	})

	s.True(env.IsWorkflowCompleted())
	s.Error(env.GetWorkflowError())
}

// ─── RFCTaskWorkflow ──────────────────────────────────────────────────────────

func (s *temporalSuite) Test_RFCTaskWorkflow_WorktreeAddFails() {
	env := s.NewTestWorkflowEnvironment()
	env.RegisterWorkflow(RFCTaskWorkflow)
	// worktree-add returns non-zero exit code → workflow returns immediately with FailReason
	env.OnActivity(activities.GitOp, mock.Anything,
		mock.MatchedBy(func(input activities.GitOpInput) bool {
			return input.Op == "worktree-add"
		}),
	).Return(activities.RunCommandResult{ExitCode: 1, Stderr: "git error"}, nil).Once()

	env.ExecuteWorkflow(RFCTaskWorkflow, RFCTaskInput{
		Task:         RFCTaskSpec{ID: "t1", Title: "test task"},
		RepoDir:      "/repo",
		BranchName:   "rfc-impl-t1",
		WorktreePath: "/tmp/wt",
		BaseBranch:   "main",
	})

	s.True(env.IsWorkflowCompleted())
	var result RFCTaskResult
	s.NoError(env.GetWorkflowResult(&result))
	s.False(result.Succeeded)
	s.Equal("worktree setup failed", result.FailReason)
}
