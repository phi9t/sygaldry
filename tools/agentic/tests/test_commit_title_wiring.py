from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]


def test_planner_prompt_emits_task_title_output():
    planner_prompt = (REPO_ROOT / "tools" / "agentic" / "prompts" / "planner.md").read_text(
        encoding="utf-8"
    )
    assert "::set-output name=task_title::<task.title>" in planner_prompt
    assert "lowercase, imperative" in planner_prompt


def test_pipeline_uses_typed_planner_title_for_commit_and_pr():
    pipeline = (REPO_ROOT / "tools" / "agentic" / "improvement_loop.yaml").read_text(
        encoding="utf-8"
    )
    assert "tools/agentic/generate_plan.py" in pipeline
    expected_subject = "agentic(${{ params.issue_type }}): ${{ steps.plan.outputs.task_title }}"
    assert expected_subject in pipeline
    assert 'Planned fix: ${{ steps.plan.outputs.task_title }}' in pipeline


def test_run_loop_passes_issue_type_to_pipeline():
    run_loop = (REPO_ROOT / "tools" / "agentic" / "run_improvement_loop.sh").read_text(
        encoding="utf-8"
    )
    assert '-set "issue_type=${issue_type}"' in run_loop
