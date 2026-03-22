#!/usr/bin/env python3
"""tools/agentic/parse_session_events.py — Parse claude stream-json events from a structured JSONL log.

Each line of a *_structured.jsonl file is a structuredLogLine wrapper:
  {"timestamp":"...","workflowId":"...","stream":"stdout","message":"<claude event JSON>","partial":false}

With --output-format stream-json, claude emits NDJSON to stdout.  The lineBufferWriter
captures each stdout line into the message field.  This script unwraps those envelopes
and extracts a SessionSummary from the claude stream events.

Usage:
  parse_session_events.py --events-file <path>         # parse specific file
  parse_session_events.py --log-dir <dir>              # auto-find latest *_structured.jsonl
  parse_session_events.py --log-dir <dir> \\
      --update-current-task <path>                     # merge session into current_task.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class SessionSummary:
    session_id: str = ""
    model: str = ""
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_creation_tokens: int = 0
    total_cost_usd: float = 0.0
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    files_touched: list[str] = field(default_factory=list)
    last_message: str = ""
    turn_count: int = 0
    status: str = "running"

    def to_dict(self) -> dict[str, Any]:
        return {
            "cacheCreationTokens": self.cache_creation_tokens,
            "cacheReadTokens": self.cache_read_tokens,
            "filesTouched": sorted(set(self.files_touched)),
            "inputTokens": self.input_tokens,
            "lastMessage": self.last_message[:500],
            "model": self.model,
            "outputTokens": self.output_tokens,
            "sessionId": self.session_id,
            "status": self.status,
            "toolCalls": self.tool_calls[-50:],  # cap to last 50 to avoid bloat
            "totalCostUsd": round(self.total_cost_usd, 6),
            "turnCount": self.turn_count,
        }


def parse_events(path: Path) -> SessionSummary:
    """Parse a *_structured.jsonl file and return a SessionSummary."""
    s = SessionSummary()
    if not path.exists():
        return s

    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return s

    for raw_line in lines:
        raw_line = raw_line.strip()
        if not raw_line:
            continue

        # Each line is a structuredLogLine wrapper
        try:
            wrapper = json.loads(raw_line)
        except json.JSONDecodeError:
            continue

        # Only process stdout non-partial lines (where claude stream-json lives)
        if wrapper.get("stream") != "stdout" or wrapper.get("partial"):
            continue

        msg_text = wrapper.get("message", "")
        if not msg_text:
            continue

        # Parse the actual claude stream-json event from the message field
        try:
            ev = json.loads(msg_text)
        except json.JSONDecodeError:
            continue

        ev_type = ev.get("type", "")

        if ev_type == "system" and ev.get("subtype") == "init":
            s.session_id = ev.get("session_id", "")
            s.model = ev.get("model", "")

        elif ev_type == "assistant":
            s.turn_count += 1
            msg = ev.get("message", {})
            usage = msg.get("usage", {})
            s.input_tokens += usage.get("input_tokens", 0)
            s.output_tokens += usage.get("output_tokens", 0)
            s.cache_read_tokens += usage.get("cache_read_input_tokens", 0)
            s.cache_creation_tokens += usage.get("cache_creation_input_tokens", 0)

            for block in msg.get("content", []):
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    text = block.get("text", "")
                    if text:
                        s.last_message = text
                elif block.get("type") == "tool_use":
                    tool_name = block.get("name", "")
                    tool_input = block.get("input", {})
                    s.tool_calls.append(
                        {
                            "name": tool_name,
                            "inputSummary": str(tool_input)[:200],
                        }
                    )
                    if tool_name in ("Edit", "Write", "MultiEdit"):
                        fp = tool_input.get("file_path", "")
                        if fp:
                            s.files_touched.append(fp)

        elif ev_type == "result":
            s.status = "completed"
            s.total_cost_usd = float(ev.get("total_cost_usd") or 0.0)
            usage = ev.get("usage", {})
            if usage:
                # Result event carries cumulative totals — prefer these
                s.input_tokens = usage.get("input_tokens", s.input_tokens)
                s.output_tokens = usage.get("output_tokens", s.output_tokens)
                s.cache_read_tokens = usage.get(
                    "cache_read_input_tokens", s.cache_read_tokens
                )
                s.cache_creation_tokens = usage.get(
                    "cache_creation_input_tokens", s.cache_creation_tokens
                )

    return s


def find_latest_events_file(log_dir: Path) -> Path | None:
    """Return the most recently modified *_structured.jsonl in log_dir."""
    if not log_dir.exists():
        return None
    candidates = list(log_dir.glob("*_structured.jsonl"))
    if not candidates:
        return None
    try:
        return max(candidates, key=lambda p: p.stat().st_mtime)
    except OSError:
        return candidates[-1]


def update_current_task(task_file: Path, session: SessionSummary) -> None:
    """Merge session data into an existing current_task.json in place."""
    payload: dict[str, Any] = {}
    if task_file.exists():
        try:
            payload = json.loads(task_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    payload["session"] = session.to_dict()
    payload["sessionUpdatedAt"] = (
        dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")
    )
    task_file.parent.mkdir(parents=True, exist_ok=True)
    task_file.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Parse claude stream-json events from a structured JSONL log"
    )
    parser.add_argument(
        "--events-file", type=Path, help="Specific *_structured.jsonl file"
    )
    parser.add_argument(
        "--log-dir", type=Path, help="Dir to search for latest *_structured.jsonl"
    )
    parser.add_argument(
        "--update-current-task",
        type=Path,
        metavar="PATH",
        help="Merge session into this current_task.json file",
    )
    args = parser.parse_args()

    events_file: Path | None = args.events_file
    if events_file is None and args.log_dir:
        events_file = find_latest_events_file(args.log_dir)

    if events_file is None:
        summary = SessionSummary()
    else:
        summary = parse_events(events_file)

    if args.update_current_task:
        update_current_task(args.update_current_task, summary)
    else:
        print(json.dumps(summary.to_dict()))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
