#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import sys
from collections import defaultdict
from time import sleep


def read_events(path):
    if not os.path.exists(path):
        return []
    events = []
    with open(path, "r", encoding="utf-8") as file:
        for line in file:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def parse_timestamp(value):
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def summarize_runs(events):
    runs = {}
    for event in events:
        workflow_id = event.get("workflowId")
        run_id = event.get("runId")
        if not workflow_id or not run_id:
            continue
        key = (workflow_id, run_id)
        record = runs.setdefault(
            key,
            {
                "workflowId": workflow_id,
                "runId": run_id,
                "last": None,
                "events": 0,
            },
        )
        timestamp = parse_timestamp(event.get("timestamp"))
        if timestamp and (record["last"] is None or timestamp > record["last"]):
            record["last"] = timestamp
        record["events"] += 1

    return sorted(
        runs.values(),
        key=lambda record: record["last"] or dt.datetime.min,
        reverse=True,
    )


def resolve_run(events, workflow_id, run_id, latest):
    if latest:
        runs = summarize_runs(events)
        if workflow_id:
            runs = [run for run in runs if run["workflowId"] == workflow_id]
        if not runs:
            raise ValueError("no runs found")
        return runs[0]["workflowId"], runs[0]["runId"]

    if workflow_id and run_id:
        return workflow_id, run_id

    raise ValueError("either provide --workflow-id and --run-id, or use --latest")


def collect_steps(events, workflow_id, run_id):
    steps = defaultdict(
        lambda: {
            "status": "pending",
            "exitCode": None,
            "durationSec": None,
            "stdoutPath": "",
            "stderrPath": "",
            "structuredPath": "",
            "start": None,
            "finish": None,
        }
    )
    first_seen = {}

    for event in events:
        if event.get("workflowId") != workflow_id or event.get("runId") != run_id:
            continue

        step_id = event.get("stepId") or event.get("stepName") or "unknown"
        if step_id not in first_seen:
            first_seen[step_id] = len(first_seen)

        timestamp = parse_timestamp(event.get("timestamp"))
        if event.get("status") == "step_started":
            steps[step_id]["status"] = "running"
            if timestamp and (
                steps[step_id]["start"] is None or timestamp < steps[step_id]["start"]
            ):
                steps[step_id]["start"] = timestamp
        elif event.get("status") == "step_finished":
            exit_code = event.get("exitCode")
            steps[step_id]["status"] = "success" if exit_code == 0 else "failed"
            steps[step_id]["exitCode"] = exit_code
            steps[step_id]["durationSec"] = event.get("durationSec")
            steps[step_id]["stdoutPath"] = event.get("stdoutPath") or ""
            steps[step_id]["stderrPath"] = event.get("stderrPath") or ""
            steps[step_id]["structuredPath"] = event.get("structuredPath") or ""
            if timestamp and (
                steps[step_id]["finish"] is None or timestamp > steps[step_id]["finish"]
            ):
                steps[step_id]["finish"] = timestamp

    ordered = sorted(steps.items(), key=lambda item: first_seen[item[0]])
    return ordered


def read_run_events(events_path, workflow_id, run_id):
    events = []
    for event in read_events(events_path):
        if event.get("workflowId") == workflow_id and event.get("runId") == run_id:
            events.append(event)
    return events


def list_runs(events):
    for run in summarize_runs(events):
        timestamp = run["last"].isoformat() if run["last"] else ""
        print(f"{run['workflowId']}\t{run['runId']}\t{timestamp}\t{run['events']}")


def show_steps(events, workflow_id, run_id):
    for step_id, info in collect_steps(events, workflow_id, run_id):
        print(
            f"{step_id}\t{info['status']}\t{info.get('exitCode')}\t{info.get('durationSec')}"
            f"\t{info.get('stdoutPath','')}\t{info.get('stderrPath','')}\t{info.get('structuredPath','')}"
        )


def summary(events, workflow_id, run_id):
    steps = collect_steps(events, workflow_id, run_id)
    if not steps:
        print(f"Pipeline: {workflow_id}")
        print("Status: NO_EVENTS")
        return

    success_count = sum(1 for _, info in steps if info["status"] == "success")
    failed_count = sum(1 for _, info in steps if info["status"] == "failed")
    total = len(steps)
    if failed_count:
        status = "FAILED"
    elif success_count == total:
        status = "SUCCESS"
    else:
        status = "RUNNING"

    starts = [info["start"] for _, info in steps if info["start"]]
    finishes = [info["finish"] for _, info in steps if info["finish"]]
    duration = "?"
    if starts and finishes:
        duration = f"{int((max(finishes) - min(starts)).total_seconds())}s"

    print(f"Pipeline: {workflow_id}")
    print(f"Run: {run_id}")
    print(f"Status: {status} ({success_count}/{total} steps succeeded)")
    print(f"Duration: {duration}")
    print("")
    for step_id, info in steps:
        step_duration = info.get("durationSec")
        duration_text = f"{step_duration}s" if step_duration is not None else "-"
        print(f"  {step_id:<20} {info['status']:<8} {duration_text}")


def tail(events_path, workflow_id, run_id):
    for event in read_run_events(events_path, workflow_id, run_id):
        print(json.dumps(event))


