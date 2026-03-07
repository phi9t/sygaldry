#!/usr/bin/env python3
"""
tools/agentic/analyze_sail_run.py — Analyze one persisted SAIL run.

Reads the artifact directory created by run_improvement_loop.sh, normalizes
workflow and agent-session logs, and emits synthetic self-improvement issues for
SAIL itself (not general repo-quality issues).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as file:
        for raw_line in file:
            line = raw_line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_jsonl(path: Path, payloads: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        for payload in payloads:
            file.write(json.dumps(payload, sort_keys=True) + "\n")


def sanitize_text(value: str) -> str:
    value = value.strip()
    value = re.sub(r"\s+", " ", value)
    return value


def read_excerpt(path_value: str, max_lines: int = 12) -> str:
    if not path_value:
        return ""
    path = Path(path_value)
    if not path.exists():
        return ""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(lines[-max_lines:])


def step_statuses(events: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    statuses: dict[str, dict[str, Any]] = {}
    for event in events:
        step_id = event.get("stepId") or event.get("stepName") or "unknown"
        state = statuses.setdefault(
            step_id,
            {
                "status": "pending",
                "exitCode": None,
                "stdoutPath": "",
                "stderrPath": "",
                "structuredPath": "",
            },
        )
        if event.get("status") != "step_finished":
            continue
        exit_code = event.get("exitCode")
        state["status"] = "success" if exit_code == 0 else "failed"
        state["exitCode"] = exit_code
        state["stdoutPath"] = event.get("stdoutPath") or ""
        state["stderrPath"] = event.get("stderrPath") or ""
        state["structuredPath"] = event.get("structuredPath") or ""
    return statuses


def synthetic_issue(
    issue_type: str,
    priority: int,
    title: str,
    description: str,
    files: list[str],
    context: dict[str, Any],
) -> dict[str, Any]:
    stable = json.dumps(
        {
            "issue_type": issue_type,
            "title": title,
            "files": files,
            "context": context,
        },
        sort_keys=True,
    )
    digest = hashlib.sha1(stable.encode()).hexdigest()[:8]
    return {
        "id": f"sail-{issue_type}-{digest}",
        "priority": priority,
        "type": issue_type,
        "title": title,
        "description": description,
        "files": files,
        "context": json.dumps(context, sort_keys=True),
    }


def validate_signature(stderr_excerpt: str) -> str:
    text = sanitize_text(stderr_excerpt)
    if not text:
        return ""
    return hashlib.sha1(text.encode()).hexdigest()[:12]


def aggregate_run(
    run_dir: Path,
    attempt_records: list[dict[str, Any]],
    run_meta: dict[str, Any],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, dict[str, Any]]]:
    workflow_events: list[dict[str, Any]] = []
    agent_sessions: list[dict[str, Any]] = []
    step_summaries: dict[str, dict[str, Any]] = {}

    planner_cfg = run_meta.get("config", {}).get("planner", {})
    implementer_cfg = run_meta.get("config", {}).get("implementer", {})

    for record in attempt_records:
        log_dir_value = record.get("logDir", "")
        if not log_dir_value:
            continue
        log_dir = Path(log_dir_value)
        events = read_jsonl(log_dir / "events.jsonl")
        statuses = step_statuses(events)
        step_summaries[f"{record.get('issueId','')}#{record.get('attempt', 0)}"] = statuses

        for event in events:
            enriched = dict(event)
            enriched.update(
                {
                    "sailRunId": record.get("sailRunId", ""),
                    "runKind": record.get("runKind", ""),
                    "issueId": record.get("issueId", ""),
                    "issueType": record.get("issueType", ""),
                    "issuePriority": record.get("issuePriority"),
                    "attempt": record.get("attempt", 0),
                    "outerStatus": record.get("status", ""),
                }
            )
            workflow_events.append(enriched)

        for structured_path in log_dir.glob("*_structured.jsonl"):
            for line in read_jsonl(structured_path):
                step_id = line.get("stepId") or line.get("stepName") or ""
                if step_id not in {"plan", "implement"}:
                    continue
                engine = planner_cfg.get("engine", "")
                model = planner_cfg.get("model", "")
                prompt_file = record.get("promptFile", "")
                if step_id == "implement":
                    engine = implementer_cfg.get("engine", "")
                    model = implementer_cfg.get("model", "")
                    prompt_file = "tools/agentic/prompts/implementer.md"
                agent_sessions.append(
                    {
                        "sailRunId": record.get("sailRunId", ""),
                        "runKind": record.get("runKind", ""),
                        "issueId": record.get("issueId", ""),
                        "issueType": record.get("issueType", ""),
                        "attempt": record.get("attempt", 0),
                        "workflowId": record.get("workflowId", ""),
                        "temporalRunId": record.get("temporalRunId", ""),
                        "stepId": step_id,
                        "engine": engine,
                        "model": model,
                        "promptFile": prompt_file,
                        **line,
                    }
                )

    workflow_events.sort(key=lambda item: item.get("timestamp", ""))
    agent_sessions.sort(key=lambda item: item.get("timestamp", ""))
    return workflow_events, agent_sessions, step_summaries


def detect_issues(
    run_meta: dict[str, Any],
    discovery_stats: dict[str, Any],
    attempt_records: list[dict[str, Any]],
    step_summaries: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    issues: dict[str, dict[str, Any]] = {}

    duration = float(discovery_stats.get("durationSec", 0.0) or 0.0)
    slow_sources = [
        source
        for source in discovery_stats.get("sources", [])
        if float(source.get("durationSec", 0.0) or 0.0) >= 60.0
    ]
    if duration >= 120.0 or slow_sources:
        issue = synthetic_issue(
            issue_type="discovery_slow",
            priority=2,
            title="Reduce SAIL discovery runtime",
            description=(
                f"SAIL discovery took {duration:.1f}s and should be optimized or "
                "time-boxed for unattended cron execution."
            ),
            files=["tools/agentic/discover_issues.py"],
            context={
                "durationSec": duration,
                "slowSources": slow_sources,
                "runId": run_meta.get("runId", ""),
            },
        )
        issues[issue["id"]] = issue

    repeated_validate: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in attempt_records:
        key = f"{record.get('issueId','')}#{record.get('attempt', 0)}"
        statuses = step_summaries.get(key, {})
        validate = statuses.get("validate")
        if validate and validate.get("status") == "failed":
            stderr_excerpt = read_excerpt(validate.get("stderrPath", ""))
            repeated_validate[record.get("issueId", "")].append(
                {
                    "attempt": record.get("attempt", 0),
                    "signature": validate_signature(stderr_excerpt),
                    "stderrExcerpt": stderr_excerpt,
                }
            )

        plan = statuses.get("plan")
        if plan and plan.get("status") == "failed":
            issue = synthetic_issue(
                issue_type="planner_failure",
                priority=1,
                title="Stabilize SAIL planner step failures",
                description=(
                    f"Planner step failed for issue {record.get('issueId','')} during "
                    f"attempt {record.get('attempt', 0)}."
                ),
                files=[
                    "temporal/internal/activities/agent_task.go",
                    "tools/agentic/prompts/planner.md",
                ],
                context={
                    "issueId": record.get("issueId", ""),
                    "attempt": record.get("attempt", 0),
                    "stderrExcerpt": read_excerpt(plan.get("stderrPath", "")),
                },
            )
            issues[issue["id"]] = issue

        implement = statuses.get("implement")
        if implement and implement.get("status") == "failed":
            issue = synthetic_issue(
                issue_type="implementer_failure",
                priority=1,
                title="Stabilize SAIL implementer step failures",
                description=(
                    f"Implementer step failed for issue {record.get('issueId','')} during "
                    f"attempt {record.get('attempt', 0)}."
                ),
                files=[
                    "temporal/internal/activities/agent_task.go",
                    "tools/agentic/prompts/implementer.md",
                ],
                context={
                    "issueId": record.get("issueId", ""),
                    "attempt": record.get("attempt", 0),
                    "stderrExcerpt": read_excerpt(implement.get("stderrPath", "")),
                },
            )
            issues[issue["id"]] = issue

        commit_step = statuses.get("commit_pr")
        if commit_step and commit_step.get("status") == "failed":
            commit_excerpt = sanitize_text(read_excerpt(commit_step.get("stderrPath", "")))
            if "nothing to commit" in commit_excerpt.lower():
                issue = synthetic_issue(
                    issue_type="empty_commit",
                    priority=2,
                    title="Avoid empty-commit SAIL success paths",
                    description=(
                        f"Commit step reported no staged changes for issue {record.get('issueId','')}."
                    ),
                    files=[
                        "tools/agentic/prompts/implementer.md",
                        "tools/agentic/improvement_loop.yaml",
                    ],
                    context={
                        "issueId": record.get("issueId", ""),
                        "attempt": record.get("attempt", 0),
                        "stderrExcerpt": commit_excerpt,
                    },
                )
                issues[issue["id"]] = issue

        create_pr = statuses.get("create_pr")
        if create_pr and create_pr.get("status") == "failed":
            issue = synthetic_issue(
                issue_type="pr_creation_failure",
                priority=2,
                title="Harden SAIL pull-request creation failures",
                description=(
                    f"PR creation failed for issue {record.get('issueId','')}."
                ),
                files=["tools/agentic/git_ops.sh"],
                context={
                    "issueId": record.get("issueId", ""),
                    "attempt": record.get("attempt", 0),
                    "stderrExcerpt": read_excerpt(create_pr.get("stderrPath", "")),
                },
            )
            issues[issue["id"]] = issue

    for issue_id, failures in repeated_validate.items():
        if len(failures) < 2:
            continue
        signatures = {entry["signature"] for entry in failures if entry["signature"]}
        if len(signatures) == 1:
            issue = synthetic_issue(
                issue_type="retry_loop",
                priority=2,
                title="Improve SAIL retry behavior for repeated validate failures",
                description=(
                    f"Validation failed repeatedly with the same signature for issue {issue_id}."
                ),
                files=[
                    "tools/agentic/prompts/retry.md",
                    "tools/agentic/run_improvement_loop.sh",
                ],
                context={
                    "issueId": issue_id,
                    "failures": failures,
                },
            )
            issues[issue["id"]] = issue

    return sorted(issues.values(), key=lambda item: (item["priority"], item["id"]))


def build_summary(
    run_meta: dict[str, Any],
    discovery_stats: dict[str, Any],
    attempt_records: list[dict[str, Any]],
    synthetic_issues: list[dict[str, Any]],
    agent_sessions: list[dict[str, Any]],
    workflow_events: list[dict[str, Any]],
) -> dict[str, Any]:
    attempt_status_counts = Counter(record.get("status", "") for record in attempt_records)
    step_event_counts = Counter(event.get("status", "") for event in workflow_events)
    return {
        "runId": run_meta.get("runId", ""),
        "runKind": run_meta.get("runKind", ""),
        "counts": {
            "attempts": len(attempt_records),
            "agentSessions": len(agent_sessions),
            "workflowEvents": len(workflow_events),
            "syntheticIssues": len(synthetic_issues),
        },
        "attemptStatusCounts": dict(sorted(attempt_status_counts.items())),
        "workflowEventCounts": dict(sorted(step_event_counts.items())),
        "discovery": {
            "durationSec": discovery_stats.get("durationSec", 0.0),
            "selectedCount": discovery_stats.get("selectedCount", 0),
            "sources": discovery_stats.get("sources", []),
        },
    }


def build_summary_markdown(summary: dict[str, Any], synthetic_issues: list[dict[str, Any]]) -> str:
    lines = [
        f"# SAIL Run Analysis: {summary.get('runId', '')}",
        "",
        f"- Attempts: {summary['counts']['attempts']}",
        f"- Agent session lines: {summary['counts']['agentSessions']}",
        f"- Workflow events: {summary['counts']['workflowEvents']}",
        f"- Synthetic self-improvement issues: {summary['counts']['syntheticIssues']}",
        f"- Discovery duration: {summary['discovery']['durationSec']}s",
        "",
        "## Attempt status counts",
    ]
    for name, count in sorted(summary.get("attemptStatusCounts", {}).items()):
        lines.append(f"- {name}: {count}")

    lines.extend(["", "## Synthetic issues"])
    if not synthetic_issues:
        lines.append("- None")
    else:
        for issue in synthetic_issues:
            lines.append(f"- [p{issue['priority']}] {issue['title']}")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze a persisted SAIL run")
    parser.add_argument("--run-dir", required=True, help="SAIL artifact directory to analyze")
    parser.add_argument("--output-dir", help="Output directory (default: <run-dir>/analysis)")
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    output_dir = Path(args.output_dir).resolve() if args.output_dir else run_dir / "analysis"
    output_dir.mkdir(parents=True, exist_ok=True)

    run_meta = read_json(run_dir / "run.json", {})
    discovery_stats = read_json(run_dir / "discovery_stats.json", {})
    attempt_records = read_jsonl(run_dir / "issue_attempts.jsonl")

    workflow_events, agent_sessions, step_summaries = aggregate_run(run_dir, attempt_records, run_meta)
    synthetic_issues = detect_issues(run_meta, discovery_stats, attempt_records, step_summaries)
    summary = build_summary(
        run_meta=run_meta,
        discovery_stats=discovery_stats,
        attempt_records=attempt_records,
        synthetic_issues=synthetic_issues,
        agent_sessions=agent_sessions,
        workflow_events=workflow_events,
    )

    write_json(output_dir / "summary.json", summary)
    (output_dir / "summary.md").write_text(
        build_summary_markdown(summary, synthetic_issues),
        encoding="utf-8",
    )
    write_jsonl(output_dir / "agent_sessions.jsonl", agent_sessions)
    write_jsonl(output_dir / "workflow_events.jsonl", workflow_events)
    write_json(output_dir / "self_improvement_issues.json", synthetic_issues)


if __name__ == "__main__":
    main()
