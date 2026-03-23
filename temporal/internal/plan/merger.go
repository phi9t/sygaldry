package plan

import (
	"temporal-orchestration/internal/maputil"
	"temporal-orchestration/internal/workflows"
)

// MergeStep merges override on top of base, returning a new PipelineStep.
// Non-zero/non-nil override fields replace base fields; zero-value overrides
// are ignored so the base value is preserved.
func MergeStep(base, override workflows.PipelineStep) workflows.PipelineStep {
	merged := base

	if override.ID != "" {
		merged.ID = override.ID
	}
	if override.Name != "" {
		merged.Name = override.Name
	}
	if override.Type != "" {
		merged.Type = override.Type
	}
	if override.DependsOn != nil {
		merged.DependsOn = append([]string(nil), override.DependsOn...)
	}
	if override.When != nil {
		whenCopy := *override.When
		merged.When = &whenCopy
	}
	if override.Command != "" {
		merged.Command = override.Command
	}
	if override.Args != nil {
		merged.Args = append([]string(nil), override.Args...)
	}
	if override.Env != nil {
		merged.Env = maputil.MergeStringMaps(merged.Env, override.Env)
	}
	if override.WorkingDir != "" {
		merged.WorkingDir = override.WorkingDir
	}
	if override.TimeoutSeconds > 0 {
		merged.TimeoutSeconds = override.TimeoutSeconds
	}
	if override.AllowFailure {
		merged.AllowFailure = true
	}
	if override.Retry != nil {
		merged.Retry = mergeRetrySpec(merged.Retry, override.Retry)
	}

	if override.Download != nil {
		merged.Download = mergeDownloadSpec(merged.Download, override.Download)
	}
	if override.DockerBuild != nil {
		merged.DockerBuild = mergeDockerBuildSpec(merged.DockerBuild, override.DockerBuild)
	}
	if override.DockerPush != nil {
		merged.DockerPush = mergeDockerPushSpec(merged.DockerPush, override.DockerPush)
	}
	if override.PackageBuild != nil {
		merged.PackageBuild = mergePackageBuildSpec(merged.PackageBuild, override.PackageBuild)
	}
	if override.ContainerJob != nil {
		merged.ContainerJob = mergeContainerJobSpec(merged.ContainerJob, override.ContainerJob)
	}
	if override.HFDownloadDataset != nil {
		merged.HFDownloadDataset = mergeHFDownloadDatasetSpec(merged.HFDownloadDataset, override.HFDownloadDataset)
	}
	if override.HFDownloadModel != nil {
		merged.HFDownloadModel = mergeHFDownloadModelSpec(merged.HFDownloadModel, override.HFDownloadModel)
	}
	if override.K8sJob != nil {
		merged.K8sJob = mergeK8sJobSpec(merged.K8sJob, override.K8sJob)
	}
	if override.AgentTask != nil {
		merged.AgentTask = mergeAgentTaskSpec(merged.AgentTask, override.AgentTask)
	}
	if override.GitOp != nil {
		merged.GitOp = mergeGitOpSpec(merged.GitOp, override.GitOp)
	}

	return merged
}

func mergeRetrySpec(base, override *workflows.RetrySpec) *workflows.RetrySpec {
	if base == nil {
		base = &workflows.RetrySpec{}
	}
	merged := *base
	if override.MaxAttempts > 0 {
		merged.MaxAttempts = override.MaxAttempts
	}
	if override.InitialIntervalSeconds > 0 {
		merged.InitialIntervalSeconds = override.InitialIntervalSeconds
	}
	if override.BackoffCoefficient > 0 {
		merged.BackoffCoefficient = override.BackoffCoefficient
	}
	if override.MaximumIntervalSeconds > 0 {
		merged.MaximumIntervalSeconds = override.MaximumIntervalSeconds
	}
	return &merged
}

func mergeDownloadSpec(base, override *workflows.DownloadSpec) *workflows.DownloadSpec {
	if base == nil {
		base = &workflows.DownloadSpec{}
	}
	merged := *base
	if override.URL != "" {
		merged.URL = override.URL
	}
	if override.Output != "" {
		merged.Output = override.Output
	}
	if override.Sha256 != "" {
		merged.Sha256 = override.Sha256
	}
	return &merged
}

func mergeDockerBuildSpec(base, override *workflows.DockerBuildSpec) *workflows.DockerBuildSpec {
	if base == nil {
		base = &workflows.DockerBuildSpec{}
	}
	merged := *base
	if override.Image != "" {
		merged.Image = override.Image
	}
	if override.Context != "" {
		merged.Context = override.Context
	}
	if override.Dockerfile != "" {
		merged.Dockerfile = override.Dockerfile
	}
	if override.BuildArgs != nil {
		merged.BuildArgs = maputil.MergeStringMaps(merged.BuildArgs, override.BuildArgs)
	}
	if override.Labels != nil {
		merged.Labels = maputil.MergeStringMaps(merged.Labels, override.Labels)
	}
	if override.Platform != "" {
		merged.Platform = override.Platform
	}
	if override.Target != "" {
		merged.Target = override.Target
	}
	return &merged
}

