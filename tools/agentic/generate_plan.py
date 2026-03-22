#!/usr/bin/env python3
"""
tools/agentic/generate_plan.py — Deterministically generate a focused SAIL plan.

This keeps unattended SAIL runs from depending on an LLM to emit pipeline
outputs. The implementer step remains agent-driven; this script produces the
plan file and a commit-ready task title.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

Issue = dict[str, Any]


def json_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def normalize_repo_path(repo_dir: Path, raw_path: str) -> str:
    raw_path = raw_path.strip()
    if not raw_path:
        return ""
    path = Path(raw_path)
    if path.is_absolute():
        try:
            return str(path.resolve().relative_to(repo_dir.resolve()))
        except ValueError:
            return raw_path
    return raw_path


def actionable_files(repo_dir: Path, issue: Issue) -> list[str]:
    files: list[str] = []
    seen: set[str] = set()
    for raw_path in issue.get("files", []):
        path = normalize_repo_path(repo_dir, str(raw_path))
        if not path or "..." in path:
            continue
        if path not in seen:
            seen.add(path)
            files.append(path)
    return files


def read_failure_context(path_value: str) -> str:
    if not path_value:
        return ""
    path = Path(path_value)
    if not path.exists():
        return ""
    try:
        lines = [
            line.rstrip()
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
        ]
    except OSError:
        return ""
    excerpt = [line for line in lines if line.strip()][-12:]
    return "\n".join(excerpt)


def short_path(path: str) -> str:
    if len(path) <= 44:
        return path
    parts = Path(path).parts
    if len(parts) < 2:
        return path[:44]
    return f".../{parts[-1]}"


def trim_title(value: str, max_len: int = 64) -> str:
    value = " ".join(value.split()).strip().lower().rstrip(".")
    if len(value) <= max_len:
        return value
    trimmed = value[: max_len - 1].rstrip()
    if " " in trimmed:
        trimmed = trimmed.rsplit(" ", 1)[0]
    return trimmed.rstrip(".")


def issue_tag(issue: Issue) -> str:
    title = str(issue.get("title", ""))
    for prefix in ("TODO", "FIXME", "HACK"):
        if title.upper().startswith(f"{prefix}:"):
            return prefix.lower()
    return "todo"


def shellcheck_code(issue: Issue) -> str:
    text = " ".join(
        str(issue.get(key, "")) for key in ("title", "description", "context")
    )
    for token in text.split():
        if token.upper().startswith("SC") and token[2:].isdigit():
            return token.upper().rstrip(":")
    return "shellcheck"


def ruff_code(issue: Issue) -> str:
    title = str(issue.get("title", ""))
    code = title.split(":", 1)[0].strip().upper()
    return code if code and code.replace("-", "").isalnum() else "ruff"


def go_test_name(issue: Issue) -> str:
    title = str(issue.get("title", ""))
    if ":" in title:
        return title.split(":", 1)[1].strip()
    return title.strip() or "failing test"


def coverage_target(issue: Issue, file_path: str) -> str:
    title = str(issue.get("title", ""))
    if title.lower().startswith("uncovered function:"):
        remainder = title.split(":", 1)[1].strip()
        func_name = remainder.split(" in ", 1)[0].strip()
        if func_name:
            return func_name
    return Path(file_path).stem


def build_title(issue: Issue, files: list[str]) -> str:
    issue_type = str(issue.get("type", "issue"))
    file_path = files[0] if files else ""
    display_path = short_path(file_path) if file_path else "repository"

    if issue_type == "todo":
        if file_path.endswith("tools/agentic/discover_issues.py"):
            return "avoid todo false positives in tools/agentic/discover_issues.py"
        return trim_title(f"resolve {issue_tag(issue)} in {display_path}")
    if issue_type == "shellcheck":
        return trim_title(f"fix {shellcheck_code(issue).lower()} in {display_path}")
    if issue_type == "ruff":
        return trim_title(f"fix {ruff_code(issue).lower()} in {display_path}")
    if issue_type == "go_vet":
        return trim_title(f"fix go vet warning in {display_path}")
    if issue_type == "go_test":
        return trim_title(f"fix failing test {go_test_name(issue)}")
    if issue_type == "foundation_drift":
        return trim_title(f"fix foundation reference to {Path(display_path).name}")
    if issue_type == "go_coverage":
        return trim_title(
            f"add test coverage for {coverage_target(issue, display_path)}"
        )
    return trim_title(f"resolve {issue_type} issue {issue.get('id', 'unknown')}")


def build_approach(issue: Issue, files: list[str], failure_context: str) -> str:
    issue_type = str(issue.get("type", "issue"))
    issue_title = str(issue.get("title", "")).strip()
    if not files and issue_type not in {"go_test", "foundation_drift", "rfc"}:
        return "SKIP: This issue does not identify a concrete repository file to change safely."

    file_list = ", ".join(files) if files else "the affected repository files"
    if issue_type == "todo" and files == ["tools/agentic/discover_issues.py"]:
        lines = [
            "Inspect the TODO scanner implementation and make the smallest change that prevents it from flagging its own implementation literals as actionable repository annotations.",
            "Preserve discovery of real TODO/FIXME/HACK comments elsewhere in the repository.",
        ]
    elif issue_type == "shellcheck":
        lines = [
            f"Inspect {file_list} and apply the smallest shell change that resolves the reported ShellCheck finding.",
            "Preserve existing script behavior and quoting semantics outside the flagged case.",
        ]
    elif issue_type == "ruff":
        lines = [
            f"Apply the minimal Python change in {file_list} needed to resolve the reported Ruff finding.",
            "Keep surrounding behavior and formatting stable outside the flagged code path.",
        ]
    elif issue_type == "go_vet":
        lines = [
            f"Adjust {file_list} with the smallest Go code change that resolves the reported go vet warning.",
            "Avoid refactoring unrelated logic while making the warning disappear cleanly.",
        ]
    elif issue_type == "go_test":
        lines = [
            f"Investigate the failing test reported as {json_quote(issue_title)} and make the narrowest code or test change that restores the expected behavior.",
            "Keep the fix focused on the failing path instead of broad cleanup.",
        ]
    elif issue_type == "foundation_drift":
        lines = [
            "Update foundation.org or the referenced path so the missing-file reference is no longer stale.",
            "Prefer correcting the reference over creating placeholder files unless a real file is required.",
        ]
    elif issue_type == "go_coverage":
        lines = [
            f"Add a focused unit test around {file_list} so the uncovered function gains meaningful execution coverage.",
            "Keep the new test tight and avoid broad fixture churn.",
        ]
    elif issue_type == "rfc":
        rfc_doc = (
            issue.get("context", "")
            .replace("See ", "")
            .replace(" in docs/ for full spec and acceptance criteria.", "")
        )
        lines = [
            f"Read the RFC specification in docs/{rfc_doc} and implement exactly the changes described in the 'Proposed Solution' and 'Acceptance Criteria' sections.",
            "Make only the changes specified by the RFC. Do not add unrelated improvements.",
            "After implementing, verify ./validate_all.sh --quick passes.",
        ]
    else:
        lines = [
            f"Inspect {file_list} and implement the smallest change that resolves the reported {issue_type} issue.",
            "Avoid unrelated cleanup or structural refactors while fixing the targeted problem.",
        ]

    if failure_context:
        lines.append(
            "Address the previously observed failure context during this retry:"
        )
        lines.extend(failure_context.splitlines())

    return "\n".join(lines)


def build_file_changes(issue: Issue, files: list[str]) -> list[dict[str, str]]:
    issue_type = str(issue.get("type", "issue"))
    changes: list[dict[str, str]] = []
    for file_path in files:
        if issue_type == "todo" and file_path == "tools/agentic/discover_issues.py":
            change = (
                "Tighten TODO discovery so implementation literals in the scanner itself are not emitted "
                "as actionable issues while preserving real comment detection."
            )
        elif issue_type == "todo":
            change = "Resolve the flagged TODO/FIXME/HACK or narrow the detection so this finding is no longer actionable noise."
        elif issue_type == "shellcheck":
            change = "Apply the minimal shell change needed to eliminate the reported ShellCheck finding without altering intended behavior."
        elif issue_type == "ruff":
            change = "Apply the minimal Python change needed to eliminate the reported Ruff finding while preserving current behavior."
        elif issue_type == "go_vet":
            change = "Apply the smallest Go code change that resolves the reported go vet warning."
        elif issue_type == "foundation_drift":
            change = "Correct the stale foundation.org reference or align it with the actual repository layout."
        elif issue_type == "go_coverage":
            change = "Add a focused automated test or helper change that raises coverage for the targeted function."
        else:
            change = f"Make the minimal change required to resolve the reported {issue_type} issue."
        changes.append({"path": file_path, "change": change})
    return changes


def build_acceptance(issue: Issue, files: list[str]) -> list[str]:
    issue_type = str(issue.get("type", "issue"))
    file_path = files[0] if files else "the targeted code path"
    if issue_type == "todo" and file_path == "tools/agentic/discover_issues.py":
        return [
            "TODO discovery no longer emits a false-positive issue from tools/agentic/discover_issues.py for the scanner's own implementation literals.",
            "Legitimate TODO/FIXME/HACK comments elsewhere in the repository remain discoverable.",
            "./validate_all.sh --quick passes after the change.",
        ]
    if issue_type == "shellcheck":
        return [
            f"The referenced ShellCheck finding is no longer reported for {file_path}.",
            "./validate_all.sh --quick passes after the change.",
        ]
    if issue_type == "ruff":
        return [
            f"The referenced Ruff finding is no longer reported for {file_path}.",
            "./validate_all.sh --quick passes after the change.",
        ]
    if issue_type == "go_vet":
        return [
            f"go vet no longer reports the referenced warning for {file_path}.",
            "./validate_all.sh --quick passes after the change.",
        ]
    if issue_type == "go_test":
        return [
            "The previously failing Go test now passes.",
            "./validate_all.sh --quick passes after the change.",
        ]
    if issue_type == "foundation_drift":
        return [
            "foundation.org no longer references a missing file for this issue.",
            "./validate_all.sh --quick passes after the change.",
        ]
    if issue_type == "go_coverage":
        return [
            "The targeted function has non-zero automated test coverage.",
            "./validate_all.sh --quick passes after the change.",
        ]
    return [
        f"The reported {issue_type} issue is resolved in the targeted code path.",
        "./validate_all.sh --quick passes after the change.",
    ]


def build_risks(issue: Issue) -> list[str]:
    issue_type = str(issue.get("type", "issue"))
    if issue_type == "todo":
        return [
            "Narrowing TODO detection too aggressively could hide legitimate repository annotations."
        ]
    if issue_type in {"shellcheck", "ruff", "go_vet"}:
        return [
            "A minimal lint fix can still change behavior if quoting, control flow, or types are adjusted incorrectly."
        ]
    if issue_type == "go_test":
        return [
            "Patching only the test without understanding the failure could mask a real runtime bug."
        ]
    if issue_type == "go_coverage":
        return [
            "Coverage-only tests can become brittle if they overspecify internal implementation details."
        ]
    return ["Keep the fix tightly scoped so unrelated behavior does not change."]


def render_yaml(plan: dict[str, Any]) -> str:
    task = plan["task"]
    lines = [
        "task:",
        f"  issue_id: {json_quote(task['issue_id'])}",
        f"  title: {json_quote(task['title'])}",
        "  approach: |",
    ]
    for line in str(task["approach"]).splitlines():
        lines.append(f"    {line}")
    file_changes = task["files_to_change"]
    if file_changes:
        lines.append("  files_to_change:")
        for change in file_changes:
            lines.append(f"    - path: {json_quote(change['path'])}")
            lines.append(f"      change: {json_quote(change['change'])}")
    else:
        lines.append("  files_to_change: []")
    lines.append("  acceptance_criteria:")
    for item in task["acceptance_criteria"]:
        lines.append(f"    - {json_quote(item)}")
    lines.append("  risks:")
    for item in task["risks"]:
        lines.append(f"    - {json_quote(item)}")
    return "\n".join(lines) + "\n"


def build_plan(
    repo_dir: Path, workflow_id: str, issue: Issue, failure_context: str
) -> tuple[Path, dict[str, Any]]:
    files = actionable_files(repo_dir, issue)
    title = build_title(issue, files)
    plan = {
        "task": {
            "issue_id": str(issue.get("id", "")),
            "title": title,
            "approach": build_approach(issue, files, failure_context),
            "files_to_change": build_file_changes(issue, files),
            "acceptance_criteria": build_acceptance(issue, files),
            "risks": build_risks(issue),
        }
    }
    plan_path = Path(f"/tmp/sail-{workflow_id}-plan.yaml")
    plan_path.write_text(render_yaml(plan), encoding="utf-8")
    return plan_path, plan


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a deterministic SAIL plan")
    parser.add_argument("--repo-dir", required=True, help="Repository root")
    parser.add_argument(
        "--workflow-id", required=True, help="Workflow id used to name the plan file"
    )
    parser.add_argument(
        "--issue-json", required=True, help="JSON-encoded issue payload"
    )
    parser.add_argument(
        "--failure-context-file", default="", help="Optional retry failure context file"
    )
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    issue = json.loads(args.issue_json)
    failure_context = read_failure_context(args.failure_context_file)
    plan_path, plan = build_plan(repo_dir, args.workflow_id, issue, failure_context)

    print(f"::set-output name=plan_file::{plan_path}")
    print(f"::set-output name=task_title::{plan['task']['title']}")


if __name__ == "__main__":
    main()
