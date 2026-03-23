#!/usr/bin/env python3
"""
tools/agentic/close_rfc.py — Mark an RFC as Done after SAIL lands a fix.

Usage:
  python3 tools/agentic/close_rfc.py --repo-dir <path> --issue-id rfc-054 --commit-sha <sha>

Steps:
  1. Derive the RFC filename: rfc-054 -> docs/RFC-054-*.md (first match).
  2. Replace `**Status:** Draft*` with `**Status:** Done — SAIL (commit <sha>)`.
  3. In docs/RFC-INDEX.md, move the row from Open to Closed; update header counts.
  4. Stage both files with `git add` and amend into the landing commit.
     Falls back to a new commit if amend fails.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


def _find_rfc_file(repo_dir: Path, rfc_id: str) -> Path | None:
    num = rfc_id.upper().removeprefix("RFC-")
    matches = sorted(repo_dir.glob(f"docs/RFC-{num}-*.md"))
    return matches[0] if matches else None


def _update_rfc_status(rfc_file: Path, commit_sha: str) -> bool:
    text = rfc_file.read_text(encoding="utf-8")
    new_text, n = re.subn(
        r"(\*\*Status:\*\*\s*)Draft.*",
        rf"\g<1>Done — SAIL (commit {commit_sha})",
        text,
    )
    if n == 0:
        return False
    rfc_file.write_text(new_text, encoding="utf-8")
    return True


def _update_index(repo_dir: Path, rfc_id: str, title: str) -> bool:
    index_file = repo_dir / "docs" / "RFC-INDEX.md"
    if not index_file.exists():
        return False

    text = index_file.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    num = rfc_id.upper().removeprefix("RFC-")
    row_pattern = re.compile(rf"^\|\s*RFC-{num}\s*\|")

    # Find and remove from Open section
    open_row: str | None = None
    new_lines: list[str] = []
    in_open = False
    for line in lines:
        if "## Open RFCs" in line:
            in_open = True
        elif in_open and line.startswith("## "):
            in_open = False
        if in_open and row_pattern.match(line):
            open_row = line
            continue  # remove from Open section
        new_lines.append(line)

    if open_row is None:
        return False

    # Update Open count in header
    result_text = "".join(new_lines)
    result_text = re.sub(
        r"(\*\*Total RFCs:\*\*\s*)(\d+)\s*open",
        lambda m: f"{m.group(1)}{max(0, int(m.group(2)) - 1)} open",
        result_text,
    )

    # Append row to Closed table
    closed_row = f"| {rfc_id.upper()} | {title} | Done — SAIL |\n"
    closed_table_re = re.compile(r"(## Closed RFCs\s*\n(?:\|.*\|\n)+)", re.MULTILINE)
    m = closed_table_re.search(result_text)
    if m:
        insert_pos = m.end()
        result_text = result_text[:insert_pos] + closed_row + result_text[insert_pos:]
    else:
        # Fallback: append before end of file
        result_text = result_text.rstrip("\n") + "\n" + closed_row

    index_file.write_text(result_text, encoding="utf-8")
    return True


def _git_stage(repo_dir: Path, *files: Path) -> None:
    subprocess.run(
        ["git", "add", "--", *[str(f) for f in files]],
        cwd=repo_dir,
        check=True,
    )


def _git_amend(repo_dir: Path) -> bool:
    result = subprocess.run(
        ["git", "commit", "--amend", "--no-edit"],
        cwd=repo_dir,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def _git_commit_new(repo_dir: Path, rfc_id: str) -> None:
    subprocess.run(
        [
            "git",
            "commit",
            "-m",
            f"docs: close {rfc_id.upper()} in index (SAIL landed fix)",
        ],
        cwd=repo_dir,
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Close an RFC after SAIL lands a fix")
    parser.add_argument("--repo-dir", default=".", help="Repository root")
    parser.add_argument("--issue-id", required=True, help="RFC issue id, e.g. rfc-054")
    parser.add_argument("--commit-sha", required=True, help="Landing commit SHA")
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    issue_id = args.issue_id.lower()
    commit_sha = args.commit_sha[:12] if len(args.commit_sha) > 12 else args.commit_sha

    rfc_file = _find_rfc_file(repo_dir, issue_id)
    if rfc_file is None:
        print(f"close_rfc: no RFC file found for {issue_id}, skipping", file=sys.stderr)
        sys.exit(0)

    # Extract title from RFC file for index row
    title = issue_id.upper()
    for line in rfc_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("# RFC-"):
            title = line.lstrip("# ").strip()
            # Strip "RFC-NNN: " prefix if present
            title = re.sub(r"^RFC-\d+:\s*", "", title)
            break

    changed_files: list[Path] = []

    if _update_rfc_status(rfc_file, commit_sha):
        changed_files.append(rfc_file)

    if _update_index(repo_dir, issue_id, title):
        changed_files.append(repo_dir / "docs" / "RFC-INDEX.md")

    if not changed_files:
        print(f"close_rfc: nothing to update for {issue_id}", file=sys.stderr)
        sys.exit(0)

    _git_stage(repo_dir, *changed_files)

    if not _git_amend(repo_dir):
        _git_commit_new(repo_dir, issue_id)

    print(f"close_rfc: closed {issue_id.upper()} (commit {commit_sha})")


if __name__ == "__main__":
    main()
