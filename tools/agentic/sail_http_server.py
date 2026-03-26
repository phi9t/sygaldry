"""
tools/agentic/sail_http_server.py — HTTP status/health API for sail_supervisor.
"""

from __future__ import annotations

import datetime as dt
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler
from http.server import HTTPServer as _HTTPServer
from pathlib import Path
from typing import TYPE_CHECKING, Any
from urllib.parse import parse_qs, urlparse

if TYPE_CHECKING:
    from sail_supervisor import Config


def _log(message: str) -> None:
    print(
        f"[{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [sail-supervisor] {message}",
        file=sys.stderr,
        flush=True,
    )


# Shared state for HTTP handler (read from any thread, written from poll thread)
_http_lock = threading.Lock()
_current_snapshot: dict[str, Any] = {}
_refresh_event: threading.Event | None = None


def safe_json_load(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


class HttpServer:
    """Minimal HTTP API for the supervisor. Runs as a daemon thread."""

    def __init__(self, config: "Config") -> None:
        self._config = config

    def start(self, refresh_event: threading.Event) -> None:
        global _refresh_event
        _refresh_event = refresh_event
        config = self._config

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
                pass  # suppress default HTTP logging

            def do_GET(self) -> None:  # noqa: N802
                parsed = urlparse(self.path)
                path = parsed.path.rstrip("/")
                qs = parse_qs(parsed.query)

                if path in ("/status", "/api/v1/status"):
                    with _http_lock:
                        body = json.dumps(
                            _current_snapshot, indent=2, sort_keys=True, default=str
                        )
                    self._send_json(body)
                elif path in ("/api/v1/task", "/task"):
                    task_file = config.runtime_root / "current_task.json"
                    if not task_file.exists():
                        self.send_response(404)
                        self.end_headers()
                        self.wfile.write(b'{"error": "no active task"}')
                    else:
                        self._handle_file_json(task_file)
                elif path == "/api/v1/metrics":
                    self._handle_file_json(config.runtime_root / "metrics.json")
                elif path in ("/api/v1/events", "/events"):
                    tail = int(qs.get("tail", ["100"])[0])
                    self._handle_events(tail, config)
                elif (
                    path in ("/api/v1/runs", "/runs")
                    or path.startswith("/api/v1/runs/")
                    or path.startswith("/runs/")
                ):
                    # strip /api/v1 prefix if present
                    bare = path.removeprefix("/api/v1")
                    parts = bare.split("/")
                    if len(parts) >= 3 and parts[2]:
                        self._handle_run_detail(parts[2], config)
                    else:
                        n = int(qs.get("n", ["20"])[0])
                        self._handle_runs_list(n, config)
                elif path == "/queue":
                    self._handle_file_json(config.runtime_root / "last_discovered.json")
                else:
                    self.send_response(404)
                    self.end_headers()

            def do_POST(self) -> None:  # noqa: N802
                if self.path == "/refresh":
                    if _refresh_event is not None:
                        _refresh_event.set()
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"status": "refresh triggered"}')
                else:
                    self.send_response(404)
                    self.end_headers()

            def _send_json(self, body: str) -> None:
                encoded = body.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def _handle_file_json(self, path: Path) -> None:
                data = safe_json_load(path, {})
                self._send_json(json.dumps(data, indent=2, sort_keys=True, default=str))

            def _handle_runs_list(self, n: int, cfg: "Config") -> None:
                runs_dir = cfg.runs_dir
                if not runs_dir.exists():
                    self._send_json("[]")
                    return
                dirs = sorted(
                    (p for p in runs_dir.iterdir() if p.is_dir()),
                    key=lambda p: p.name,
                    reverse=True,
                )[:n]
                result = [
                    {
                        "runId": d.name,
                        "summary": safe_json_load(d / "primary" / "run.json", {}),
                    }
                    for d in dirs
                ]
                self._send_json(
                    json.dumps(result, indent=2, sort_keys=True, default=str)
                )

            def _handle_run_detail(self, run_id: str, cfg: "Config") -> None:
                run_dir = cfg.runs_dir / run_id
                if not run_dir.exists():
                    self.send_response(404)
                    self.end_headers()
                    return
                result: dict[str, Any] = {}
                for sub in ("primary", "selffix", "major"):
                    sub_dir = run_dir / sub
                    run_json = safe_json_load(sub_dir / "run.json", {})
                    attempts: list[dict[str, Any]] = []
                    jsonl = sub_dir / "issue_attempts.jsonl"
                    if jsonl.exists():
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
                    if run_json or attempts:
                        result[sub] = {"run": run_json, "attempts": attempts}
                self._send_json(
                    json.dumps(result, indent=2, sort_keys=True, default=str)
                )

            def _handle_events(self, tail: int, cfg: "Config") -> None:
                events: list[Any] = []
                if cfg.events_file.exists():
                    for line in cfg.events_file.read_text(
                        encoding="utf-8", errors="replace"
                    ).splitlines():
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            events.append(json.loads(line))
                        except json.JSONDecodeError:
                            events.append({"raw": line})
                self._send_json(
                    json.dumps(events[-tail:], indent=2, sort_keys=True, default=str)
                )

        server = _HTTPServer(("", config.http_port), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        _log(f"HTTP API listening on port {config.http_port}")
