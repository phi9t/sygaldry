"""Tests for tools/agentic/update_major_challenge_state.py"""

import json

from tools.agentic.update_major_challenge_state import (
    append_history,
    load_state,
    read_slice_state,
    save_state,
)


def test_load_state_returns_empty_dict_when_missing(tmp_path):
    result = load_state(tmp_path / "nonexistent.json")
    assert result == {
        "emptyDiscoveryStreak": 0,
        "activeChallengeId": "",
        "updatedAt": "",
        "challenges": {},
    }


def test_save_state_injects_updated_at(tmp_path):
    path = tmp_path / "state.json"
    save_state(path, {"key": "value"})
    data = json.loads(path.read_text())
    assert "updatedAt" in data
    assert data["updatedAt"] != ""


def test_save_state_roundtrip(tmp_path):
    path = tmp_path / "state.json"
    payload = {"activeChallengeId": "c1", "challenges": {"c1": {"status": "active"}}}
    save_state(path, payload)
    loaded = load_state(path)
    assert loaded["activeChallengeId"] == "c1"
    assert loaded["challenges"]["c1"]["status"] == "active"
    assert "updatedAt" in loaded


def test_read_slice_state_applies_defaults(tmp_path):
    issue = {"sliceIndex": 2, "title": "My Slice"}
    result = read_slice_state(tmp_path / "nonexistent.json", issue)
    assert result["sliceIndex"] == 2
    assert result["sliceTitle"] == "My Slice"
    assert result["postSuccessChallengeStatus"] == "active"


def test_read_slice_state_merges_stored(tmp_path):
    path = tmp_path / "slice.json"
    stored = {"postSuccessChallengeStatus": "complete", "extra": "data"}
    path.write_text(json.dumps(stored), encoding="utf-8")
    issue = {"sliceIndex": 3, "title": "Stored Slice"}
    result = read_slice_state(path, issue)
    assert result["postSuccessChallengeStatus"] == "complete"
    assert result["extra"] == "data"
    assert result["sliceIndex"] == 3


def test_append_history_creates_file(tmp_path):
    path = tmp_path / "subdir" / "history.jsonl"
    record = {"event": "test", "value": 42}
    append_history(path, record)
    assert path.exists()
    lines = path.read_text().splitlines()
    assert len(lines) == 1
    assert json.loads(lines[0]) == record


def test_append_history_appends(tmp_path):
    path = tmp_path / "history.jsonl"
    append_history(path, {"n": 1})
    append_history(path, {"n": 2})
    lines = path.read_text().splitlines()
    assert len(lines) == 2
    assert json.loads(lines[0]) == {"n": 1}
    assert json.loads(lines[1]) == {"n": 2}
