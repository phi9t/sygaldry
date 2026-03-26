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
  8. Rust functions with 0 execution count via cargo-llvm-cov
  9. Open RFCs listed in docs/RFC-INDEX.md

Output: JSON array of issues sorted by priority (1=critical, 2=high, 3=normal),
        printed to stdout. Each issue has the shape:
        {
          "id":          "<type>-<hash>",
          "priority":    1|2|3,
          "type":        "todo|shellcheck|go_test|ruff|foundation_drift|go_vet|go_coverage|rust_coverage|cargo_clippy|rfc",
          "title":       "<short description>",
          "description": "<detail>",
          "files":       ["<path>", ...],
          "context":     "<extra context>"
        }

Usage:
  python3 tools/agentic/discover_issues.py [--repo-dir <path>] [--max-per-type N] [--sources <name,name,...>]
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
    TimeoutError as FuturesTimeoutError,
)
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

Issue = dict[str, Any]
SourceFunc = Callable[[Path, int], list[Issue]]

SOURCE_TIMEOUT_SECS = 120
GO_COVERAGE_FILE_ENV = "SAIL_GO_COVERAGE_FILE"
RUST_COVERAGE_FILE_ENV = "SAIL_RUST_COVERAGE_FILE"


def _issue_id(issue_type: str, data: str) -> str:
    h = hashlib.sha1(data.encode()).hexdigest()[:8]
    return f"{issue_type}-{h}"


def _utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")


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


def _dedup(issues: list[Issue]) -> list[Issue]:
    seen: set[str] = set()
    deduped: list[Issue] = []
    for issue in issues:
        issue_id = issue["id"]
        if issue_id not in seen:
            seen.add(issue_id)
            deduped.append(issue)
    return deduped


# ---------------------------------------------------------------------------
# Source 1: TODO/FIXME/HACK comments
# ---------------------------------------------------------------------------

_TODO_RE = re.compile(r"(TODO|FIXME|HACK)\b[:\s]*(.*)", re.IGNORECASE)
_DOC_TODO_RE = re.compile(
    r"^\s*(?:[-*+]\s+|\d+\.\s+|\*+\s+|#+\s+)?(TODO|FIXME|HACK)\b[:\s]*(.*)",
    re.IGNORECASE,
)
_DOC_TODO_EXTENSIONS = {".md", ".markdown", ".org", ".rst", ".txt"}


def _strip_comment_closer(text: str) -> str:
    return re.sub(r"\s*(?:\*/|-->)\s*$", "", text).strip()