def follow(events_path, workflow_id, run_id):
    if not os.path.exists(events_path):
        print(f"events file not found: {events_path}", file=sys.stderr)
        return

    # bootstrap existing events for the run
    tail(events_path, workflow_id, run_id)

    with open(events_path, "r", encoding="utf-8") as file:
        file.seek(0, os.SEEK_END)
        while True:
            line = file.readline()
            if not line:
                sleep(0.5)
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("workflowId") != workflow_id or event.get("runId") != run_id:
                continue
            print(json.dumps(event), flush=True)


def read_structured_lines(paths):
    lines = []
    for path in paths:
        if not path or not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8") as file:
            for raw_line in file:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    event = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue
                timestamp = parse_timestamp(event.get("timestamp"))
                lines.append((timestamp or dt.datetime.min, event))
    lines.sort(key=lambda item: item[0])
    return [line for _, line in lines]


def logs(events, workflow_id, run_id):
    steps = collect_steps(events, workflow_id, run_id)
    structured_paths = []
    for _, info in steps:
        if info.get("structuredPath"):
            structured_paths.append(info["structuredPath"])
    lines = read_structured_lines(structured_paths)
    for line in lines:
        timestamp = parse_timestamp(line.get("timestamp"))
        stamp = timestamp.strftime("%H:%M:%S") if timestamp else "--:--:--"
        step_id = line.get("stepId") or line.get("stepName") or "unknown"
        stream = line.get("stream", "stdout")
        message = line.get("message", "")
        if stream == "stderr":
            message = f"[stderr] {message}"
        print(f"[{stamp}] {step_id:<16} | {message}")


def load_manifest(log_dir, workflow_id, run_id):
    candidate = os.path.join(
        log_dir, f"{safe_name(workflow_id)}_{safe_name(run_id)}_plan.json"
    )
    if not os.path.exists(candidate):
        return None
    try:
        with open(candidate, "r", encoding="utf-8") as file:
            return json.load(file)
    except json.JSONDecodeError:
        return None


def safe_name(value):
    return (
        value.strip()
        .replace("/", "_")
        .replace("\\", "_")
        .replace(" ", "_")
        .replace(":", "_")
    )


def dag(events, workflow_id, run_id, log_dir):
    manifest = load_manifest(log_dir, workflow_id, run_id)
    if not manifest:
        print(
            "No DAG manifest found for run. Expected *_plan.json in log dir.",
            file=sys.stderr,
        )
        return 1

    steps = manifest.get("steps", [])
    if not steps:
        print("DAG: no steps")
        return 0

    print("DAG:")
    by_id = {step.get("id"): step for step in steps}
    for step in steps:
        step_id = step.get("id", "unknown")
        depends_on = step.get("dependsOn") or []
        if depends_on:
            print(f"  {', '.join(depends_on)} -> {step_id}")
        else:
            print(f"  {step_id}")

    # also print terminal nodes
    downstream = set()
    for step in steps:
        for dep in step.get("dependsOn") or []:
            downstream.add(dep)
    terminals = [step_id for step_id in by_id if step_id not in downstream]
    if terminals:
        print(f"Terminal: {', '.join(sorted(terminals))}")
    return 0


def add_run_selection(parser):
    parser.add_argument("--workflow-id", help="Workflow ID")
    parser.add_argument("--run-id", help="Run ID")
    parser.add_argument(
        "--latest",
        action="store_true",
        help="Use most recent run (optionally scoped by --workflow-id)",
    )


def main():
    parser = argparse.ArgumentParser(description="Inspect Temporal step events")
    parser.add_argument(
        "--log-dir", default="logs", help="log directory (default: logs)"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list-runs")

    show = sub.add_parser("show-steps")
    add_run_selection(show)

    summary_cmd = sub.add_parser("summary")
    add_run_selection(summary_cmd)

    tail_cmd = sub.add_parser("tail")
    add_run_selection(tail_cmd)

    follow_cmd = sub.add_parser("follow")
    add_run_selection(follow_cmd)

    logs_cmd = sub.add_parser("logs")
    add_run_selection(logs_cmd)

    dag_cmd = sub.add_parser("dag")
    add_run_selection(dag_cmd)

    args = parser.parse_args()
    events_path = os.path.join(args.log_dir, "events.jsonl")
    events = read_events(events_path)

    if args.command == "list-runs":
        list_runs(events)
        return

    try:
        workflow_id, run_id = resolve_run(
            events,
            getattr(args, "workflow_id", None),
            getattr(args, "run_id", None),
            getattr(args, "latest", False),
        )
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(2)

    if args.command == "show-steps":
        show_steps(events, workflow_id, run_id)
    elif args.command == "summary":
        summary(events, workflow_id, run_id)
    elif args.command == "tail":
        tail(events_path, workflow_id, run_id)
    elif args.command == "follow":
        follow(events_path, workflow_id, run_id)
    elif args.command == "logs":
        logs(events, workflow_id, run_id)
    elif args.command == "dag":
        rc = dag(events, workflow_id, run_id, args.log_dir)
        if rc != 0:
            sys.exit(rc)


if __name__ == "__main__":
    main()
