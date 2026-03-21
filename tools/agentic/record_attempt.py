#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path


def record_attempt(
    path: Path,
    issue_id: str,
    status: str,
    branch: str,
    pr_url: str,
    workflow_id: str,
    temporal_run_id: str,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "issue_id": issue_id,
        "status": status,
        "branch": branch,
        "pr_url": pr_url,
        "workflow_id": workflow_id,
        "temporal_run_id": temporal_run_id,
        "timestamp": dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z"),
    }
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(record, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", required=True, type=Path)
    parser.add_argument("--issue-id", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--branch", default="")
    parser.add_argument("--pr-url", default="")
    parser.add_argument("--workflow-id", default="")
    parser.add_argument("--temporal-run-id", default="")
    args = parser.parse_args()

    record_attempt(
        args.path,
        args.issue_id,
        args.status,
        args.branch,
        args.pr_url,
        args.workflow_id,
        args.temporal_run_id,
    )


if __name__ == "__main__":
    main()