def _extract_unquoted_comment(content: str) -> str | None:
    quote = ""
    escaped = False
    index = 0
    while index < len(content):
        char = content[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\" and quote in {'"', "'", "`"}:
                escaped = True
            elif char == quote:
                quote = ""
            index += 1
            continue
        if char in {'"', "'", "`"}:
            quote = char
            index += 1
            continue
        if content.startswith("<!--", index):
            return content[index:]
        if content.startswith("//", index):
            return content[index:]
        if content.startswith("/*", index):
            return content[index:]
        if char == "#":
            return content[index:]
        index += 1

    stripped = content.lstrip()
    if stripped.startswith("*"):
        return stripped
    return None


def _match_todo_annotation(file_path: str, content: str) -> tuple[str, str] | None:
    if Path(file_path).suffix.lower() in _DOC_TODO_EXTENSIONS:
        match = _DOC_TODO_RE.match(content)
        if not match:
            return None
    else:
        comment = _extract_unquoted_comment(content)
        if not comment:
            return None
        match = _TODO_RE.search(comment)
        if not match:
            return None

    tag = match.group(1).upper()
    desc = _strip_comment_closer(match.group(2)) or f"Unaddressed {tag}"
    return tag, desc


def discover_todos(repo_dir: Path, max_per_type: int) -> list[Issue]:
    try:
        result = subprocess.run(
            [
                "git",
                "grep",
                "-n",
                "-E",
                r"TODO|FIXME|HACK",
                "--",
                ".",
                ":(exclude)tools/agentic/discover_issues.py",
                ":(exclude)crates/zephyr/DESIGN.org",
            ],
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
        annotation = _match_todo_annotation(file_path, content)
        if not annotation:
            continue
        tag, desc = annotation
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
        f
        for f in sh_files
        if not any(
            part.startswith(".") or part in ("node_modules", "vendor")
            for part in f.parts
        )
    ]
    if not sh_files:
        return []

    try:
        result = subprocess.run(
            [
                "shellcheck",
                "-f",
                "json",
                "-S",
                "warning",
                "--",
                *[str(f) for f in sh_files],
            ],
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
# Source 3: go test failures and coverage
# ---------------------------------------------------------------------------

_GO_FUNC_RE = re.compile(r"^(\S+)\s+(\S+)\s+(\d+\.\d+)%$")


def discover_go_tests_and_coverage(repo_dir: Path, max_per_type: int) -> list[Issue]:
    temporal_dir = repo_dir / "temporal"
    if not temporal_dir.is_dir():
        return []

    cover_file = os.environ.get(GO_COVERAGE_FILE_ENV, "/tmp/sail-coverage.out")
    try:
        # Run go test with -json for failure detection AND -coverprofile for coverage analysis
        result = subprocess.run(
            [
                "go",
                "test",
                "./...",
                "-json",
                f"-coverprofile={cover_file}",
                "-covermode=set",
            ],
            cwd=temporal_dir,
            capture_output=True,
            text=True,
            timeout=180,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    # Part 1: Collect failures from JSON stream
    failures: list[dict[str, Any]] = []
    # Note: go test might exit non-zero if tests fail, but we still want to parse stdout
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

    # Part 2: Collect zero-coverage functions
    if not Path(cover_file).exists():
        return issues

    try:
        func_result = subprocess.run(
            ["go", "tool", "cover", f"-func={cover_file}"],
            cwd=temporal_dir,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return issues

    coverage_count = 0
    for line in func_result.stdout.splitlines():
        m = _GO_FUNC_RE.match(line.strip())
        if not m:
            continue
        file_func, func_name, pct_str = m.group(1), m.group(2), m.group(3)
        if func_name in ("total:", "init", "main"):
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
        coverage_count += 1
        if coverage_count >= max_per_type:
            break

    return issues


def discover_uncovered_rust_functions(repo_dir: Path, max_per_type: int) -> list[Issue]:
    rust_crate_dir = repo_dir / "crates" / "zephyr"
    if not rust_crate_dir.is_dir():
        return []

    coverage_file = Path(
        os.environ.get(RUST_COVERAGE_FILE_ENV, "/tmp/sail-rust-coverage.json")
    )

    try:
        probe = subprocess.run(
            ["cargo", "llvm-cov", "--version"],
            cwd=rust_crate_dir,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        print(
            "Warning: cargo llvm-cov is unavailable; skipping rust coverage discovery",
            file=sys.stderr,
        )
        return []

    if probe.returncode != 0:
        print(
            "Warning: cargo llvm-cov is unavailable; skipping rust coverage discovery",
            file=sys.stderr,
        )
        return []

    coverage_file.unlink(missing_ok=True)

    try:
        result = subprocess.run(
            [
                "cargo",
                "llvm-cov",
                "--json",
                "--output-path",
                str(coverage_file),
            ],
            cwd=rust_crate_dir,
            capture_output=True,
            text=True,
            timeout=300,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    if result.returncode != 0 and not coverage_file.exists():
        print(
            "Warning: cargo llvm-cov failed; skipping rust coverage discovery",
            file=sys.stderr,
        )
        return []

    try:
        payload = json.loads(coverage_file.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return []

    issues: list[Issue] = []
    for datum in payload.get("data", []):
        for file_entry in datum.get("files", []):
            filename = file_entry.get("filename", "")
            if not filename:
                continue
            for function in file_entry.get("functions", []):
                name = function.get("name", "")
                count = function.get("count")
                if not name or count is None or count != 0:
                    continue
                issues.append(
                    {
                        "id": _issue_id("rust_coverage", f"{filename}:{name}"),
                        "priority": 2,
                        "type": "rust_coverage",
                        "title": f"Uncovered Rust function: {name}",
                        "description": (
                            f"{filename}: function {name!r} has 0 execution count in cargo llvm-cov output. "
                            "Consider adding a Rust test."
                        ),
                        "files": [filename],
                        "context": json.dumps(function, sort_keys=True),
                    }
                )
                if len(issues) >= max_per_type:
                    return issues
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
    for rel_path in referenced_files[: max_per_type * 4]:
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
# Source 9: Open RFCs from docs/RFC-INDEX.md
# ---------------------------------------------------------------------------

_RFC_ROW_RE = re.compile(
    r"^\|\s*RFC-(\d+)\s*\|([^|]+)\|([^|]+)\|([^|]+)\|",
)
_RFC_PRIORITY_MAP = {
    "high": 1,
    "medium": 2,
    "low": 3,
}


def discover_open_rfcs(repo_dir: Path, max_per_type: int) -> list[Issue]:
    index_file = repo_dir / "docs" / "RFC-INDEX.md"
    if not index_file.exists():
        return []

    text = index_file.read_text(errors="replace")

    in_open_section = False
    issues: list[Issue] = []
    for line in text.splitlines():
        if "## Open RFCs" in line:
            in_open_section = True
            continue
        if in_open_section and line.startswith("## "):
            break
        if not in_open_section:
            continue

        m = _RFC_ROW_RE.match(line)
        if not m:
            continue

        rfc_num = m.group(1).strip()
        title_text = m.group(2).strip()
        priority_text = m.group(4).strip().lower()
        priority = _RFC_PRIORITY_MAP.get(priority_text, 2)

        rfc_id = f"RFC-{rfc_num}"
        rfc_files = sorted(repo_dir.glob(f"docs/{rfc_id}-*.md"))
        rfc_file = (
            str(rfc_files[0].relative_to(repo_dir))
            if rfc_files
            else f"docs/{rfc_id}-*.md"
        )

        issues.append(
            {
                "id": f"rfc-{rfc_num}",
                "priority": priority,
                "type": "rfc",
                "title": f"{rfc_id}: {title_text}",
                "description": f"Open RFC — implement as described in {rfc_file}",
                "files": ["tools/agentic/discover_issues.py"],
                "context": f"See {rfc_file} for full spec and acceptance criteria.",
            }
        )
        if len(issues) >= max_per_type:
            break

    return issues


# ---------------------------------------------------------------------------
# Source 10: cargo clippy errors
# ---------------------------------------------------------------------------


def discover_cargo_clippy(repo_dir: Path, max_per_type: int) -> list[Issue]:
    if shutil.which("cargo") is None:
        return []

    crate_dir = repo_dir / "crates" / "zephyr"
    manifest = crate_dir / "Cargo.toml"
    if not manifest.exists():
        return []

    env = dict(os.environ)

    toolchain_file = crate_dir / "rust-toolchain.toml"
    if toolchain_file.exists() and shutil.which("rustup") is not None:
        try:
            channel_result = subprocess.run(
                ["grep", "-o", 'channel = "[^"]*"', str(toolchain_file)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            channel_raw = channel_result.stdout.strip()
            if channel_raw:
                channel = channel_raw.split('"')[1]
                triple_result = subprocess.run(
                    ["rustc", "-vV"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                triple = ""
                for line in triple_result.stdout.splitlines():
                    if line.startswith("host:"):
                        triple = line.split(None, 1)[1].strip()
                        break
                if channel and triple:
                    home = os.environ.get("HOME", "")
                    tc_bin = os.path.join(
                        home, ".rustup", "toolchains", f"{channel}-{triple}", "bin"
                    )
                    if os.path.isfile(os.path.join(tc_bin, "cargo")) and os.access(
                        os.path.join(tc_bin, "cargo"), os.X_OK
                    ):
                        env["PATH"] = tc_bin + ":" + env.get("PATH", "")
        except (subprocess.TimeoutExpired, FileNotFoundError, IndexError):
            pass

    try:
        result = subprocess.run(
            [
                "cargo",
                "clippy",
                "--manifest-path",
                str(manifest),
                "--message-format",
                "json",
                "--",
                "-D",
                "warnings",
            ],
            cwd=repo_dir,
            capture_output=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=120,
            env=env,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    issues: list[Issue] = []
    for line in result.stdout.splitlines():
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("reason") != "compiler-message":
            continue
        inner = msg.get("message", {})
        if inner.get("level") != "error":
            continue
        rendered = inner.get("rendered", inner.get("message", ""))
        spans = inner.get("spans", [])
        if spans:
            file_path = spans[0].get("file_name", str(crate_dir))
            lineno = spans[0].get("line_start", 0)
            cite = f"{file_path}:{lineno}"
        else:
            file_path = str(crate_dir)
            cite = str(crate_dir)

        text_key = f"{file_path}:{lineno if spans else 0}:{rendered[:120]}"
        issues.append(
            {
                "id": _issue_id("cargo_clippy", text_key),
                "priority": 2,
                "type": "cargo_clippy",
                "title": f"clippy error: {rendered[:80].splitlines()[0] if rendered else 'error'}",
                "description": f"{cite}: {rendered[:200]}",
                "files": [file_path],
                "context": rendered[:500],
            }
        )
        if len(issues) >= max_per_type:
            break
    return issues


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Discover actionable issues in sygaldry repo"
    )
    parser.add_argument(
        "--repo-dir", default=".", help="Repository root (default: $PWD)"
    )
    parser.add_argument(
        "--max-per-type",
        type=int,
        default=10,
        help="Max issues per source type (default: 10)",
    )
    parser.add_argument(
        "--min-priority",
        type=int,
        default=3,
        help="Only emit issues with priority <= this (default: 3 = all)",
    )
    parser.add_argument(
        "--stats-file", help="Write discovery timing/count metadata to this JSON file"
    )
    parser.add_argument(
        "--sources",
        help="Comma-separated list of source names to run (e.g. shellcheck,ruff)",
    )
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    max_per = args.max_per_type

    overall_started_at = _utc_now()
    overall_start = time.perf_counter()
    all_issues: list[Issue] = []
    source_stats: list[dict[str, Any]] = []

    sources = [
        ("go_tests_and_coverage", discover_go_tests_and_coverage),
        ("rust_coverage", discover_uncovered_rust_functions),
        ("go_vet", discover_go_vet),
        ("shellcheck", discover_shellcheck),
        ("todo", discover_todos),
        ("ruff", discover_ruff),
        ("foundation_drift", discover_foundation_drift),
        ("open_rfcs", discover_open_rfcs),
        ("cargo_clippy", discover_cargo_clippy),
    ]

    if args.sources:
        names = {s.strip() for s in args.sources.split(",")}
        sources = [(n, f) for n, f in sources if n in names]

    with ThreadPoolExecutor(max_workers=len(sources) or 1) as executor:
        future_to_name = {
            executor.submit(_run_source, name, func, repo_dir, max_per): name
            for name, func in sources
        }

        for future in as_completed(future_to_name):
            name = future_to_name[future]
            try:
                issues, stats = future.result(timeout=SOURCE_TIMEOUT_SECS)
                all_issues.extend(issues)
                source_stats.append(stats)
            except FuturesTimeoutError:
                print(
                    f"Warning: source {name!r} timed out after {SOURCE_TIMEOUT_SECS}s",
                    file=sys.stderr,
                )
                source_stats.append(
                    {
                        "name": name,
                        "startedAt": _utc_now(),
                        "finishedAt": _utc_now(),
                        "durationSec": float(SOURCE_TIMEOUT_SECS),
                        "count": 0,
                        "error": f"FuturesTimeoutError: exceeded {SOURCE_TIMEOUT_SECS}s",
                    }
                )
            except Exception as exc:  # pragma: no cover
                print(
                    f"Error: source {name!r} failed with unexpected error: {exc}",
                    file=sys.stderr,
                )
                source_stats.append(
                    {
                        "name": name,
                        "startedAt": _utc_now(),
                        "finishedAt": _utc_now(),
                        "durationSec": 0.0,
                        "count": 0,
                        "error": f"UnexpectedError: {exc}",
                    }
                )

    all_issues = _dedup(all_issues)
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
