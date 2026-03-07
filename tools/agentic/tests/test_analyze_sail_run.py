from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
ANALYZE_PATH = REPO_ROOT / "tools" / "agentic" / "analyze_sail_run.py"


def load_module():
    spec = importlib.util.spec_from_file_location("analyze_sail_run", ANALYZE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        for row in rows:
            file.write(json.dumps(row) + "\n")


def test_analyzer_emits_synthetic_sail_issues(monkeypatch, tmp_path):
    module = load_module()
    run_dir = tmp_path / "run"
    analysis_dir = tmp_path / "analysis"

    run_meta = {
        "runId": "sailrun-001",
        "runKind": "primary",
        "config": {
            "planner": {"engine": "claude", "model": "opus"},
            "implementer": {"engine": "claude", "model": "sonnet"},
        },
    }
    discovery_stats = {
        "durationSec": 181.0,
        "selectedCount": 2,
        "sources": [
            {"name": "go_test", "durationSec": 90.0, "count": 0, "error": ""},
            {"name": "shellcheck", "durationSec": 10.0, "count": 1, "error": ""},
        ],
    }
    (run_dir / "run.json").parent.mkdir(parents=True, exist_ok=True)
    (run_dir / "run.json").write_text(json.dumps(run_meta), encoding="utf-8")
    (run_dir / "discovery_stats.json").write_text(json.dumps(discovery_stats), encoding="utf-8")

    attempt_records = []
    for attempt in (1, 2):
        log_dir = run_dir / f"logs-{attempt}"
        stderr_path = log_dir / "validate_stderr.log"
        stderr_path.parent.mkdir(parents=True, exist_ok=True)
        stderr_path.write_text("validate failed: same signature\n", encoding="utf-8")
        write_jsonl(
            log_dir / "events.jsonl",
            [
                {
                    "timestamp": f"2026-03-07T00:00:0{attempt}Z",
                    "workflowId": f"wf-{attempt}",
                    "runId": f"run-{attempt}",
                    "stepId": "validate",
                    "stepName": "validate",
                    "status": "step_finished",
                    "exitCode": 1,
                    "durationSec": 1,
                    "stdoutPath": "",
                    "stderrPath": str(stderr_path),
                    "structuredPath": "",
                    "message": "",
                },
                {
                    "timestamp": f"2026-03-07T00:00:1{attempt}Z",
                    "workflowId": f"wf-{attempt}",
                    "runId": f"run-{attempt}",
                    "stepId": "create_pr",
                    "stepName": "create_pr",
                    "status": "step_finished",
                    "exitCode": 1,
                    "durationSec": 1,
                    "stdoutPath": "",
                    "stderrPath": str(stderr_path),
                    "structuredPath": "",
                    "message": "",
                },
            ],
        )
        write_jsonl(
            log_dir / "wf_run_plan_structured.jsonl",
            [
                {
                    "timestamp": f"2026-03-07T00:00:0{attempt}Z",
                    "workflowId": f"wf-{attempt}",
                    "runId": f"run-{attempt}",
                    "stepId": "plan",
                    "stepName": "plan",
                    "stream": "stdout",
                    "message": "planner output",
                    "partial": False,
                }
            ],
        )
        write_jsonl(
            log_dir / "wf_run_implement_structured.jsonl",
            [
                {
                    "timestamp": f"2026-03-07T00:00:0{attempt}Z",
                    "workflowId": f"wf-{attempt}",
                    "runId": f"run-{attempt}",
                    "stepId": "implement",
                    "stepName": "implement",
                    "stream": "stdout",
                    "message": "implementer output",
                    "partial": False,
                }
            ],
        )
        attempt_records.append(
            {
                "sailRunId": "sailrun-001",
                "runKind": "primary",
                "issueId": "issue-1",
                "issueType": "shellcheck",
                "issuePriority": 2,
                "attempt": attempt,
                "workflowId": f"wf-{attempt}",
                "temporalRunId": f"run-{attempt}",
                "logDir": str(log_dir),
                "promptFile": "tools/agentic/prompts/planner.md",
                "status": "failed_attempt",
            }
        )

    write_jsonl(run_dir / "issue_attempts.jsonl", attempt_records)

    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(ANALYZE_PATH),
            "--run-dir",
            str(run_dir),
            "--output-dir",
            str(analysis_dir),
        ],
    )
    module.main()

    issues = json.loads((analysis_dir / "self_improvement_issues.json").read_text(encoding="utf-8"))
    issue_types = {issue["type"] for issue in issues}
    assert "discovery_slow" in issue_types
    assert "retry_loop" in issue_types
    assert "pr_creation_failure" in issue_types

    agent_sessions = (analysis_dir / "agent_sessions.jsonl").read_text(encoding="utf-8").strip().splitlines()
    assert len(agent_sessions) == 4

    summary = json.loads((analysis_dir / "summary.json").read_text(encoding="utf-8"))
    assert summary["counts"]["syntheticIssues"] >= 3