func mergeDockerPushSpec(base, override *workflows.DockerPushSpec) *workflows.DockerPushSpec {
	if base == nil {
		base = &workflows.DockerPushSpec{}
	}
	merged := *base
	if override.Image != "" {
		merged.Image = override.Image
	}
	return &merged
}

func mergePackageBuildSpec(base, override *workflows.PackageBuildSpec) *workflows.PackageBuildSpec {
	if base == nil {
		base = &workflows.PackageBuildSpec{}
	}
	merged := *base
	if override.Command != "" {
		merged.Command = override.Command
	}
	if override.Args != nil {
		merged.Args = append([]string(nil), override.Args...)
	}
	if override.Env != nil {
		merged.Env = maputil.MergeStringMaps(merged.Env, override.Env)
	}
	if override.WorkingDir != "" {
		merged.WorkingDir = override.WorkingDir
	}
	return &merged
}

func mergeContainerJobSpec(base, override *workflows.ContainerJobSpec) *workflows.ContainerJobSpec {
	if base == nil {
		base = &workflows.ContainerJobSpec{}
	}
	merged := *base
	if override.ProjectID != "" {
		merged.ProjectID = override.ProjectID
	}
	if override.Entrypoint != "" {
		merged.Entrypoint = override.Entrypoint
	}
	if override.Command != "" {
		merged.Command = override.Command
	}
	if override.Env != nil {
		merged.Env = maputil.MergeStringMaps(merged.Env, override.Env)
	}
	if override.GPU {
		merged.GPU = true
	}
	return &merged
}

func mergeHFDownloadDatasetSpec(base, override *workflows.HFDownloadDatasetSpec) *workflows.HFDownloadDatasetSpec {
	if base == nil {
		base = &workflows.HFDownloadDatasetSpec{}
	}
	merged := *base
	if override.DatasetID != "" {
		merged.DatasetID = override.DatasetID
	}
	if override.Config != "" {
		merged.Config = override.Config
	}
	if override.Split != "" {
		merged.Split = override.Split
	}
	if override.CacheDir != "" {
		merged.CacheDir = override.CacheDir
	}
	return &merged
}

func mergeHFDownloadModelSpec(base, override *workflows.HFDownloadModelSpec) *workflows.HFDownloadModelSpec {
	if base == nil {
		base = &workflows.HFDownloadModelSpec{}
	}
	merged := *base
	if override.ModelID != "" {
		merged.ModelID = override.ModelID
	}
	if override.CacheDir != "" {
		merged.CacheDir = override.CacheDir
	}
	return &merged
}

func mergeK8sJobSpec(base, override *workflows.K8sJobSpec) *workflows.K8sJobSpec {
	if base == nil {
		base = &workflows.K8sJobSpec{}
	}
	merged := *base
	if override.ProjectID != "" {
		merged.ProjectID = override.ProjectID
	}
	if override.Entrypoint != "" {
		merged.Entrypoint = override.Entrypoint
	}
	if override.Command != "" {
		merged.Command = override.Command
	}
	if override.Env != nil {
		merged.Env = maputil.MergeStringMaps(merged.Env, override.Env)
	}
	if override.GPU {
		merged.GPU = true
	}
	if override.GPUCount > 0 {
		merged.GPUCount = override.GPUCount
	}
	if override.Image != "" {
		merged.Image = override.Image
	}
	if override.Namespace != "" {
		merged.Namespace = override.Namespace
	}
	return &merged
}

func mergeAgentTaskSpec(base, override *workflows.AgentTaskSpec) *workflows.AgentTaskSpec {
	if base == nil {
		base = &workflows.AgentTaskSpec{}
	}
	merged := *base
	if override.Engine != "" {
		merged.Engine = override.Engine
	}
	if override.Model != "" {
		merged.Model = override.Model
	}
	if override.Prompt != "" {
		merged.Prompt = override.Prompt
	}
	if override.PromptFile != "" {
		merged.PromptFile = override.PromptFile
	}
	if override.WorkingDir != "" {
		merged.WorkingDir = override.WorkingDir
	}
	if override.Sandbox != "" {
		merged.Sandbox = override.Sandbox
	}
	if override.Env != nil {
		merged.Env = maputil.MergeStringMaps(merged.Env, override.Env)
	}
	if override.Params != nil {
		merged.Params = maputil.MergeStringMaps(merged.Params, override.Params)
	}
	return &merged
}

func mergeGitOpSpec(base, override *workflows.GitOpSpec) *workflows.GitOpSpec {
	if base == nil {
		base = &workflows.GitOpSpec{}
	}
	merged := *base
	if override.Op != "" {
		merged.Op = override.Op
	}
	if override.RepoDir != "" {
		merged.RepoDir = override.RepoDir
	}
	if override.Branch != "" {
		merged.Branch = override.Branch
	}
	if override.BaseBranch != "" {
		merged.BaseBranch = override.BaseBranch
	}
	if override.CommitMessage != "" {
		merged.CommitMessage = override.CommitMessage
	}
	if override.PRTitle != "" {
		merged.PRTitle = override.PRTitle
	}
	if override.PRBody != "" {
		merged.PRBody = override.PRBody
	}
	if override.GitOpsScript != "" {
		merged.GitOpsScript = override.GitOpsScript
	}
	if override.Env != nil {
		merged.Env = maputil.MergeStringMaps(merged.Env, override.Env)
	}
	return &merged
}
