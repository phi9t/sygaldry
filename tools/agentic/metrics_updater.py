#!/usr/bin/env python3
"""tools/agentic/metrics_updater.py — Aggregate SAIL metrics across all runs → metrics.json.

Scans runs/*/primary/issue_attempts.jsonl (and selffix/major) for the last N days.
For each attempt record reads status, duration, and issue type.
For attempts with a logDir, also calls parse_session_events to accumulate token counts.

Usage:
  metrics_updater.py --runs-dir <path> --output <path> [--days 30]
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import sys
from pathlib import Path
from typing import Any

# Allow importing sibling modules
_AGENTIC_DIR = str(Path(__file__).resolve().parent)
if _AGENTIC_DIR not in sys.path:
    sys.path.insert(0, _AGENTIC_DIR)

from parse_session_events import find_latest_events_file, parse_events  # noqa: E402

SUCCESS_STATUSES = {"success", "pr_created", "landed"}


def _parse_ts(ts: str) -> dt.datetime | None:
    if not ts:
        return None
    try:
        return dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def _duration_sec(record: dict[str, Any]) -> float | None:
    started = _parse_ts(record.get("startedAt", ""))
    finished = _parse_ts(record.get("finishedAt", ""))
    if started and finished:
        delta = (finished - started).total_seconds()
        return max(delta, 0.0)
    return None


def load_attempts(runs_dir: Path, cutoff: dt.datetime) -> list[dict[str, Any]]:
    """Load all attempt records newer than cutoff from all run sub-dirs."""
    attempts: list[dict[str, Any]] = []
    if not runs_dir.exists():
        return attempts
    for run_dir in runs_dir.iterdir():
        if not run_dir.is_dir():
            continue
        for sub in ("primary", "selffix", "major"):
            jsonl = run_dir / sub / "issue_attempts.jsonl"
            if not jsonl.exists():
                continue
            try:
                for line in jsonl.read_text(
                    encoding="utf-8", errors="replace"
                ).splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    started = _parse_ts(record.get("startedAt", ""))
                    if started and started < cutoff:
                        continue
                    attempts.append(record)
            except OSError:
                continue
    return attempts


def compute_metrics(
    attempts: list[dict[str, Any]],
    runs_analyzed: int,
    days: int,
) -> dict[str, Any]:
    total = len(attempts)
    successes = sum(1 for a in attempts if a.get("status") in SUCCESS_STATUSES)
    success_rate = round(successes / total, 4) if total > 0 else 0.0

    durations = [d for a in attempts if (d := _duration_sec(a)) is not None]
    avg_duration = round(sum(durations) / len(durations), 1) if durations else 0.0

    # Per-type stats
    by_type: dict[str, dict[str, Any]] = collections.defaultdict(
        lambda: {"attempts": 0, "successes": 0}
    )
    for a in attempts:
        issue_type = a.get("issueType") or "unknown"
        by_type[issue_type]["attempts"] += 1
        if a.get("status") in SUCCESS_STATUSES:
            by_type[issue_type]["successes"] += 1
    for key, stats in by_type.items():
        n = stats["attempts"]
        stats["successRate"] = round(stats["successes"] / n, 4) if n > 0 else 0.0

    # Token accounting
    total_input_tokens = 0
    total_output_tokens = 0
    total_cache_read_tokens = 0
    total_cost_usd = 0.0
    token_attempts = 0
    for a in attempts:
        log_dir_str = a.get("logDir", "")
        if not log_dir_str:
            continue
        log_dir = Path(log_dir_str)
        events_file = find_latest_events_file(log_dir)
        if events_file is None:
            continue
        try:
            summary = parse_events(events_file)
        except Exception:
            continue
        if summary.input_tokens > 0 or summary.output_tokens > 0:
            total_input_tokens += summary.input_tokens
            total_output_tokens += summary.output_tokens
            total_cache_read_tokens += summary.cache_read_tokens
            total_cost_usd += summary.total_cost_usd
            token_attempts += 1

    avg_input = round(total_input_tokens / token_attempts) if token_attempts > 0 else 0

    # Recent trend (last 7 days, grouped by date)
    now = dt.datetime.now(dt.UTC)
    trend_days = min(days, 7)
    trend_buckets: dict[str, dict[str, int]] = {}
    for i in range(trend_days):
        day = (now - dt.timedelta(days=i)).strftime("%Y-%m-%d")
        trend_buckets[day] = {"attempts": 0, "successes": 0}
    for a in attempts:
        started = _parse_ts(a.get("startedAt", ""))
        if started is None:
            continue
        day = started.strftime("%Y-%m-%d")
        if day not in trend_buckets:
            continue
        trend_buckets[day]["attempts"] += 1
        if a.get("status") in SUCCESS_STATUSES:
            trend_buckets[day]["successes"] += 1
    recent_trend = [
        {"date": day, "attempts": v["attempts"], "successes": v["successes"]}
        for day, v in sorted(trend_buckets.items())
    ]

    # Top failures (issues with the most failed attempts)
    failure_counts: dict[str, int] = collections.Counter()
    for a in attempts:
        if a.get("status") not in SUCCESS_STATUSES and a.get("status") not in (
            "skipped_registry",
            "skipped_remote_branch",
            "dry_run",
        ):
            failure_counts[a.get("issueId", "unknown")] += 1
    top_failures = [
        {"issueId": issue_id, "attempts": count}
        for issue_id, count in failure_counts.most_common(5)
    ]

    return {
        "computedAt": now.isoformat().replace("+00:00", "Z"),
        "window": {
            "days": days,
            "runsAnalyzed": runs_analyzed,
            "attemptsAnalyzed": total,
        },
        "successRate": success_rate,
        "avgDurationSec": avg_duration,
        "byType": dict(by_type),
        "tokens": {
            "avgInputTokensPerAttempt": avg_input,
            "totalCacheReadTokens": total_cache_read_tokens,
            "totalCostUsd": round(total_cost_usd, 4),
            "totalInputTokens": total_input_tokens,
            "totalOutputTokens": total_output_tokens,
        },
        "recentTrend": recent_trend,
        "topFailures": top_failures,
    }


def count_runs(runs_dir: Path, cutoff: dt.datetime) -> int:
    if not runs_dir.exists():
        return 0
    count = 0
    for run_dir in runs_dir.iterdir():
        if not run_dir.is_dir():
            continue
        try:
            mtime = dt.datetime.fromtimestamp(run_dir.stat().st_mtime, tz=dt.UTC)
            if mtime >= cutoff:
                count += 1
        except OSError:
            continue
    return count


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate SAIL metrics from run attempts to metrics.json"
    )
    parser.add_argument("--runs-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--days", type=int, default=30)
    args = parser.parse_args()

    now = dt.datetime.now(dt.UTC)
    cutoff = now - dt.timedelta(days=args.days)

    attempts = load_attempts(args.runs_dir, cutoff)
    runs_analyzed = count_runs(args.runs_dir, cutoff)
    metrics = compute_metrics(attempts, runs_analyzed, args.days)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"metrics_updater: {runs_analyzed} runs, {len(attempts)} attempts, "
        f"success_rate={metrics['successRate']:.0%}, "
        f"cost=${metrics['tokens']['totalCostUsd']:.2f}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
