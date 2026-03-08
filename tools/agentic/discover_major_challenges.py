#!/usr/bin/env python3
"""
tools/agentic/discover_major_challenges.py — Emit one curated major SAIL challenge.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
from typing import Any

import yaml

Issue = dict[str, Any]


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")


def runtime_state_paths(runtime_root: Path) -> tuple[Path, Path]:
    root = runtime_root / "major_challenges"
    return root, root / "state.json"


def default_state() -> dict[str, Any]:
    return {
        "emptyDiscoveryStreak": 0,
        "activeChallengeId": "",
        "updatedAt": "",
        "challenges": {},
    }


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as file:
        payload = yaml.safe_load(file) or {}
    if not isinstance(payload, dict):
        raise ValueError(f"expected mapping in {path}")
    return payload


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return default_state()
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        return default_state()
    merged = default_state()
    merged.update(payload)
    merged["challenges"] = dict(payload.get("challenges", {}))
    return merged


def save_state(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload["updatedAt"] = utc_now()
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def ensure_challenge_state(
    payload: dict[str, Any], challenge: dict[str, Any], state_root: Path
) -> dict[str, Any]:
    challenge_id = str(challenge["id"])
    current = dict(payload["challenges"].get(challenge_id, {}))
    state_dir = state_root / challenge_id
    current.setdefault("status", "new")
    current.setdefault("nextSlice", 1)
    current.setdefault("consecutiveFailures", 0)
    current.setdefault("lastRunId", "")
    current.setdefault("lastIssueId", "")
    current.setdefault("lastCommit", "")
    current.setdefault("updatedAt", "")
    current.setdefault("epicPlanFile", str(state_dir / "epic_plan.md"))
    current.setdefault("sliceStateFile", str(state_dir / "slice_state.json"))
    current.setdefault("historyFile", str(state_dir / "history.jsonl"))
    current["maxSlices"] = int(challenge.get("max_slices", current.get("maxSlices", 1)))
    payload["challenges"][challenge_id] = current
    return current


def eligible_challenges(
    backlog: dict[str, Any], state: dict[str, Any], state_root: Path
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    items: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for challenge in backlog.get("challenges", []):
        if not isinstance(challenge, dict):
            continue
        if not challenge.get("enabled", True):
            continue
        if not challenge.get("id") or not challenge.get("title"):
            continue
        challenge_state = ensure_challenge_state(state, challenge, state_root)
        if challenge_state.get("status") in {"complete", "blocked"}:
            continue
        items.append((challenge, challenge_state))
    items.sort(key=lambda item: (int(item[0].get("priority", 99)), str(item[0]["id"])))
    return items


def choose_challenge(
    candidates: list[tuple[dict[str, Any], dict[str, Any]]], active_id: str
) -> tuple[dict[str, Any], dict[str, Any]] | None:
    if active_id:
        for challenge, challenge_state in candidates:
            if str(challenge["id"]) == active_id:
                return challenge, challenge_state
    return candidates[0] if candidates else None


def build_issue(
    challenge: dict[str, Any], challenge_state: dict[str, Any], repo_dir: Path
) -> Issue:
    challenge_id = str(challenge["id"])
    slice_index = int(challenge_state.get("nextSlice", 1))
    challenge_title = str(challenge["title"]).strip()
    lowered_title = challenge_title.lower()
    if lowered_title.startswith("advance "):
        issue_title = f"{lowered_title} (slice {slice_index})"
    else:
        issue_title = f"advance {lowered_title} (slice {slice_index})"
    target_paths = [str(path) for path in challenge.get("target_paths", [])]
    context_files = [str(path) for path in challenge.get("context_files", [])]
    completion_criteria = [
        str(item) for item in challenge.get("completion_criteria", [])
    ]
    validation_commands = [
        str(item) for item in challenge.get("validation_commands", [])
    ]
    description = (
        f"Curated major redesign challenge '{challenge_id}' "
        f"(slice {slice_index} of up to {challenge_state.get('maxSlices', challenge.get('max_slices', 1))})."
    )
    return {
        "id": f"major-{challenge_id}-slice-{slice_index}",
        "priority": int(challenge.get("priority", 3)),
        "type": "major_challenge",
        "title": issue_title,
        "description": description,
        "files": target_paths,
        "context": str(challenge.get("summary", "")),
        "challengeId": challenge_id,
        "challengeTitle": challenge_title,
        "challengeSummary": str(challenge.get("summary", "")),
        "contextFiles": context_files,
        "targetPaths": target_paths,
        "completionCriteria": completion_criteria,
        "validationCommands": validation_commands,
        "maxSlices": int(
            challenge.get("max_slices", challenge_state.get("maxSlices", 1))
        ),
        "sliceIndex": slice_index,
        "repoDir": str(repo_dir),
        "stateDir": str(Path(challenge_state["epicPlanFile"]).parent),
        "epicPlanFile": challenge_state["epicPlanFile"],
        "sliceStateFile": challenge_state["sliceStateFile"],
        "historyFile": challenge_state["historyFile"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Emit one curated major SAIL challenge"
    )
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--backlog-file")
    parser.add_argument("--empty-streak", type=int, default=0)
    parser.add_argument("--min-empty-streak", type=int, default=3)
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    runtime_root = Path(args.runtime_root).resolve()
    backlog_file = (
        Path(args.backlog_file).resolve()
        if args.backlog_file
        else repo_dir / "tools" / "agentic" / "major_challenges.yaml"
    )

    backlog = load_yaml(backlog_file)
    state_root, state_file = runtime_state_paths(runtime_root)
    state = load_state(state_file)
    state["emptyDiscoveryStreak"] = max(0, int(args.empty_streak))

    issues: list[Issue] = []
    if args.empty_streak >= args.min_empty_streak:
        selected = choose_challenge(
            eligible_challenges(backlog, state, state_root),
            str(state.get("activeChallengeId", "")),
        )
        if selected is not None:
            challenge, challenge_state = selected
            state["activeChallengeId"] = str(challenge["id"])
            issues.append(build_issue(challenge, challenge_state, repo_dir))

    save_state(state_file, state)
    print(json.dumps(issues, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
