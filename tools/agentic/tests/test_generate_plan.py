from __future__ import annotations

import json
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
GENERATE_PLAN = REPO_ROOT / "tools" / "agentic" / "generate_plan.py"


def run_generate_plan(
    tmp_path: Path, issue: dict[str, object], failure_context: str = ""
) -> tuple[str, Path]:
    repo_dir = tmp_path / "repo"
    repo_dir.mkdir()
    workflow_id = "wf-123"

    failure_context_file = tmp_path / "failure.txt"
    failure_context_file.write_text(failure_context, encoding="utf-8")

    result = subprocess.run(
        [
            "python3",
            str(GENERATE_PLAN),
            "--repo-dir",
            str(repo_dir),
            "--workflow-id",
            workflow_id,
            "--issue-json",
            json.dumps(issue),
            "--failure-context-file",
            str(failure_context_file),
        ],
        check=True,
        text=True,
        capture_output=True,
    )
    plan_path = Path(f"/tmp/sail-{workflow_id}-plan.yaml")
    return result.stdout, plan_path


def test_generate_plan_emits_outputs_and_meaningful_todo_title(tmp_path: Path) -> None:
    todo_tag = "TO" "DO"
    fixme_tag = "FIX" "ME"
    hack_tag = "HA" "CK"
    scanner_context = f'priority = 2 if tag in ("{fixme_tag}", "{hack_tag}") else 3'

    stdout, plan_path = run_generate_plan(
        tmp_path,
        {
            "id": "todo-59c78fad",
            "priority": 2,
            "type": "todo",
            "title": f'{fixme_tag}: ", "{hack_tag}") else 3',
            "description": f"tools/agentic/discover_issues.py:116: {scanner_context}",
            "files": ["tools/agentic/discover_issues.py"],
            "context": scanner_context,
        },
    )

    assert "::set-output name=plan_file::/tmp/sail-wf-123-plan.yaml" in stdout
    assert (
        "::set-output name=task_title::avoid todo false positives in tools/agentic/discover_issues.py"
        in stdout
    )

    plan_text = plan_path.read_text(encoding="utf-8")
    assert (
        'title: "avoid todo false positives in tools/agentic/discover_issues.py"'
        in plan_text
    )
    assert f"Tighten {todo_tag} discovery" in plan_text
    assert (
        f"Legitimate {todo_tag}/{fixme_tag}/{hack_tag} comments elsewhere" in plan_text
    )


def test_generate_plan_includes_retry_failure_context(tmp_path: Path) -> None:
    _, plan_path = run_generate_plan(
        tmp_path,
        {
            "id": "shellcheck-abc123",
            "priority": 2,
            "type": "shellcheck",
            "title": "SC2086: Double quote to prevent globbing and word splitting",
            "description": "tools/agentic/sail_cron.sh:42: SC2086 Double quote to prevent globbing and word splitting.",
            "files": ["tools/agentic/sail_cron.sh"],
            "context": "{}",
        },
        failure_context="validate failed\nmissing quote",
    )

    plan_text = plan_path.read_text(encoding="utf-8")
    assert (
        "Address the previously observed failure context during this retry:"
        in plan_text
    )
    assert "missing quote" in plan_text
