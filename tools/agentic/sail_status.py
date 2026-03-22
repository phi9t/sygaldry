#!/usr/bin/env python3
"""tools/agentic/sail_status.py — SAIL C&C terminal dashboard."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_RUNTIME_ROOT = Path(
    os.environ.get(
        "SAIL_RUNTIME_ROOT",
        "/mnt/data_infra/zephyr_container_infra/sygaldry/logs/sail",
    )
)
DEFAULT_SUPERVISOR_PORT = int(os.environ.get("SAIL_SUPERVISOR_PORT", "7890"))


def safe_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def age_str(ts: str | None) -> str:
    if not ts:
        return "unknown"
    try:
        then = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        delta = dt.datetime.now(dt.UTC) - then
        secs = int(delta.total_seconds())
        if secs < 0:
            return "in the future"
        if secs < 60:
            return f"{secs}s ago"
        if secs < 3600:
            return f"{secs // 60}m ago"
        if secs < 86400:
            return f"{secs // 3600}h ago"
        return f"{secs // 86400}d ago"
    except (ValueError, TypeError):
        return ts or "unknown"


def fmt_ts(ts: str | None) -> str:
    if not ts:
        return "—"
    try:
        then = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return then.strftime("%Y-%m-%d %H:%M UTC")
    except (ValueError, TypeError):
        return ts or "—"


def file_age_str(path: Path) -> str:
    try:
        secs = int(time.time() - path.stat().st_mtime)
        if secs < 60:
            return f"{secs}s ago"
        if secs < 3600:
            return f"{secs // 60}m ago"
        return f"{secs // 3600}h ago"
    except OSError:
        return "—"


def _delta_str(delta: dt.timedelta) -> str:
    secs = int(delta.total_seconds())
    if secs < 0:
        return "past"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h {(secs % 3600) // 60}m"
    return f"{secs // 86400}d"


def pid_alive(pid: int | None) -> bool:
    if pid is None:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except OSError:
        return False


def next_cron_utc() -> str | None:
    """Parse crontab -l, find a SAIL entry, return next-run string."""
    try:
        result = subprocess.run(
            ["crontab", "-l"], capture_output=True, text=True, check=False
        )
        for line in result.stdout.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "sail" not in line.lower():
                continue
            parts = line.split()
            if len(parts) < 5:
                continue
            minute_field, hour_field = parts[0], parts[1]
            now = dt.datetime.now(dt.UTC)
            if hour_field.startswith("*/"):
                interval = int(hour_field[2:])
                next_run = now.replace(second=0, microsecond=0)
                m = int(minute_field) if minute_field.isdigit() else 0
                next_run = next_run.replace(minute=m)
                next_h = now.hour - (now.hour % interval) + interval
                if next_h >= 24:
                    next_run = next_run.replace(hour=0) + dt.timedelta(days=1)
                else:
                    next_run = next_run.replace(hour=next_h % 24)
                if next_run <= now:
                    next_run += dt.timedelta(hours=interval)
                return (
                    next_run.strftime("%Y-%m-%d %H:%M UTC")
                    + f"  (in {_delta_str(next_run - now)})"
                )
            if minute_field.isdigit() and hour_field.isdigit():
                h, m = int(hour_field), int(minute_field)
                candidate = now.replace(hour=h, minute=m, second=0, microsecond=0)
                if candidate <= now:
                    candidate += dt.timedelta(days=1)
                return (
                    candidate.strftime("%Y-%m-%d %H:%M UTC")
                    + f"  (in {_delta_str(candidate - now)})"
                )
    except (OSError, ValueError):
        pass
    return None


def load_recent_attempts(runs_dir: Path, limit: int = 10) -> list[dict[str, Any]]:
    if not runs_dir.exists():
        return []
    run_dirs = sorted(
        (p for p in runs_dir.iterdir() if p.is_dir()),
        key=lambda p: p.name,
        reverse=True,
    )
    attempts: list[dict[str, Any]] = []
    for run_dir in run_dirs[:5]:
        for sub in ("primary", "selffix", "major"):
            jsonl = run_dir / sub / "issue_attempts.jsonl"
            if not jsonl.exists():
                continue
            for line in jsonl.read_text(
                encoding="utf-8", errors="replace"
            ).splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    attempts.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        if len(attempts) >= limit:
            break
    attempts.sort(key=lambda a: a.get("startedAt", ""), reverse=True)
    return attempts[:limit]


def try_http_status(port: int) -> dict[str, Any] | None:
    if port == 0:
        return None
    for path in ("/api/v1/status", "/status"):
        try:
            url = f"http://localhost:{port}{path}"
            with urllib.request.urlopen(url, timeout=1) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception:
            continue
    return None


def render_dashboard(
    runtime_root: Path,
    supervisor_port: int = DEFAULT_SUPERVISOR_PORT,
) -> dict[str, Any]:
    """Gather all data, return dict for --json or terminal rendering."""
    status_file = runtime_root / "supervisor_status.json"
    current_task_file = runtime_root / "current_task.json"
    last_discovered_file = runtime_root / "last_discovered.json"
    runs_dir = runtime_root / "runs"

    sup_status = try_http_status(supervisor_port) or safe_json(status_file, {})
    # currentTask and metrics are now embedded in the supervisor snapshot
    current_task = sup_status.get("currentTask") or safe_json(current_task_file)
    metrics = sup_status.get("metrics") or safe_json(runtime_root / "metrics.json")
    last_discovered = safe_json(last_discovered_file)
    recent_attempts = load_recent_attempts(runs_dir)
    next_cron = next_cron_utc()

    worker_pid = sup_status.get("workerPid")
    worker_log_age: str | None = None
    wlf = runtime_root / "infra" / "worker.log"
    if wlf.exists():
        worker_log_age = file_age_str(wlf)

    return {
        "state": sup_status.get("state", "unknown"),
        "observedAt": sup_status.get("observedAt"),
        "supervisorStatus": sup_status,
        "currentTask": current_task,
        "metrics": metrics,
        "lastDiscovered": last_discovered,
        "recentAttempts": recent_attempts,
        "nextCron": next_cron,
        "workerPid": worker_pid,
        "workerLogAge": worker_log_age,
        "lockHeld": sup_status.get("lockHeld", False),
        "lockHolders": sup_status.get("lockHolders", []),
        "temporalReachable": sup_status.get("temporalReachable"),
        "temporalAddress": sup_status.get("temporalAddress", "localhost:7233"),
        "lastCronStatus": sup_status.get("lastCronStatus", {}),
        "pauseFile": str(runtime_root / "cron.pause"),
    }


def _check(ok: bool | None) -> str:
    if ok is None:
        return "?"
    return "✓" if ok else "✗"


def _elapsed_str(started_ts: str | None) -> str:
    if not started_ts:
        return ""
    try:
        then = dt.datetime.fromisoformat(started_ts.replace("Z", "+00:00"))
        secs = int((dt.datetime.now(dt.UTC) - then).total_seconds())
        if secs < 0:
            secs = 0
        m, s = divmod(secs, 60)
        h, m = divmod(m, 60)
        if h:
            return f"{h}h {m}m {s}s"
        if m:
            return f"{m}m {s}s"
        return f"{s}s"
    except (ValueError, TypeError):
        return ""


def _bar(rate: float, width: int = 10) -> str:
    filled = round(rate * width)
    return "█" * filled + "░" * (width - filled)


def print_dashboard(data: dict[str, Any]) -> None:
    state = data["state"]
    pause_file = Path(data.get("pauseFile", ""))
    is_paused = pause_file.exists()
    display_state = "paused" if is_paused else state
    now_utc = dt.datetime.now(dt.UTC).strftime("%Y-%m-%d %H:%M UTC")

    print(f"\nSAIL  •  {display_state}  •  {now_utc}\n")

    # INFRASTRUCTURE
    temporal_ok = data.get("temporalReachable")
    temporal_addr = data.get("temporalAddress", "localhost:7233")
    worker_pid = data.get("workerPid")
    worker_alive = pid_alive(worker_pid)
    worker_log_age = data.get("workerLogAge") or "—"
    lock_held = data.get("lockHeld", False)

    lock_str = "—  not held"
    if lock_held:
        holders = data.get("lockHolders") or []
        if holders:
            lock_str = f"held  PIDs: {', '.join(str(p) for p in holders)}"
        else:
            lock_str = "held"

    worker_str = "—  not running"
    if worker_pid and worker_alive:
        worker_str = f"✓  PID {worker_pid}  (log age: {worker_log_age})"
    elif worker_pid:
        worker_str = f"✗  PID {worker_pid} dead"

    print("INFRASTRUCTURE")
    print(f"  Temporal   {_check(temporal_ok)}  {temporal_addr}")
    print(f"  Worker     {worker_str}")
    print(f"  Lock       {lock_str}")

    # LAST CYCLE
    last_cron = data.get("lastCronStatus") or {}
    last_run_id = last_cron.get("runId", "—")
    last_updated = last_cron.get("updatedAt") or last_cron.get("finishedAt")
    last_status_val = last_cron.get("status", "")
    empty_streak = last_cron.get("emptyDiscoveryStreak", 0)

    print(
        f"\nLAST CYCLE  {fmt_ts(last_updated)} ({age_str(last_updated)})  {last_status_val}"
    )
    streak_str = f"  •  streak: {empty_streak} empty" if empty_streak else ""
    print(f"  run: {last_run_id}{streak_str}")

    # ACTIVE AGENT
    current_task = data.get("currentTask")
    if current_task:
        issue_id = current_task.get("issueId", "?")
        issue_title = current_task.get("issueTitle", "")
        attempt = current_task.get("attempt", 1)
        max_attempts = current_task.get("maxAttempts", "?")
        run_id = current_task.get("runId", "")
        started = current_task.get("startedAt")
        elapsed = _elapsed_str(started)
        session = current_task.get("session") or {}

        print(f"\nACTIVE AGENT  •  {elapsed}")
        print(f"  {issue_id}: {issue_title}  (attempt {attempt}/{max_attempts})")
        if run_id:
            print(f"  Run: {run_id}")

        if session:
            sess_id = session.get("sessionId", "")
            model = session.get("model", "")
            in_tok = session.get("inputTokens", 0)
            out_tok = session.get("outputTokens", 0)
            cache_tok = session.get("cacheReadTokens", 0)
            cost = session.get("totalCostUsd", 0.0)
            turns = session.get("turnCount", 0)
            files = session.get("filesTouched") or []
            last_msg = session.get("lastMessage", "")
            status = session.get("status", "running")

            if sess_id or model:
                id_part = f"  {sess_id}" if sess_id else ""
                model_part = f"  •  {model}" if model else ""
                print(f"  Session:{id_part}{model_part}  [{status}]")
            tok_str = f"{in_tok:,} in / {out_tok:,} out"
            if cache_tok:
                tok_str += f" / {cache_tok:,} cached"
            tok_str += f"  •  ${cost:.4f}"
            print(f"  Tokens:  {tok_str}")
            files_str = ", ".join(files[:5]) if files else "—"
            print(f"  Turns:   {turns}  •  Files: {files_str}")
            if last_msg:
                snippet = last_msg[:120].replace("\n", " ")
                print(
                    f'  → "{snippet}..."' if len(last_msg) > 120 else f'  → "{snippet}"'
                )

    # METRICS
    metrics = data.get("metrics")
    if metrics and metrics.get("window"):
        win = metrics["window"]
        days = win.get("days", 30)
        runs = win.get("runsAnalyzed", 0)
        total_att = win.get("attemptsAnalyzed", 0)
        rate = metrics.get("successRate", 0.0)
        avg_dur = metrics.get("avgDurationSec", 0.0)
        tokens = metrics.get("tokens", {})
        total_cost = tokens.get("totalCostUsd", 0.0)
        avg_cost = total_cost / total_att if total_att > 0 else 0.0

        avg_m = int(avg_dur // 60)
        avg_s = int(avg_dur % 60)
        avg_dur_str = f"{avg_m}m {avg_s}s" if avg_m else f"{avg_s}s"

        print(f"\nMETRICS  ({days}d  •  {runs} runs  •  {total_att} attempts)")
        print(
            f"  Success rate:  {rate:.0%}  ({round(rate * total_att)}/{total_att})"
            f"    Avg duration:  {avg_dur_str}"
        )
        print(
            f"  Spend:  ${total_cost:.2f} total"
            f"            (${avg_cost:.3f}/attempt avg)"
        )
        by_type = metrics.get("byType") or {}
        if by_type:
            items = sorted(
                by_type.items(), key=lambda kv: kv[1].get("attempts", 0), reverse=True
            )
            for i in range(0, len(items), 2):
                parts = []
                for key, stats in items[i : i + 2]:
                    r = stats.get("successRate", 0.0)
                    bar = _bar(r)
                    parts.append(f"{key:<14} {r:.0%} {bar}")
                print("  " + "    ".join(parts))

    # NEXT CYCLE
    next_cron = data.get("nextCron")
    print(f"\nNEXT CYCLE  {next_cron or '(crontab not found)'}")

    # QUEUE
    last_disc = data.get("lastDiscovered")
    if last_disc:
        issues = last_disc.get("issues", [])
        disc_at = last_disc.get("discoveredAt")
        print(f"\nQUEUE  {len(issues)} issues  (discovered {fmt_ts(disc_at)})")
        priority_symbols = {3: "●", 2: "○", 1: "○"}
        priority_labels = {3: "high", 2: "med", 1: "low"}
        for issue in issues[:10]:
            pri = issue.get("priority", 2)
            sym = priority_symbols.get(pri, "○")
            label = priority_labels.get(pri, str(pri))
            title = issue.get("title", issue.get("id", "?"))
            print(f"  {sym} [{label}]  {title}")
    else:
        print("\nQUEUE  no queue data")

    # RECENT ATTEMPTS
    attempts = data.get("recentAttempts", [])
    if attempts:
        print(f"\nRECENT ATTEMPTS  (last {len(attempts)})")
        for a in attempts:
            status = a.get("status", "?")
            icon = "✓" if status in ("success", "pr_created", "landed") else "✗"
            run_kind = a.get("runKind", "?")
            issue_id = a.get("issueId", "?")
            issue_title = a.get("issueTitle", "")
            started = a.get("startedAt", "")
            date_str = started[:10] if started else "?"
            print(
                f"  {date_str}  {icon} {run_kind:<14}  {issue_id}  {issue_title[:50]}"
            )

    print()


def list_runs(runs_dir: Path) -> None:
    if not runs_dir.exists():
        print("No runs directory found.")
        return
    dirs = sorted(
        (p for p in runs_dir.iterdir() if p.is_dir()),
        key=lambda p: p.name,
        reverse=True,
    )
    if not dirs:
        print("No runs found.")
        return
    print(f"{'Run ID':<55}  {'Status':<10}  Processed")
    print("-" * 80)
    for d in dirs[:30]:
        run_data = safe_json(d / "primary" / "run.json", {})
        status = run_data.get("status", "?")
        counts = run_data.get("counts", {})
        processed = counts.get("processed", "?")
        print(f"{d.name:<55}  {status:<10}  {processed}")


def show_run(runs_dir: Path, run_id: str) -> None:
    run_dir = runs_dir / run_id
    if not run_dir.exists():
        print(f"Run not found: {run_id}")
        return
    for sub in ("primary", "selffix", "major"):
        sub_dir = run_dir / sub
        run_file = sub_dir / "run.json"
        if run_file.exists():
            data = safe_json(run_file, {})
            print(f"\n=== {sub}/run.json ===")
            print(json.dumps(data, indent=2))
        attempts_file = sub_dir / "issue_attempts.jsonl"
        if attempts_file.exists():
            print(f"\n=== {sub}/issue_attempts.jsonl ===")
            for line in attempts_file.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    print(line)


def main() -> int:
    parser = argparse.ArgumentParser(description="SAIL C&C terminal dashboard")
    parser.add_argument("--runtime-root", type=Path, default=DEFAULT_RUNTIME_ROOT)
    parser.add_argument(
        "--supervisor-port",
        type=int,
        default=DEFAULT_SUPERVISOR_PORT,
    )
    parser.add_argument("--watch", action="store_true", help="Refresh every 5s")
    parser.add_argument(
        "--json", dest="json_out", action="store_true", help="Machine-readable JSON"
    )
    parser.add_argument(
        "--runs",
        nargs="?",
        const="",
        default=None,
        metavar="RUN_ID",
        help="List all runs (no arg) or show detail for RUN_ID",
    )
    args = parser.parse_args()

    runs_dir = args.runtime_root / "runs"

    if args.runs is not None:
        if args.runs:
            show_run(runs_dir, args.runs)
        else:
            list_runs(runs_dir)
        return 0

    if args.watch:
        try:
            while True:
                print("\033[2J\033[H", end="")
                data = render_dashboard(args.runtime_root, args.supervisor_port)
                if args.json_out:
                    print(json.dumps(data, indent=2, default=str))
                else:
                    print_dashboard(data)
                time.sleep(5)
        except KeyboardInterrupt:
            return 0

    data = render_dashboard(args.runtime_root, args.supervisor_port)
    if args.json_out:
        print(json.dumps(data, indent=2, default=str))
    else:
        print_dashboard(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
