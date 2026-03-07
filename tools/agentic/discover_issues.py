#!/usr/bin/env python3
"""
tools/agentic/discover_issues.py — Scan the sygaldry repo for actionable issues.

Sources:
  1. git grep for TODO/FIXME/HACK comments
  2. shellcheck warnings (JSON output) on all .sh files
  3. go test ./... failures
  4. ruff lint findings (JSON output) on Python files
  5. foundation.org section header drift vs actual file list
  6. go vet ./... warnings
  7. Go functions with 0% test coverage

Output: JSON array of issues sorted by priority (1=critical, 2=high, 3=normal),
        printed to stdout. Each issue has the shape:
        {
          "id":          "<type>-<hash>",
          "priority":    1|2|3,
          "type":        "todo|shellcheck|go_test|ruff|foundation_drift|go_vet|go_coverage",
          "title":       "<short description>",
          "description": "<detail>",
          "files":       ["<path>", ...],
          "context":     "<extra context>"
        }

Usage:
  python3 tools/agentic/discover_issues.py [--repo-dir <path>] [--max-per-type N]
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

Issue = dict[str, Any]
SourceFunc = Callable[[Path, int], list[Issue]]


def _issue_id(issue_type: str, data: str) -> str:
    h = hashlib.sha1(data.encode()).hexdigest()[:8]
    return f"{issue_type}-{h}"


def _utc_now() -> str:
    return dt.datetime.utcnow().isoformat() + "Z"


def _run_source(
    name: str,
    func: SourceFunc,
    repo_dir: Path,
    max_per_type: int,
) -> tuple[list[Issue], dict[str, Any]]:
    started_at = _utc_now()
    start = time.perf_counter()
    error = ""
    try:
        issues = func(repo_dir, max_per_type)
    except Exception as exc:  # pragma: no cover - defensive telemetry path
        issues = []
        error = str(exc)
    duration = round(time.perf_counter() - start, 3)
    stats = {
        "name": name,
        "startedAt": started_at,
        "finishedAt": _utc_now(),
        "durationSec": duration,
        "count": len(issues),
        "error": error,
    }
    return issues, stats


# ---------------------------------------------------------------------------
# Source 1: TODO/FIXME/HACK comments
# ---------------------------------------------------------------------------

_TODO_RE = re.compile(r"(TODO|FIXME|HACK)\b[:\s]*(.*)", re.IGNORECASE)


def discover_todos(repo_dir: Path, max_per_type: int) -> list[Issue]:
    try:
        result = subprocess.run(
            ["git", "grep", "-n", "-E", r"TODO|FIXME|HACK"],
            cwd=repo_dir,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    issues: list[Issue] = []
    for line in result.stdout.splitlines():
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        file_path, lineno, content = parts
        m = _TODO_RE.search(content)
        if not m:
            continue
        tag = m.group(1).upper()
        desc = m.group(2).strip() or f"Unaddressed {tag}"
        priority = 2 if tag in ("FIXME", "HACK") else 3
        issues.append(
            {
                "id": _issue_id("todo", f"{file_path}:{lineno}:{content}"),
                "priority": priority,
                "type": "todo",
                "title": f"{tag}: {desc[:80]}",
                "description": f"{file_path}:{lineno}: {content.strip()}",
                "files": [file_path],
                "context": content.strip(),
            }
        )
        if len(issues) >= max_per_type:
            break
    return issues


# ---------------------------------------------------------------------------
# Source 2: shellcheck warnings
# ---------------------------------------------------------------------------

def discover_shellcheck(repo_dir: Path, max_per_type: int) -> list[Issue]:
    sh_files = list(repo_dir.rglob("*.sh"))
    # Exclude vendor/node_modules/hidden dirs
    sh_files = [
        f for f in sh_files
        if not any(part.startswith(".") or part in ("node_modules", "vendor")
                   for part in f.parts)
    ]
    if not sh_files:
        return []

    try:
        result = subprocess.run(
            ["shellcheck", "-f", "json", "-S", "warning", "--", *[str(f) for f in sh_files]],
            cwd=repo_dir,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    try:
        findings = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []

    issues: list[Issue] = []
    for finding in findings[:max_per_type]:
        file_path = finding.get("file", "")
        line = finding.get("line", 0)
        code = finding.get("code", 0)
        message = finding.get("message", "")
        level = finding.get("level", "warning")
        priority = 2 if level == "error" else 3
        issues.append(
            {
                "id": _issue_id("shellcheck", f"{file_path}:{line}:SC{code}"),
                "priority": priority,
                "type": "shellcheck",
                "title": f"SC{code}: {message[:80]}",
                "description": f"{file_path}:{line}: SC{code} {message}",
                "files": [file_path],
                "context": json.dumps(finding),
            }
        )
    return issues


# ---------------------------------------------------------------------------
# Source 3: go test failures
# ---------------------------------------------------------------------------

def discover_go_test_failures(repo_dir: Path, max_per_type: int) -> list[Issue]:
    temporal_dir = repo_dir / "temporal"
    if not temporal_dir.is_dir():
        return []

    try:
        result = subprocess.run(
            ["go", "test", "./...", "-json"],
            cwd=temporal_dir,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    failures: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("Action") == "fail" and entry.get("Test"):
            failures.append(entry)

    issues: list[Issue] = []
    for entry in failures[:max_per_type]:
        test_name = entry.get("Test", "unknown")
        pkg = entry.get("Package", "")
        issues.append(
            {
                "id": _issue_id("go_test", f"{pkg}:{test_name}"),
                "priority": 1,
                "type": "go_test",
                "title": f"Test failure: {test_name}",
                "description": f"Package {pkg}: test {test_name} failed",
                "files": [str(temporal_dir / "...")],
                "context": json.dumps(entry),
            }
        )
    return issues


# ---------------------------------------------------------------------------
# Source 4: ruff lint
# ---------------------------------------------------------------------------

def discover_ruff(repo_dir: Path, max_per_type: int) -> list[Issue]:
    try:
        result = subprocess.run(
            ["ruff", "check", "--output-format", "json", "."],
            cwd=repo_dir,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    try:
        findings = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []

    issues: list[Issue] = []
    for finding in findings[:max_per_type]:
        file_path = finding.get("filename", "")
        row = finding.get("location", {}).get("row", 0)
        code = finding.get("code", "")
        message = finding.get("message", "")
        issues.append(
            {
                "id": _issue_id("ruff", f"{file_path}:{row}:{code}"),
                "priority": 3,
                "type": "ruff",
                "title": f"{code}: {message[:80]}",
                "description": f"{file_path}:{row}: {code} {message}",
                "files": [file_path],
                "context": json.dumps(finding),
            }
        )
    return issues


# ---------------------------------------------------------------------------
# Source 5: foundation.org drift
# ---------------------------------------------------------------------------

_ORG_HEADING_RE = re.compile(r"^\*+\s+(.*)")
_FILE_RE = re.compile(r"`([^`]+\.[a-zA-Z0-9]+)`")


def discover_foundation_drift(repo_dir: Path, max_per_type: int) -> list[Issue]:
    foundation = repo_dir / "foundation.org"
    if not foundation.exists():
        return []

    text = foundation.read_text(errors="replace")
    referenced_files: list[str] = _FILE_RE.findall(text)

    issues: list[Issue] = []
    for rel_path in referenced_files[:max_per_type * 4]:
        full_path = repo_dir / rel_path
        if not full_path.exists():
            issues.append(
                {
                    "id": _issue_id("foundation_drift", rel_path),
                    "priority": 3,
                    "type": "foundation_drift",
                    "title": f"foundation.org references missing file: {rel_path}",
                    "description": (
                        f"foundation.org mentions `{rel_path}` but the file does not exist. "
                        "Either create the file or remove the reference."
                    ),
                    "files": [str(foundation), rel_path],
                    "context": rel_path,
                }
            )
        if len(issues) >= max_per_type:
            break
    return issues


# ---------------------------------------------------------------------------
# Source 6: go vet warnings
# ---------------------------------------------------------------------------

def discover_go_vet(repo_dir: Path, max_per_type: int) -> list[Issue]:
    temporal_dir = repo_dir / "temporal"
    if not temporal_dir.is_dir():
        return []

    try:
        result = subprocess.run(
            ["go", "vet", "./..."],
            cwd=temporal_dir,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    if result.returncode == 0:
        return []

    issues: list[Issue] = []
    for line in (result.stdout + result.stderr).splitlines():
        # go vet emits lines like: ./path/file.go:42:10: message
        parts = line.split(":", 3)
        if len(parts) < 4:
            continue
        file_path = parts[0].strip().lstrip("./")
        try:
            lineno = int(parts[1])
        except ValueError:
            continue
        message = parts[3].strip()
        if not message:
            continue
        full_path = str(temporal_dir / file_path)
        issues.append(
            {
                "id": _issue_id("go_vet", f"{full_path}:{lineno}:{message}"),
                "priority": 2,
                "type": "go_vet",
                "title": f"go vet: {message[:80]}",
                "description": f"{full_path}:{lineno}: {message}",
                "files": [full_path],
                "context": line.strip(),
            }
        )
        if len(issues) >= max_per_type:
            break
    return issues


# ---------------------------------------------------------------------------
# Source 7: Go functions with 0% test coverage
# ---------------------------------------------------------------------------

_GO_FUNC_RE = re.compile(r"^(\S+)\s+(\S+)\s+(\d+\.\d+)%$")


def discover_uncovered_functions(repo_dir: Path, max_per_type: int) -> list[Issue]:
    temporal_dir = repo_dir / "temporal"
    if not temporal_dir.is_dir():
        return []

    cover_file = "/tmp/sail-coverage.out"
    try:
        subprocess.run(
            ["go", "test", "./...", f"-coverprofile={cover_file}", "-covermode=set"],
            cwd=temporal_dir,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    try:
        func_result = subprocess.run(
            ["go", "tool", "cover", f"-func={cover_file}"],
            cwd=temporal_dir,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    issues: list[Issue] = []
    for line in func_result.stdout.splitlines():
        m = _GO_FUNC_RE.match(line.strip())
        if not m:
            continue
        file_func, func_name, pct_str = m.group(1), m.group(2), m.group(3)
        if func_name in ("total:", "init"):
            continue
        if float(pct_str) > 0:
            continue
        # file_func is like "temporal-orchestration/internal/activities/command.go:RunCommand"
        file_path = file_func.rsplit(":", 1)[0] if ":" in file_func else file_func
        issues.append(
            {
                "id": _issue_id("go_coverage", f"{file_func}"),
                "priority": 3,
                "type": "go_coverage",
                "title": f"Uncovered function: {func_name} in {Path(file_path).name}",
                "description": (
                    f"{file_path}: function {func_name!r} has 0% test coverage. "
                    "Consider adding a unit test."
                ),
                "files": [file_path],
                "context": line.strip(),
            }
        )
        if len(issues) >= max_per_type:
            break
    return issues


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Discover actionable issues in sygaldry repo")
    parser.add_argument("--repo-dir", default=".", help="Repository root (default: $PWD)")
    parser.add_argument("--max-per-type", type=int, default=10,
                        help="Max issues per source type (default: 10)")
    parser.add_argument("--min-priority", type=int, default=3,
                        help="Only emit issues with priority <= this (default: 3 = all)")
    parser.add_argument("--stats-file", help="Write discovery timing/count metadata to this JSON file")
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    max_per = args.max_per_type

    overall_started_at = _utc_now()
    overall_start = time.perf_counter()
    all_issues: list[Issue] = []
    source_stats: list[dict[str, Any]] = []
    for name, func in (
        ("go_test", discover_go_test_failures),
        ("go_vet", discover_go_vet),
        ("shellcheck", discover_shellcheck),
        ("todo", discover_todos),
        ("ruff", discover_ruff),
        ("foundation_drift", discover_foundation_drift),
        ("go_coverage", discover_uncovered_functions),
    ):
        issues, stats = _run_source(name, func, repo_dir, max_per)
        all_issues.extend(issues)
        source_stats.append(stats)

    filtered = [i for i in all_issues if i["priority"] <= args.min_priority]
    filtered.sort(key=lambda i: (i["priority"], i["id"]))

    if args.stats_file:
        stats_payload = {
            "repoDir": str(repo_dir),
            "mode": "discover",
            "startedAt": overall_started_at,
            "finishedAt": _utc_now(),
            "durationSec": round(time.perf_counter() - overall_start, 3),
            "discoveredCount": len(all_issues),
            "selectedCount": len(filtered),
            "sources": source_stats,
        }
        Path(args.stats_file).write_text(
            json.dumps(stats_payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    json.dump(filtered, sys.stdout, indent=2)
    print()  # trailing newline


if __name__ == "__main__":
    main()
