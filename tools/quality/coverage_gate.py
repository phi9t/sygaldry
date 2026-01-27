#!/usr/bin/env python3
"""Coverage ratchet gate for review/refactor quality checks."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sys
from typing import Any


def _load_structured(path: pathlib.Path) -> dict[str, Any]:
    raw = path.read_text(encoding="utf-8")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        try:
            import yaml  # type: ignore
        except Exception as exc:  # pragma: no cover - import guard
            raise RuntimeError(
                f"{path} is not valid JSON and PyYAML is unavailable for YAML parsing"
            ) from exc
        data = yaml.safe_load(raw)
        if not isinstance(data, dict):
            raise RuntimeError(f"{path} must contain a JSON/YAML object")
        return data


def _read_changed_files(path: pathlib.Path) -> set[str]:
    if not path.exists():
        return set()
    return {
        line.strip().lstrip("./")
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }


def _is_touched(sources: list[str], changed_files: set[str]) -> bool:
    if not sources or not changed_files:
        return False
    normalized_sources = [s.lstrip("./") for s in sources]
    for changed in changed_files:
        for source in normalized_sources:
            if source.endswith("/"):
                if changed.startswith(source):
                    return True
            elif changed == source or changed.startswith(f"{source}/"):
                return True
    return False


def _waiver_active(module_cfg: dict[str, Any], today: dt.date) -> tuple[bool, str]:
    waiver = module_cfg.get("waiver")
    if not isinstance(waiver, dict):
        return False, ""

    expires = waiver.get("expires")
    if expires:
        try:
            expiry = dt.date.fromisoformat(str(expires))
        except ValueError:
            return False, ""
        if expiry < today:
            return False, ""

    reason = str(waiver.get("reason", "waiver active"))
    owner = str(waiver.get("owner", "unassigned"))
    return True, f"owner={owner}, reason={reason}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Coverage ratchet gate")
    parser.add_argument("--baseline", required=True, help="Path to baseline JSON/YAML")
    parser.add_argument(
        "--metrics", required=True, help="Path to generated metrics JSON"
    )
    parser.add_argument(
        "--changed-files", required=True, help="Path to changed-files list"
    )
    parser.add_argument(
        "--strict", action="store_true", help="Fail when expected metrics are missing"
    )
    args = parser.parse_args()

    baseline_path = pathlib.Path(args.baseline)
    metrics_path = pathlib.Path(args.metrics)
    changed_path = pathlib.Path(args.changed_files)

    baseline = _load_structured(baseline_path)
    metrics_doc = _load_structured(metrics_path)

    defaults = baseline.get("defaults", {})
    modules = baseline.get("modules", {})
    if not isinstance(defaults, dict):
        raise RuntimeError("baseline.defaults must be an object")
    if not isinstance(modules, dict):
        raise RuntimeError("baseline.modules must be an object")

    metrics = metrics_doc.get("metrics", [])
    if not isinstance(metrics, list):
        raise RuntimeError("metrics.metrics must be a list")

    changed_files = _read_changed_files(changed_path)
    today = dt.date.today()

    target_default = float(defaults.get("target", 80.0))
    improvement_default = float(defaults.get("min_improvement", 2.0))
    tolerance = float(defaults.get("tolerance", 0.01))

    failures: list[str] = []
    warnings: list[str] = []
    seen_keys: set[str] = set()

    for metric in metrics:
        if not isinstance(metric, dict):
            continue
        key = str(metric.get("key", "")).strip()
        if not key:
            continue
        seen_keys.add(key)

        value = float(metric.get("value", 0.0))
        sources = metric.get("sources", [])
        if not isinstance(sources, list):
            sources = []
        touched = _is_touched([str(s) for s in sources], changed_files)

        module_cfg_raw = modules.get(key, {})
        module_cfg = module_cfg_raw if isinstance(module_cfg_raw, dict) else {}

        target = float(module_cfg.get("target", target_default))
        improvement = float(module_cfg.get("min_improvement", improvement_default))
        baseline_value = module_cfg.get("baseline")

        waiver_is_active, waiver_note = _waiver_active(module_cfg, today)

        if baseline_value is None:
            if touched and not waiver_is_active and value + tolerance < target:
                failures.append(
                    f"{key}: touched new/untracked module has {value:.2f}% < target {target:.2f}%"
                )
            elif touched and waiver_is_active:
                warnings.append(f"{key}: waiver active ({waiver_note})")
            else:
                warnings.append(f"{key}: no baseline; skipped (untouched)")
            continue

        baseline_float = float(baseline_value)
        if value + tolerance < baseline_float:
            failures.append(
                f"{key}: regression {value:.2f}% < baseline {baseline_float:.2f}%"
            )

        if baseline_float >= target and value + tolerance < target:
            failures.append(f"{key}: dropped below target {value:.2f}% < {target:.2f}%")

        if touched and baseline_float < target and not waiver_is_active:
            required = min(target, baseline_float + improvement)
            if value + tolerance < required:
                failures.append(
                    f"{key}: touched module must improve to {required:.2f}%, got {value:.2f}%"
                )
        elif touched and waiver_is_active:
            warnings.append(f"{key}: touched with active waiver ({waiver_note})")

    for key, module_cfg_raw in modules.items():
        if key in seen_keys:
            continue
        module_cfg = module_cfg_raw if isinstance(module_cfg_raw, dict) else {}
        sources = module_cfg.get("sources", [])
        if not isinstance(sources, list):
            sources = []
        touched = _is_touched([str(s) for s in sources], changed_files)
        if touched:
            message = f"{key}: touched but no coverage metric produced"
            if args.strict:
                failures.append(message)
            else:
                warnings.append(message)

    for warning in warnings:
        print(f"[quality][coverage] WARN: {warning}")
    for failure in failures:
        print(f"[quality][coverage] FAIL: {failure}")

    if failures:
        print(f"[quality][coverage] FAILED with {len(failures)} issue(s)")
        return 1

    print(
        f"[quality][coverage] PASS ({len(metrics)} metric(s), {len(warnings)} warning(s), {len(changed_files)} changed file(s))"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
