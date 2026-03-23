from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DISCOVER_PATH = REPO_ROOT / "tools" / "agentic" / "discover_issues.py"


def load_module():
    spec = importlib.util.spec_from_file_location("discover_issues", DISCOVER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def issue(issue_id: str, priority: int, issue_type: str) -> dict[str, object]:
    return {
        "id": issue_id,
        "priority": priority,
        "type": issue_type,
        "title": f"{issue_type} title",
        "description": f"{issue_type} description",
        "files": [f"{issue_type}.txt"],
        "context": issue_type,
    }


def test_stats_file_is_written(monkeypatch, tmp_path, capsys):
    module = load_module()
    stats_path = tmp_path / "stats.json"

    monkeypatch.setattr(
        module,
        "discover_go_tests_and_coverage",
        lambda repo_dir, max_per_type: [issue("go-test", 1, "go_test")],
    )
    monkeypatch.setattr(module, "discover_go_vet", lambda repo_dir, max_per_type: [])
    monkeypatch.setattr(
        module,
        "discover_shellcheck",
        lambda repo_dir, max_per_type: [issue("shellcheck", 3, "shellcheck")],
    )
    monkeypatch.setattr(
        module,
        "discover_todos",
        lambda repo_dir, max_per_type: [issue("todo", 2, "todo")],
    )
    monkeypatch.setattr(module, "discover_ruff", lambda repo_dir, max_per_type: [])
    monkeypatch.setattr(
        module, "discover_foundation_drift", lambda repo_dir, max_per_type: []
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            str(DISCOVER_PATH),
            "--repo-dir",
            str(tmp_path),
            "--min-priority",
            "2",
            "--stats-file",
            str(stats_path),
        ],
    )

    module.main()

    emitted = json.loads(capsys.readouterr().out)
    assert [entry["id"] for entry in emitted] == ["go-test", "todo"]

    stats = json.loads(stats_path.read_text(encoding="utf-8"))
    assert stats["repoDir"] == str(tmp_path.resolve())
    assert stats["selectedCount"] == 2
    assert stats["discoveredCount"] == 3
    assert {source["name"] for source in stats["sources"]} == {
        "go_tests_and_coverage",
        "go_vet",
        "shellcheck",
        "todo",
        "ruff",
        "foundation_drift",
        "rust_coverage",
        "open_rfcs",
    }
