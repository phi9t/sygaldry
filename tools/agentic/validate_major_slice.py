#!/usr/bin/env python3
"""
tools/agentic/validate_major_slice.py — Run the standard SAIL gate plus extra commands.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def run_command(repo_dir: Path, command: str) -> int:
    print(f"[major-validate] {command}", flush=True)
    process = subprocess.run(
        ["bash", "-lc", command],
        cwd=repo_dir,
        text=True,
        capture_output=True,
        check=False,
    )
    if process.stdout:
        sys.stdout.write(process.stdout)
    if process.stderr:
        sys.stderr.write(process.stderr)
    return process.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a major SAIL slice")
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--issue-json", required=True)
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    issue = json.loads(args.issue_json)
    commands = ["./validate_all.sh --quick"]
    for command in issue.get("validationCommands", []):
        if command != "./validate_all.sh --quick":
            commands.append(str(command))

    for command in commands:
        exit_code = run_command(repo_dir, command)
        if exit_code != 0:
            return exit_code
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
