from __future__ import annotations

import json
import time
from pathlib import Path

from tools.agentic.parse_session_events import (
    SessionSummary,
    find_latest_events_file,
    parse_events,
    update_current_task,
)


def _make_structured_line(
    ev: dict, stream: str = "stdout", partial: bool = False
) -> str:
    return json.dumps(
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "workflowId": "wf-001",
            "stream": stream,
            "message": json.dumps(ev),
            "partial": partial,
        }
    )


def test_parse_events_extracts_token_counts(tmp_path: Path) -> None:
    events_file = tmp_path / "run_structured.jsonl"
    assistant_ev = {
        "type": "assistant",
        "message": {
            "usage": {
                "input_tokens": 100,
                "output_tokens": 50,
                "cache_read_input_tokens": 10,
                "cache_creation_input_tokens": 5,
            },
            "content": [],
        },
    }
    events_file.write_text(_make_structured_line(assistant_ev) + "\n", encoding="utf-8")

    session = parse_events(events_file)
    assert session.input_tokens == 100
    assert session.output_tokens == 50
    assert session.cache_read_tokens == 10
    assert session.cache_creation_tokens == 5


def test_parse_events_empty_file(tmp_path: Path) -> None:
    events_file = tmp_path / "empty_structured.jsonl"
    events_file.write_text("", encoding="utf-8")

    session = parse_events(events_file)
    assert session.input_tokens == 0
    assert session.output_tokens == 0
    assert session.tool_calls == []


def test_parse_events_result_event_overrides_totals(tmp_path: Path) -> None:
    events_file = tmp_path / "run_structured.jsonl"
    assistant_ev = {
        "type": "assistant",
        "message": {
            "usage": {"input_tokens": 10, "output_tokens": 5},
            "content": [],
        },
    }
    result_ev = {
        "type": "result",
        "total_cost_usd": 0.001234,
        "usage": {"input_tokens": 200, "output_tokens": 80},
    }
    lines = "\n".join(
        [_make_structured_line(assistant_ev), _make_structured_line(result_ev)]
    )
    events_file.write_text(lines + "\n", encoding="utf-8")

    session = parse_events(events_file)
    assert session.input_tokens == 200
    assert session.output_tokens == 80
    assert session.status == "completed"
    assert abs(session.total_cost_usd - 0.001234) < 1e-9


def test_find_latest_events_file_returns_newest(tmp_path: Path) -> None:
    older = tmp_path / "older_structured.jsonl"
    newer = tmp_path / "newer_structured.jsonl"
    older.write_text("{}\n", encoding="utf-8")
    time.sleep(0.01)
    newer.write_text("{}\n", encoding="utf-8")

    result = find_latest_events_file(tmp_path)
    assert result == newer


def test_find_latest_events_file_missing_dir(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist"
    assert find_latest_events_file(missing) is None


def test_update_current_task_merges_token_counts(tmp_path: Path) -> None:
    task_file = tmp_path / "current_task.json"
    task_file.write_text(json.dumps({"issueId": "rfc-001"}), encoding="utf-8")

    session = SessionSummary(input_tokens=42, output_tokens=7, status="completed")
    update_current_task(task_file, session)

    payload = json.loads(task_file.read_text(encoding="utf-8"))
    assert payload["session"]["inputTokens"] == 42
    assert payload["session"]["outputTokens"] == 7
    assert payload["session"]["status"] == "completed"
    assert "sessionUpdatedAt" in payload
    assert payload["issueId"] == "rfc-001"
