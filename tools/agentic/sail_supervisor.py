#!/usr/bin/env python3
"""
tools/agentic/sail_supervisor.py — Monitor and heal unattended SAIL runs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

_AGENTIC_DIR = str(Path(__file__).resolve().parent)
if _AGENTIC_DIR not in sys.path:
    sys.path.insert(0, _AGENTIC_DIR)

import sail_http_server as _sail_http_server  # noqa: E402
from sail_http_server import (  # noqa: E402
    HttpServer,
    _http_lock,
    safe_json_load,
)
from worker_manager import WorkerManager  # noqa: E402
from temporal_probe import TemporalProbe  # noqa: E402

__all__ = [
    "HttpServer",
    "WorkerManager",
    "TemporalProbe",
]

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RUNTIME_ROOT = Path(
    os.environ.get(
        "SAIL_RUNTIME_ROOT",
        "/mnt/data_infra/zephyr_container_infra/sygaldry/logs/sail",
    )
)
FIXABLE_STATES = {"stalled", "worker_dead", "temporal_dead"}
HEALTHY_STATES = {"idle", "running"}
PAUSED_STATES = {"paused"}
_MAX_EVENTS_BYTES = int(
    os.environ.get("SAIL_SUPERVISOR_MAX_EVENTS_BYTES", str(10 * 1024 * 1024))
)
_DEFAULT_HTTP_PORT = int(os.environ.get("SAIL_SUPERVISOR_PORT", "7890"))


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


def iso_now() -> str:
    return utc_now().isoformat().replace("+00:00", "Z")


def log(message: str) -> None:
    print(
        f"[{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [sail-supervisor] {message}",
        file=sys.stderr,
        flush=True,
    )


@dataclass
class Config:
    runtime_root: Path
    poll_secs: int
    stall_secs: int
    fix_cooldown_secs: int
    fix_timeout_secs: int
    max_fix_tries: int
    temporal_address: str
    fix_engine: str
    fix_model: str
    once: bool
    no_fix: bool
    http_port: int
    webhook_url: str = ""

    @property
    def heartbeat_file(self) -> Path:
        return self.runtime_root / "heartbeat"

    @property
    def lock_file(self) -> Path:
        return self.runtime_root / "cron.lock"

    @property
    def last_status_file(self) -> Path:
        return self.runtime_root / "last_status.json"

    @property
    def status_file(self) -> Path:
        return self.runtime_root / "supervisor_status.json"

    @property
    def events_file(self) -> Path:
        return self.runtime_root / "supervisor_events.jsonl"

    @property
    def worker_pid_file(self) -> Path:
        return self.runtime_root / "infra" / "worker.pid"

    @property
    def worker_log_file(self) -> Path:
        return self.runtime_root / "infra" / "worker.log"

    @property
    def runs_dir(self) -> Path:
        return self.runtime_root / "runs"


def parse_args() -> Config:
    parser = argparse.ArgumentParser(description="Monitor and heal unattended SAIL")
    parser.add_argument("--once", action="store_true", help="Poll once and exit")
    parser.add_argument("--no-fix", action="store_true", help="Disable remediation")
    parser.add_argument("--runtime-root", type=Path, default=DEFAULT_RUNTIME_ROOT)
    parser.add_argument(
        "--poll-secs",
        type=int,
        default=int(os.environ.get("SAIL_SUPERVISOR_POLL_SECS", "30")),
    )
    parser.add_argument(
        "--stall-secs",
        type=int,
        default=int(os.environ.get("SAIL_SUPERVISOR_STALL_SECS", "1200")),
    )
    args = parser.parse_args()
    return Config(
        runtime_root=args.runtime_root,
        poll_secs=max(args.poll_secs, 1),
        stall_secs=max(args.stall_secs, 1),
        fix_cooldown_secs=max(
            int(os.environ.get("SAIL_SUPERVISOR_FIX_COOLDOWN_SECS", "300")), 0
        ),
        fix_timeout_secs=max(
            int(os.environ.get("SAIL_SUPERVISOR_FIX_TIMEOUT_SECS", "600")), 1
        ),
        max_fix_tries=max(int(os.environ.get("SAIL_SUPERVISOR_MAX_FIX_TRIES", "5")), 1),
        temporal_address=os.environ.get("TEMPORAL_ADDRESS", "localhost:7233"),
        fix_engine=os.environ.get("SAIL_SUPERVISOR_FIX_ENGINE", "claude").strip()
        or "claude",
        fix_model=os.environ.get("SAIL_SUPERVISOR_FIX_MODEL", "").strip(),
        once=args.once,
        no_fix=args.no_fix,
        http_port=_DEFAULT_HTTP_PORT,
        webhook_url=os.environ.get("SAIL_WEBHOOK_URL", "").strip(),
    )


def send_webhook(config: Config, event: str, **details: Any) -> None:
    """POST a JSON event to the configured webhook URL (fire-and-forget, silent on failure)."""
    if not config.webhook_url:
        return
    payload = {"event": event, "timestamp": iso_now(), **details}
    data = json.dumps(payload).encode("utf-8")
    try:
        req = urllib.request.Request(
            config.webhook_url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5):
            pass
    except Exception:
        pass


def ensure_runtime_root(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def tail_text(path: Path, max_lines: int = 50) -> str:
    if not path.exists():
        return ""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(lines[-max_lines:])


def age_seconds(path: Path) -> float | None:
    try:
        return max(time.time() - path.stat().st_mtime, 0.0)
    except OSError:
        return None


def newest_run_dir(runs_dir: Path) -> Path | None:
    if not runs_dir.exists():
        return None
    dirs = sorted(
        (path for path in runs_dir.iterdir() if path.is_dir()), key=lambda p: p.name
    )
    return dirs[-1] if dirs else None


def newest_tree_mtime(path: Path) -> float | None:
    if not path.exists():
        return None
    latest: float | None = None
    try:
        for candidate in path.rglob("*"):
            try:
                stat_result = candidate.stat()
            except OSError:
                continue
            if latest is None or stat_result.st_mtime > latest:
                latest = stat_result.st_mtime
    except OSError:
        return None
    return latest


def latest_tree_age(path: Path) -> float | None:
    latest = newest_tree_mtime(path)
    if latest is None:
        return None
    return max(time.time() - latest, 0.0)


def lock_held(path: Path) -> bool:
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
        except BlockingIOError:
            return True
    finally:
        os.close(fd)


def lock_holders(path: Path) -> list[int]:
    if not path.exists():
        return []
    try:
        result = subprocess.run(
            ["lsof", "-t", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return []
    holders: list[int] = []
    for raw in result.stdout.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            holders.append(int(raw))
        except ValueError:
            continue
    return holders


def temporal_reachable(address: str) -> bool:
    host, sep, port_text = address.partition(":")
    if not sep:
        host = address
        port_text = "7233"
    try:
        port = int(port_text)
    except ValueError:
        return False
    try:
        with socket.create_connection((host, port), timeout=3):
            return True
    except OSError:
        return False


def worker_info(pid_file: Path) -> tuple[int | None, bool]:
    if not pid_file.exists():
        return None, False
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None, False
    try:
        os.kill(pid, 0)
    except OSError:
        return pid, False
    return pid, True


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", delete=False, dir=path.parent
    ) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        tmp_path = Path(handle.name)
    tmp_path.replace(path)


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def short_health_details(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        "heartbeatAgeSec": snapshot.get("heartbeatAgeSec"),
        "lockHeld": snapshot.get("lockHeld"),
        "runTreeAgeSec": snapshot.get("runTreeAgeSec"),
        "state": snapshot.get("state"),
        "temporalReachable": snapshot.get("temporalReachable"),
        "workerAlive": snapshot.get("workerAlive"),
    }


def classify_state(
    config: Config, raw: dict[str, Any], temporal_failures: int
) -> tuple[str, list[dict[str, str]]]:
    issues: list[dict[str, str]] = []
    if (config.runtime_root / "cron.pause").exists():
        return "paused", []
    if temporal_failures >= 3:
        issues.append(
            {
                "code": "temporal_unreachable",
                "message": f"Temporal unreachable at {config.temporal_address} for 3 consecutive polls",
            }
        )
        return "temporal_dead", issues

    if not raw["workerAlive"]:
        issues.append(
            {
                "code": "worker_not_running",
                "message": "managed worker pid file missing or process not alive",
            }
        )
        return "worker_dead", issues

    if raw["lockHeld"]:
        fresh_progress = False
        if (
            raw["heartbeatAgeSec"] is not None
            and raw["heartbeatAgeSec"] <= config.stall_secs
        ):
            fresh_progress = True
        elif (
            raw["heartbeatAgeSec"] is None
            and raw["lockAgeSec"] is not None
            and raw["lockAgeSec"] <= config.stall_secs
        ):
            fresh_progress = True
        elif (
            raw["runTreeAgeSec"] is not None
            and raw["runTreeAgeSec"] <= config.stall_secs
        ):
            fresh_progress = True
        elif (
            raw["workerLogAgeSec"] is not None
            and raw["workerLogAgeSec"] <= config.stall_secs
        ):
            fresh_progress = True

        if fresh_progress:
            if raw["heartbeatAgeSec"] is None:
                issues.append(
                    {
                        "code": "heartbeat_missing_startup_grace",
                        "message": "cron lock held with no heartbeat yet; using startup grace window",
                    }
                )
            return "running", issues

        issues.append(
            {
                "code": "stalled_progress",
                "message": "cron lock held but heartbeat and run progress are stale",
            }
        )
        return "stalled", issues

    return "idle", issues


def collect_health(
    config: Config, temporal_failures: int
) -> tuple[dict[str, Any], int]:
    lock_is_held = lock_held(config.lock_file)
    temporal_ok = temporal_reachable(config.temporal_address)
    temporal_failures = 0 if temporal_ok else temporal_failures + 1
    worker_pid, worker_alive = worker_info(config.worker_pid_file)
    latest_run = newest_run_dir(config.runs_dir)
    last_status = safe_json_load(config.last_status_file, {})
    raw = {
        "observedAt": iso_now(),
        "runtimeRoot": str(config.runtime_root),
        "lockFile": str(config.lock_file),
        "lockHeld": lock_is_held,
        "lockAgeSec": age_seconds(config.lock_file),
        "lockHolders": lock_holders(config.lock_file) if lock_is_held else [],
        "temporalReachable": temporal_ok,
        "temporalFailureCount": temporal_failures,
        "temporalAddress": config.temporal_address,
        "workerAlive": worker_alive,
        "workerPid": worker_pid,
        "workerPidFile": str(config.worker_pid_file),
        "workerLogFile": str(config.worker_log_file),
        "workerLogAgeSec": age_seconds(config.worker_log_file),
        "heartbeatFile": str(config.heartbeat_file),
        "heartbeatAgeSec": age_seconds(config.heartbeat_file),
        "currentRunDir": str(latest_run) if latest_run else "",
        "runTreeAgeSec": latest_tree_age(latest_run) if latest_run else None,
        "lastCronStatus": last_status,
        "currentTask": safe_json_load(config.runtime_root / "current_task.json", {}),
        "metrics": safe_json_load(config.runtime_root / "metrics.json", {}),
        "issues": [],
        "lastFix": {},
    }
    state, issues = classify_state(config, raw, temporal_failures)
    raw["state"] = state
    raw["issues"] = issues
    return raw, temporal_failures


def health_problem_key(snapshot: dict[str, Any]) -> str:
    run_key = (
        Path(snapshot["currentRunDir"]).name if snapshot.get("currentRunDir") else "-"
    )
    return f"{snapshot['state']}:{run_key}"


def snapshot_for_status(
    snapshot: dict[str, Any], last_fix: dict[str, Any]
) -> dict[str, Any]:
    payload = dict(snapshot)
    payload["lastFix"] = last_fix
    return payload


def build_engine_command(
    engine: str, prompt: str, model: str, working_dir: Path
) -> tuple[list[str], dict[str, str]]:
    env = dict(os.environ)
    if engine == "claude":
        command = [
            "claude",
            "-p",
            prompt,
            "--allowedTools",
            "Edit,Read,Write,Bash,Glob,Grep",
            "--permission-mode",
            "acceptEdits",
        ]
        if model:
            command.extend(["--model", model])
        return command, env
    if engine == "codex":
        command = ["codex", "exec", "--full-auto", "--json", "-s", "workspace-write"]
        if model:
            command.extend(["-m", model])
        command.extend(["-C", str(working_dir), prompt])
        return command, env
    if engine == "cursor":
        command = ["cursor", "--exec"]
        if model:
            command.extend(["--model", model])
        command.append(prompt)
        return command, env
    if engine == "echo":
        return ["echo", prompt], env
    raise ValueError(f"unsupported supervisor fix engine: {engine}")


def load_prompt_template() -> str:
    prompt_path = REPO_ROOT / "tools" / "agentic" / "prompts" / "supervisor_fix.md"
    return prompt_path.read_text(encoding="utf-8")


def render_fix_prompt(
    config: Config, snapshot: dict[str, Any], preface: str = ""
) -> str:
    latest_run_dir = (
        Path(snapshot["currentRunDir"]) if snapshot.get("currentRunDir") else None
    )
    run_json = (
        safe_json_load(latest_run_dir / "primary" / "run.json", {})
        if latest_run_dir
        else {}
    )
    issue_attempts_excerpt = (
        tail_text(latest_run_dir / "primary" / "issue_attempts.jsonl", max_lines=50)
        if latest_run_dir
        else ""
    )
    template = load_prompt_template()
    return (
        template.replace("{{preface}}", preface.strip() or "None")
        .replace("{{repo_root}}", str(REPO_ROOT))
        .replace("{{runtime_root}}", str(config.runtime_root))
        .replace("{{health_json}}", json.dumps(snapshot, indent=2, sort_keys=True))
        .replace(
            "{{last_status_json}}",
            json.dumps(snapshot.get("lastCronStatus", {}), indent=2, sort_keys=True),
        )
        .replace("{{run_json}}", json.dumps(run_json, indent=2, sort_keys=True))
        .replace(
            "{{worker_log_excerpt}}",
            tail_text(config.worker_log_file, max_lines=80) or "unavailable",
        )
        .replace("{{issue_attempts_excerpt}}", issue_attempts_excerpt or "unavailable")
    )


def run_subprocess(
    command: list[str],
    *,
    cwd: Path,
    timeout: int,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def summarize_process(result: subprocess.CompletedProcess[str] | None) -> str:
    if result is None:
        return ""
    stderr_tail = "\n".join(result.stderr.splitlines()[-20:]).strip()
    stdout_tail = "\n".join(result.stdout.splitlines()[-20:]).strip()
    summary = f"exit={result.returncode}"
    if stderr_tail:
        summary += f" stderr_tail={stderr_tail!r}"
    elif stdout_tail:
        summary += f" stdout_tail={stdout_tail!r}"
    return summary


def run_ensure_infra(config: Config) -> subprocess.CompletedProcess[str]:
    command = [str(REPO_ROOT / "bin" / "sygaldry"), "sail", "ensure-infra"]
    return run_subprocess(command, cwd=REPO_ROOT, timeout=config.fix_timeout_secs)


def run_fix_engine(
    config: Config,
    snapshot: dict[str, Any],
    *,
    preface: str = "",
) -> subprocess.CompletedProcess[str]:
    prompt = render_fix_prompt(config, snapshot, preface=preface)
    command, env = build_engine_command(
        config.fix_engine, prompt, config.fix_model, REPO_ROOT
    )
    env["SAIL_RUNTIME_ROOT"] = str(config.runtime_root)
    env["SAIL_SUPERVISOR_RUNTIME_ROOT"] = str(config.runtime_root)
    return run_subprocess(
        command, cwd=REPO_ROOT, timeout=config.fix_timeout_secs, env=env
    )


class StopSignal(Exception):
    pass


def install_signal_handlers() -> dict[str, bool]:
    state = {"stop": False}

    def _handler(_signum: int, _frame: Any) -> None:
        state["stop"] = True

    signal.signal(signal.SIGINT, _handler)
    signal.signal(signal.SIGTERM, _handler)
    return state


def sleep_or_stop(
    seconds: int,
    stop_state: dict[str, bool],
    refresh_event: threading.Event | None = None,
) -> None:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if stop_state["stop"]:
            raise StopSignal
        if refresh_event is not None and refresh_event.is_set():
            refresh_event.clear()
            return
        time.sleep(min(0.5, max(deadline - time.time(), 0.0)))


def append_event(
    config: Config, event: str, snapshot: dict[str, Any], **details: Any
) -> None:
    payload = {
        "timestamp": iso_now(),
        "event": event,
        "state": snapshot.get("state", ""),
        "problemKey": (
            health_problem_key(snapshot)
            if snapshot.get("state") in FIXABLE_STATES
            else ""
        ),
        "details": details or short_health_details(snapshot),
    }
    events_file = config.events_file
    try:
        if events_file.exists() and events_file.stat().st_size > _MAX_EVENTS_BYTES:
            events_file.rename(events_file.parent / "supervisor_events.jsonl.1")
    except OSError:
        pass
    append_jsonl(events_file, payload)


def run_fix_cycle(
    config: Config,
    snapshot: dict[str, Any],
    *,
    problem_key: str,
    attempt_number: int,
) -> dict[str, Any]:
    started_at = iso_now()
    fixing_snapshot = dict(snapshot)
    fixing_snapshot["state"] = "fixing"
    append_event(
        config,
        "fix_started",
        fixing_snapshot,
        attempt=attempt_number,
        engine=config.fix_engine,
        originalState=snapshot["state"],
    )
    atomic_write_json(
        config.status_file,
        snapshot_for_status(
            fixing_snapshot,
            {
                "attempts": attempt_number,
                "engine": config.fix_engine,
                "problemKey": problem_key,
                "startedAt": started_at,
                "strategy": (
                    "infra_then_llm"
                    if snapshot["state"] in {"worker_dead", "temporal_dead"}
                    else "llm"
                ),
                "status": "running",
            },
        ),
    )

    ensure_result: subprocess.CompletedProcess[str] | None = None
    llm_result: subprocess.CompletedProcess[str] | None = None
    summary_parts: list[str] = []

    if snapshot["state"] in {"worker_dead", "temporal_dead"}:
        ensure_result = run_ensure_infra(config)
        summary_parts.append(f"ensure_infra:{summarize_process(ensure_result)}")
        if ensure_result.returncode != 0:
            llm_result = run_fix_engine(
                config,
                snapshot,
                preface="The deterministic 'sygaldry sail ensure-infra' recovery failed first.",
            )
            summary_parts.append(f"llm:{summarize_process(llm_result)}")
    else:
        llm_result = run_fix_engine(config, snapshot)
        summary_parts.append(f"llm:{summarize_process(llm_result)}")

    return {
        "attempts": attempt_number,
        "engine": config.fix_engine,
        "ensureInfraExitCode": ensure_result.returncode if ensure_result else None,
        "exitCode": llm_result.returncode if llm_result else None,
        "finishedAt": iso_now(),
        "problemKey": problem_key,
        "startedAt": started_at,
        "status": "finished",
        "strategy": (
            "infra_then_llm"
            if snapshot["state"] in {"worker_dead", "temporal_dead"}
            else "llm"
        ),
        "summary": " | ".join(part for part in summary_parts if part),
    }


def main() -> int:
    config = parse_args()
    ensure_runtime_root(config.runtime_root)
    stop_state = install_signal_handlers()

    refresh_event: threading.Event | None = None
    if config.http_port != 0 and not config.once:
        refresh_event = threading.Event()
        HttpServer(config).start(refresh_event)

    temporal_failures = 0
    previous_state = ""
    previous_problem_key = ""
    fix_problem_key = ""
    fix_failures = 0
    last_fix_finished_at = 0.0
    last_fix: dict[str, Any] = {}

    while True:
        if stop_state["stop"]:
            log("shutdown requested")
            return 0

        snapshot, temporal_failures = collect_health(config, temporal_failures)
        with _http_lock:
            _sail_http_server._current_snapshot = snapshot
        state = snapshot["state"]
        problem_key = health_problem_key(snapshot) if state in FIXABLE_STATES else ""

        if state in HEALTHY_STATES:
            fix_problem_key = ""
            fix_failures = 0
        elif state in FIXABLE_STATES:
            if problem_key != fix_problem_key:
                fix_problem_key = problem_key
                fix_failures = 0
                last_fix_finished_at = 0.0

        if state in FIXABLE_STATES and fix_failures >= config.max_fix_tries:
            snapshot["issues"] = list(snapshot["issues"]) + [
                {
                    "code": "fix_budget_exhausted",
                    "message": f"reached max fix attempts for {problem_key}",
                }
            ]
            snapshot["state"] = "error"
            state = "error"
            send_webhook(config, "infra_error", state=state, problemKey=problem_key)

        snapshot["lastFix"] = last_fix
        atomic_write_json(config.status_file, snapshot_for_status(snapshot, last_fix))
        append_event(config, "poll", snapshot)
        if state != previous_state or problem_key != previous_problem_key:
            append_event(
                config,
                "state_change",
                snapshot,
                previousProblemKey=previous_problem_key,
                previousState=previous_state,
            )
            previous_state = state
            previous_problem_key = problem_key

        can_fix = (
            not config.no_fix
            and state in FIXABLE_STATES
            and fix_failures < config.max_fix_tries
            and (
                last_fix_finished_at == 0.0
                or time.time() - last_fix_finished_at >= config.fix_cooldown_secs
            )
        )
        if can_fix:
            log(f"starting remediation for {state} ({problem_key})")
            try:
                last_fix = run_fix_cycle(
                    config,
                    snapshot,
                    problem_key=problem_key,
                    attempt_number=fix_failures + 1,
                )
            except (subprocess.TimeoutExpired, ValueError) as exc:
                last_fix = {
                    "attempts": fix_failures + 1,
                    "engine": config.fix_engine,
                    "finishedAt": iso_now(),
                    "problemKey": problem_key,
                    "startedAt": iso_now(),
                    "status": "failed",
                    "strategy": "llm",
                    "summary": str(exc),
                }
            last_fix_finished_at = time.time()

            snapshot, temporal_failures = collect_health(config, temporal_failures)
            with _http_lock:
                _sail_http_server._current_snapshot = snapshot
            if snapshot["state"] in HEALTHY_STATES:
                fix_failures = 0
                fix_problem_key = ""
                last_fix["status"] = "succeeded"
                append_event(config, "fix_finished", snapshot, result="healthy")
                send_webhook(config, "infra_recovered", problemKey=problem_key)
            else:
                fix_failures += 1
                last_fix["status"] = "failed"
                append_event(
                    config,
                    "fix_finished",
                    snapshot,
                    attempt=fix_failures,
                    result="still_unhealthy",
                )
            snapshot["lastFix"] = last_fix
            atomic_write_json(
                config.status_file, snapshot_for_status(snapshot, last_fix)
            )
            next_problem_key = (
                health_problem_key(snapshot)
                if snapshot["state"] in FIXABLE_STATES
                else ""
            )
            if (
                snapshot["state"] != previous_state
                or next_problem_key != previous_problem_key
            ):
                append_event(
                    config,
                    "state_change",
                    snapshot,
                    previousProblemKey=previous_problem_key,
                    previousState=previous_state,
                )
            previous_state = snapshot["state"]
            previous_problem_key = next_problem_key

        if config.once:
            return 0

        try:
            sleep_or_stop(config.poll_secs, stop_state, refresh_event)
        except StopSignal:
            log("shutdown requested")
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
