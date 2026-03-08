from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DISCOVER_PATH = REPO_ROOT / "tools" / "agentic" / "discover_major_challenges.py"
UPDATE_PATH = REPO_ROOT / "tools" / "agentic" / "update_major_challenge_state.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_backlog(path: Path) -> None:
    path.write_text(
        """
version: 1
challenges:
  - id: alpha
    title: Alpha challenge
    priority: 2
    enabled: true
    summary: alpha summary
    context_files: [foundation.org]
    target_paths: [temporal/]
    completion_criteria: [alpha done]
    validation_commands: ["./validate_all.sh --quick"]
    max_slices: 4
  - id: beta
    title: Beta challenge
    priority: 1
    enabled: true
    summary: beta summary
    context_files: [foundation.org]
    target_paths: [container/]
    completion_criteria: [beta done]
    validation_commands: ["./validate_all.sh --quick"]
    max_slices: 2
""".strip() + "\n",
        encoding="utf-8",
    )


def test_discover_major_challenges_respects_empty_streak_and_priority(
    tmp_path, monkeypatch, capsys
):
    module = load_module("discover_major_challenges", DISCOVER_PATH)
    backlog_file = tmp_path / "major_challenges.yaml"
    write_backlog(backlog_file)

    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(DISCOVER_PATH),
            "--repo-dir",
            str(REPO_ROOT),
            "--runtime-root",
            str(tmp_path / "runtime"),
            "--backlog-file",
            str(backlog_file),
            "--empty-streak",
            "2",
            "--min-empty-streak",
            "3",
        ],
    )
    assert module.main() == 0
    assert json.loads(capsys.readouterr().out) == []

    state_file = tmp_path / "runtime" / "major_challenges" / "state.json"
    state = json.loads(state_file.read_text(encoding="utf-8"))
    assert state["emptyDiscoveryStreak"] == 2
    assert state["activeChallengeId"] == ""

    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(DISCOVER_PATH),
            "--repo-dir",
            str(REPO_ROOT),
            "--runtime-root",
            str(tmp_path / "runtime"),
            "--backlog-file",
            str(backlog_file),
            "--empty-streak",
            "3",
            "--min-empty-streak",
            "3",
        ],
    )
    assert module.main() == 0
    issues = json.loads(capsys.readouterr().out)
    assert issues[0]["challengeId"] == "beta"

    state = json.loads(state_file.read_text(encoding="utf-8"))
    assert state["activeChallengeId"] == "beta"


def test_discover_major_challenges_prefers_active_challenge(
    tmp_path, monkeypatch, capsys
):
    module = load_module("discover_major_challenges_active", DISCOVER_PATH)
    backlog_file = tmp_path / "major_challenges.yaml"
    write_backlog(backlog_file)
    state_dir = tmp_path / "runtime" / "major_challenges"
    state_dir.mkdir(parents=True)
    state_file = state_dir / "state.json"
    state_file.write_text(
        json.dumps(
            {
                "emptyDiscoveryStreak": 5,
                "activeChallengeId": "alpha",
                "challenges": {"alpha": {"status": "active", "nextSlice": 3}},
            }
        )
        + "\n",
        encoding="utf-8",
    )

    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(DISCOVER_PATH),
            "--repo-dir",
            str(REPO_ROOT),
            "--runtime-root",
            str(tmp_path / "runtime"),
            "--backlog-file",
            str(backlog_file),
            "--empty-streak",
            "5",
            "--min-empty-streak",
            "3",
        ],
    )
    assert module.main() == 0
    issues = json.loads(capsys.readouterr().out)
    assert issues[0]["challengeId"] == "alpha"
    assert issues[0]["sliceIndex"] == 3


def test_update_major_challenge_state_marks_complete(tmp_path, monkeypatch):
    module = load_module("update_major_challenge_state", UPDATE_PATH)
    runtime_root = tmp_path / "runtime"
    state_dir = runtime_root / "major_challenges" / "alpha"
    state_dir.mkdir(parents=True)
    slice_state_file = state_dir / "slice_state.json"
    history_file = state_dir / "history.jsonl"
    slice_state_file.write_text(
        json.dumps(
            {
                "sliceIndex": 2,
                "sliceTitle": "finish alpha",
                "postSuccessChallengeStatus": "complete",
            }
        )
        + "\n",
        encoding="utf-8",
    )
    issue = {
        "id": "major-alpha-slice-2",
        "challengeId": "alpha",
        "title": "advance alpha challenge (slice 2)",
        "sliceIndex": 2,
        "sliceStateFile": str(slice_state_file),
        "historyFile": str(history_file),
        "epicPlanFile": str(state_dir / "epic_plan.md"),
    }

    monkeypatch.setattr(module, "current_head", lambda repo_dir: "abc123")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(UPDATE_PATH),
            "--runtime-root",
            str(runtime_root),
            "--repo-dir",
            str(REPO_ROOT),
            "--issue-json",
            json.dumps(issue),
            "--attempt-status",
            "success",
            "--run-id",
            "run-1",
            "--workflow-id",
            "wf-1",
            "--temporal-run-id",
            "temporal-1",
        ],
    )
    assert module.main() == 0

    payload = json.loads(
        (runtime_root / "major_challenges" / "state.json").read_text(encoding="utf-8")
    )
    assert payload["activeChallengeId"] == ""
    assert payload["challenges"]["alpha"]["status"] == "complete"
    assert payload["challenges"]["alpha"]["lastCommit"] == "abc123"
