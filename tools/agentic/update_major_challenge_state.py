#!/usr/bin/env python3
"""
tools/agentic/update_major_challenge_state.py — Persist major challenge progress.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")


def runtime_state_file(runtime_root: Path) -> Path:
    return runtime_root / "major_challenges" / "state.json"


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {
            "emptyDiscoveryStreak": 0,
            "activeChallengeId": "",
            "updatedAt": "",
            "challenges": {},
        }
    return json.loads(path.read_text(encoding="utf-8"))


def save_state(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload["updatedAt"] = utc_now()
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def read_slice_state(path: Path, issue: dict[str, Any]) -> dict[str, Any]:
    default = {
        "sliceIndex": int(issue.get("sliceIndex", 1)),
        "sliceTitle": str(issue.get("title", "")),
        "postSuccessChallengeStatus": "active",
    }
    if not path.exists():
        return default
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        return default
    default.update(payload)
    return default


def current_head(repo_dir: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(repo_dir), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return ""


def append_history(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(record, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Update major challenge runtime state")
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--issue-json", required=True)
    parser.add_argument(
        "--attempt-status", required=True, choices=["success", "failed", "skipped"]
    )
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--workflow-id", default="")
    parser.add_argument("--temporal-run-id", default="")
    parser.add_argument("--max-failed-runs", type=int, default=3)
    parser.add_argument("--note", default="")
    args = parser.parse_args()

    issue = json.loads(args.issue_json)
    challenge_id = str(issue["challengeId"])
    runtime_root = Path(args.runtime_root).resolve()
    repo_dir = Path(args.repo_dir).resolve()
    state_file = runtime_state_file(runtime_root)
    payload = load_state(state_file)
    challenges = payload.setdefault("challenges", {})
    challenge_state = dict(challenges.get(challenge_id, {}))

    slice_state_file = Path(str(issue.get("sliceStateFile", "")))
    slice_state = read_slice_state(slice_state_file, issue)
    challenge_state.setdefault("nextSlice", int(issue.get("sliceIndex", 1)))
    challenge_state.setdefault("consecutiveFailures", 0)
    challenge_state.setdefault("historyFile", str(issue.get("historyFile", "")))
    challenge_state.setdefault("epicPlanFile", str(issue.get("epicPlanFile", "")))
    challenge_state.setdefault("sliceStateFile", str(issue.get("sliceStateFile", "")))
    challenge_state["lastRunId"] = args.run_id
    challenge_state["lastIssueId"] = str(issue.get("id", ""))
    challenge_state["updatedAt"] = utc_now()

    if args.attempt_status == "success":
        challenge_state["consecutiveFailures"] = 0
        challenge_state["lastCommit"] = current_head(repo_dir)
        if slice_state.get("postSuccessChallengeStatus") == "complete":
            challenge_state["status"] = "complete"
            payload["activeChallengeId"] = ""
        else:
            challenge_state["status"] = "active"
            challenge_state["nextSlice"] = (
                int(slice_state.get("sliceIndex", challenge_state["nextSlice"])) + 1
            )
            payload["activeChallengeId"] = challenge_id
    elif args.attempt_status == "failed":
        challenge_state["consecutiveFailures"] = (
            int(challenge_state.get("consecutiveFailures", 0)) + 1
        )
        if challenge_state["consecutiveFailures"] >= args.max_failed_runs:
            challenge_state["status"] = "blocked"
            payload["activeChallengeId"] = ""
        else:
            challenge_state["status"] = "active"
            payload["activeChallengeId"] = challenge_id
    else:
        challenge_state["status"] = challenge_state.get("status", "active") or "active"

    challenges[challenge_id] = challenge_state
    history_file = Path(str(challenge_state.get("historyFile", "")))
    append_history(
        history_file,
        {
            "timestamp": utc_now(),
            "challengeId": challenge_id,
            "issueId": str(issue.get("id", "")),
            "sliceIndex": int(
                slice_state.get("sliceIndex", issue.get("sliceIndex", 1))
            ),
            "sliceTitle": str(slice_state.get("sliceTitle", issue.get("title", ""))),
            "status": args.attempt_status,
            "workflowId": args.workflow_id,
            "temporalRunId": args.temporal_run_id,
            "runId": args.run_id,
            "note": args.note,
            "postSuccessChallengeStatus": str(
                slice_state.get("postSuccessChallengeStatus", "active")
            ),
        },
    )
    save_state(state_file, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
