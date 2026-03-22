from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SUPERVISOR_PATH = REPO_ROOT / "tools" / "agentic" / "sail_supervisor.py"


def load_module():
    spec = importlib.util.spec_from_file_location("sail_supervisor", SUPERVISOR_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def make_config(module, runtime_root: Path, **overrides):
    return module.Config(
        runtime_root=runtime_root,
        poll_secs=overrides.get("poll_secs", 30),
        stall_secs=overrides.get("stall_secs", 1200),
        fix_cooldown_secs=overrides.get("fix_cooldown_secs", 300),
        fix_timeout_secs=overrides.get("fix_timeout_secs", 60),
        max_fix_tries=overrides.get("max_fix_tries", 5),
        temporal_address=overrides.get("temporal_address", "localhost:7233"),
        fix_engine=overrides.get("fix_engine", "claude"),
        fix_model=overrides.get("fix_model", ""),
        once=overrides.get("once", True),
        no_fix=overrides.get("no_fix", True),
        http_port=overrides.get("http_port", 0),
    )


def test_build_engine_command_matches_agent_task_shapes():
    module = load_module()

    claude_cmd, _ = module.build_engine_command("claude", "prompt", "", REPO_ROOT)
    assert claude_cmd[:5] == [
        "claude",
        "-p",
        "prompt",
        "--allowedTools",
        "Edit,Read,Write,Bash,Glob,Grep",
    ]
    assert claude_cmd[-2:] == ["--permission-mode", "acceptEdits"]

    codex_cmd, _ = module.build_engine_command("codex", "prompt", "gpt-5", REPO_ROOT)
    assert codex_cmd[:5] == ["codex", "exec", "--full-auto", "--json", "-s"]
    assert "-C" in codex_cmd
    assert str(REPO_ROOT) in codex_cmd
    assert codex_cmd[-1] == "prompt"


def test_classify_state_uses_startup_grace_and_stall_threshold(tmp_path):
    module = load_module()
    config = make_config(module, tmp_path, stall_secs=120)

    running_state, running_issues = module.classify_state(
        config,
        {
            "heartbeatAgeSec": None,
            "lockAgeSec": 30,
            "lockHeld": True,
            "runTreeAgeSec": None,
            "temporalReachable": True,
            "workerAlive": True,
            "workerLogAgeSec": None,
        },
        temporal_failures=0,
    )
    assert running_state == "running"
    assert running_issues[0]["code"] == "heartbeat_missing_startup_grace"

    stalled_state, stalled_issues = module.classify_state(
        config,
        {
            "heartbeatAgeSec": 500,
            "lockAgeSec": 500,
            "lockHeld": True,
            "runTreeAgeSec": 500,
            "temporalReachable": True,
            "workerAlive": True,
            "workerLogAgeSec": 500,
        },
        temporal_failures=0,
    )
    assert stalled_state == "stalled"
    assert stalled_issues[0]["code"] == "stalled_progress"


def test_classify_state_prioritizes_temporal_and_worker_failures(tmp_path):
    module = load_module()
    config = make_config(module, tmp_path)

    temporal_state, _ = module.classify_state(
        config,
        {
            "heartbeatAgeSec": 0,
            "lockAgeSec": 0,
            "lockHeld": False,
            "runTreeAgeSec": 0,
            "temporalReachable": False,
            "workerAlive": True,
            "workerLogAgeSec": 0,
        },
        temporal_failures=3,
    )
    assert temporal_state == "temporal_dead"

    worker_state, _ = module.classify_state(
        config,
        {
            "heartbeatAgeSec": 0,
            "lockAgeSec": 0,
            "lockHeld": False,
            "runTreeAgeSec": 0,
            "temporalReachable": True,
            "workerAlive": False,
            "workerLogAgeSec": 0,
        },
        temporal_failures=0,
    )
    assert worker_state == "worker_dead"


def test_run_fix_cycle_prefers_ensure_infra_for_worker_failures(tmp_path, monkeypatch):
    module = load_module()
    config = make_config(module, tmp_path, no_fix=False)
    snapshot = {
        "currentRunDir": "",
        "issues": [],
        "lastCronStatus": {},
        "lockHeld": False,
        "state": "worker_dead",
        "temporalReachable": True,
        "workerAlive": False,
    }

    ensure_calls: list[str] = []
    llm_calls: list[str] = []

    monkeypatch.setattr(
        module,
        "run_ensure_infra",
        lambda cfg: ensure_calls.append(str(cfg.runtime_root))
        or subprocess.CompletedProcess(["ensure"], 0, "", ""),
    )
    monkeypatch.setattr(
        module,
        "run_fix_engine",
        lambda cfg, snap, preface="": llm_calls.append(preface)
        or subprocess.CompletedProcess(["llm"], 0, "", ""),
    )

    result = module.run_fix_cycle(
        config,
        snapshot,
        problem_key="worker_dead:-",
        attempt_number=1,
    )

    assert ensure_calls == [str(tmp_path)]
    assert llm_calls == []
    assert result["ensureInfraExitCode"] == 0


def test_collect_health_reports_idle_with_alive_worker(tmp_path, monkeypatch):
    module = load_module()
    config = make_config(module, tmp_path)
    (tmp_path / "infra").mkdir()
    config.worker_pid_file.write_text(str(os.getpid()), encoding="utf-8")
    config.last_status_file.write_text('{"status":"success"}\n', encoding="utf-8")

    monkeypatch.setattr(module, "temporal_reachable", lambda address: True)
    snapshot, failures = module.collect_health(config, temporal_failures=0)

    assert failures == 0
    assert snapshot["state"] == "idle"
    assert snapshot["workerAlive"] is True
    assert snapshot["lastCronStatus"]["status"] == "success"


def test_main_once_no_fix_writes_status_and_events(tmp_path, monkeypatch):
    module = load_module()

    monkeypatch.setattr(
        module,
        "collect_health",
        lambda config, temporal_failures: (
            {
                "currentRunDir": "",
                "heartbeatAgeSec": None,
                "issues": [],
                "lastCronStatus": {},
                "lockHeld": False,
                "observedAt": "2026-03-08T00:00:00Z",
                "runTreeAgeSec": None,
                "state": "idle",
                "temporalReachable": True,
                "workerAlive": True,
                "workerLogAgeSec": None,
            },
            0,
        ),
    )
    monkeypatch.setattr(module, "install_signal_handlers", lambda: {"stop": False})
    monkeypatch.setattr(module, "parse_args", lambda: make_config(module, tmp_path))

    assert module.main() == 0

    status_payload = json.loads((tmp_path / "supervisor_status.json").read_text())
    events = [
        json.loads(line)
        for line in (tmp_path / "supervisor_events.jsonl")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip()
    ]
    assert status_payload["state"] == "idle"
    assert {event["event"] for event in events} == {"poll", "state_change"}
