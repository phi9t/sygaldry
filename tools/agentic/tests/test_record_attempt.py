from __future__ import annotations

import json
from pathlib import Path

from tools.agentic.record_attempt import record_attempt


def test_record_attempt_writes_expected_fields(tmp_path: Path) -> None:
    path = tmp_path / "attempted.jsonl"

    record_attempt(
        path,
        issue_id="issue-123",
        status="success",
        branch="main",
        pr_url="https://example.test/pr/1",
        workflow_id="wf-1",
        temporal_run_id="run-1",
    )

    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    assert rows == [
        {
            "issue_id": "issue-123",
            "status": "success",
            "branch": "main",
            "pr_url": "https://example.test/pr/1",
            "workflow_id": "wf-1",
            "temporal_run_id": "run-1",
            "timestamp": rows[0]["timestamp"],
        }
    ]
