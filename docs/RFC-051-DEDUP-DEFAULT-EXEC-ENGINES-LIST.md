# RFC-051: Deduplicate Default Exec Engine List in rfc_impl.go

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Medium
**Effort:** XS

---

## Problem

The default multi-engine execution list is defined twice:

`temporal/internal/activities/multi_engine.go:33–38` (authoritative, exported):
```go
var defaultExecEngines = []AgentTaskEngine{
    AgentEngineCursor,
    AgentEngineGemini,
    AgentEngineOpenCode,
    AgentEngineCodex,
}
```

`temporal/internal/workflows/rfc_impl.go:347–354` (duplicate, inline):
```go
engines := input.ExecEngines
if len(engines) == 0 {
    engines = []activities.AgentTaskEngine{
        activities.AgentEngineCursor,
        activities.AgentEngineGemini,
        activities.AgentEngineOpenCode,
        activities.AgentEngineCodex,
    }
}
```

If a new engine is added to `defaultExecEngines` (or an engine is removed or reordered),
`rfc_impl.go` must be updated separately. The two lists have already diverged in order
relative to how they are presented in documentation.

`defaultExecEngines` is already a package-level `var` in the `activities` package. However,
it is unexported (`defaultExecEngines`, lowercase). Exporting it lets `rfc_impl.go` reuse it
directly.

---

## Solution

1. In `temporal/internal/activities/multi_engine.go`, export the variable:

```go
// DefaultExecEngines is the ordered list of engines tried by MultiEngineAgentTask
// when no explicit engine list is provided.
var DefaultExecEngines = []AgentTaskEngine{
    AgentEngineCursor,
    AgentEngineGemini,
    AgentEngineOpenCode,
    AgentEngineCodex,
}
```

Update the internal reference on line 64:
```go
engines = DefaultExecEngines
```

2. In `temporal/internal/workflows/rfc_impl.go:347–354`, replace the inline list:

```go
engines := input.ExecEngines
if len(engines) == 0 {
    engines = activities.DefaultExecEngines
}
```

---

## Acceptance Criteria

1. `grep -n 'defaultExecEngines\b' temporal/internal/activities/multi_engine.go` returns empty (variable renamed to exported form).
2. `grep -n 'DefaultExecEngines' temporal/internal/activities/multi_engine.go temporal/internal/workflows/rfc_impl.go` returns at least two lines (definition + reference).
3. The inline literal `AgentEngineCursor, AgentEngineGemini` slice in `rfc_impl.go` is gone:
   `grep -n 'AgentEngineCursor.*AgentEngineGemini\|AgentEngineGemini.*AgentEngineCursor' temporal/internal/workflows/rfc_impl.go` returns empty.
4. `cd temporal && go test ./...` passes.
