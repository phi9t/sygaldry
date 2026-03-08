#!/usr/bin/env python3
"""
tools/agentic/check_major_slice_scope.py — Guard major slices from growing too large.
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Check major slice diff size")
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--max-files", type=int, required=True)
    parser.add_argument("--max-lines", type=int, required=True)
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    result = subprocess.run(
        ["git", "-C", str(repo_dir), "diff", "--numstat", "--find-renames", "HEAD"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(result.returncode)

    files_changed = 0
    lines_changed = 0
    for line in result.stdout.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        added, deleted, _ = parts
        files_changed += 1
        if added.isdigit():
            lines_changed += int(added)
        if deleted.isdigit():
            lines_changed += int(deleted)

    if files_changed > args.max_files or lines_changed > args.max_lines:
        print(
            f"major slice scope exceeded: files={files_changed}/{args.max_files} "
            f"lines={lines_changed}/{args.max_lines}"
        )
        return 1
    print(
        f"major slice scope ok: files={files_changed}/{args.max_files} "
        f"lines={lines_changed}/{args.max_lines}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
