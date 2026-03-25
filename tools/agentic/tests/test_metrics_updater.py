from __future__ import annotations

import datetime as dt
import json
from pathlib import Path

from tools.agentic.metrics_updater import compute_metrics, count_runs, load_attempts

_UTC = dt.UTC


def _ts(offset_hours: float = 0.0) -> str:
    ts = dt.datetime.now(_UTC) - dt.timedelta(hours=offset_hours)
    return ts.isoformat().replace("+00:00", "Z")


def test_load_attempts_filters_by_cutoff(tmp_path: Path) -> None:
    run_dir = tmp_path / "run-001"
    sub = run_dir / "primary"
    sub.mkdir(parents=True)
    records = [
        {"startedAt": _ts(1), "status": "success"},  # inside window
        {"startedAt": _ts(48), "status": "failed"},  # outside window (2 days ago)
    ]
    jsonl = sub / "issue_attempts.jsonl"
    jsonl.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")

    cutoff = dt.datetime.now(_UTC) - dt.timedelta(hours=24)
    results = load_attempts(tmp_path, cutoff)
    assert len(results) == 1
    assert results[0]["status"] == "success"


def test_load_attempts_handles_missing_dir(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist"
    cutoff = dt.datetime.now(_UTC) - dt.timedelta(days=30)
    assert load_attempts(missing, cutoff) == []


def test_compute_metrics_success_rate() -> None:
    attempts = [
        {"startedAt": _ts(1), "status": "success"},
        {"startedAt": _ts(2), "status": "failed"},
        {"startedAt": _ts(3), "status": "pr_created"},
        {"startedAt": _ts(4), "status": "error"},
    ]
    metrics = compute_metrics(attempts, runs_analyzed=1, days=7)
    # 2 successes out of 4 → 0.5
    assert metrics["successRate"] == 0.5


def test_compute_metrics_duration_aggregation() -> None:
    now = dt.datetime.now(_UTC)
    started = now - dt.timedelta(seconds=120)
    finished = now - dt.timedelta(seconds=60)

    def _fmt(d: dt.datetime) -> str:
        return d.isoformat().replace("+00:00", "Z")

    attempts = [
        {
            "startedAt": _fmt(started),
            "finishedAt": _fmt(finished),
            "status": "success",
        }
    ]
    metrics = compute_metrics(attempts, runs_analyzed=1, days=7)
    assert metrics["avgDurationSec"] == 60.0


def test_count_runs_counts_matching_dirs(tmp_path: Path) -> None:
    recent = tmp_path / "run-recent"
    recent.mkdir()
    old = tmp_path / "run-old"
    old.mkdir()

    # Make old dir appear old by setting mtime far in the past
    past = dt.datetime(2020, 1, 1, tzinfo=_UTC).timestamp()
    import os

    os.utime(old, (past, past))

    cutoff = dt.datetime.now(_UTC) - dt.timedelta(days=1)
    assert count_runs(tmp_path, cutoff) == 1


def test_count_runs_returns_zero_for_missing_dir(tmp_path: Path) -> None:
    missing = tmp_path / "no-such-dir"
    cutoff = dt.datetime.now(_UTC) - dt.timedelta(days=7)
    assert count_runs(missing, cutoff) == 0
