#!/usr/bin/env python3
"""Concretize in isolated staging and report packages not currently installed.

This tool intentionally does not run `spack install` and does not mutate the
source environment directory. It copies environment files into a temporary
staging directory, concretizes there, and compares concretized hashes against
`spack find --json`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

EXIT_OK = 0
EXIT_PRECONDITION = 3
EXIT_CONCRETIZE_FAILED = 2
EXIT_PARSE_FAILED = 4


def run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=True,
        check=False,
    )


def fail(msg: str, code: int) -> int:
    print(f"ERROR: {msg}", file=sys.stderr)
    return code


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Concretize Zephyr specs in an isolated staging env and report "
            "which concretized package hashes are not currently installed."
        )
    )
    parser.add_argument(
        "--source-env-dir",
        default="/workspace/pkg/zephyr",
        help="Path to source environment dir (default: /workspace/pkg/zephyr)",
    )
    parser.add_argument(
        "--stage-root",
        default="/tmp/zephyr_concretize_staging",
        help="Base dir for staging env dirs (default: /tmp/zephyr_concretize_staging)",
    )
    parser.add_argument(
        "--spec",
        action="append",
        default=[],
        help="Spec to analyze (repeatable). If omitted, analyze all env roots.",
    )
    parser.add_argument(
        "--forbidden-regex",
        default=r"(^|[^A-Za-z0-9_-])(py-torch|py-jax|py-jaxlib|torch|jax|jaxlib|llvm)([^A-Za-z0-9_-]|$)",
        help="Regex used to flag forbidden package names in missing set.",
    )
    parser.add_argument(
        "--output-json",
        default="",
        help="Path for JSON report. Default: <stage-root>/report-<timestamp>.json",
    )
    parser.add_argument(
        "--install-tree",
        default="",
        help=(
            "Install tree to query for installed packages (passed to "
            "'spack find --install-tree'). Defaults to /opt/spack_store/install_tree "
            "if present, else Spack default ('all')."
        ),
    )
    parser.add_argument(
        "--keep-stage",
        action="store_true",
        help="Keep staging directory after completion.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print detailed command output and diagnostics.",
    )
    parser.add_argument(
        "--allow-deprecated",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Allow concretizer to select deprecated versions (default: true).",
    )
    return parser.parse_args()


def ensure_spack_available() -> bool:
    return shutil.which("spack") is not None


def copy_source_env(source_env_dir: Path, stage_dir: Path) -> tuple[Path, bool]:
    """Copy environment files into stage; returns (manifest_path, lock_copied)."""
    src_yaml = source_env_dir / "spack.yaml"
    src_src_yaml = source_env_dir / "spack_src.yaml"
    src_lock = source_env_dir / "spack.lock"

    if src_yaml.exists():
        shutil.copy2(src_yaml, stage_dir / "spack.yaml")
    elif src_src_yaml.exists():
        shutil.copy2(src_src_yaml, stage_dir / "spack.yaml")
    else:
        raise FileNotFoundError(f"Neither {src_yaml} nor {src_src_yaml} exists.")

    lock_copied = False
    if src_lock.exists():
        shutil.copy2(src_lock, stage_dir / "spack.lock")
        lock_copied = True

    return stage_dir / "spack.yaml", lock_copied


def parse_spec_json(spec_json: dict[str, Any]) -> list[dict[str, Any]]:
    nodes = spec_json.get("spec", {}).get("nodes", [])
    if not isinstance(nodes, list):
        raise ValueError("Unexpected spec JSON format: spec.nodes is not a list")
    return nodes


def gather_concretized_nodes(
    stage_dir: Path,
    requested_specs: list[str],
    verbose: bool,
) -> tuple[dict[str, dict[str, Any]], dict[str, set[str]], list[str]]:
    """Return (hash->node, hash->origin specs, analyzed roots)."""
    nodes_by_hash: dict[str, dict[str, Any]] = {}
    origin_specs: dict[str, set[str]] = {}
    analyzed_roots: list[str] = []

    if requested_specs:
        roots = requested_specs
    else:
        lock_path = stage_dir / "spack.lock"
        lock_data = load_json(lock_path)
        roots = [root["spec"] for root in lock_data.get("roots", [])]

    for root_spec in roots:
        analyzed_roots.append(root_spec)
        proc = run(["spack", "-e", str(stage_dir), "spec", "-j", root_spec])
        if proc.returncode != 0:
            raise RuntimeError(
                f"Failed to render spec JSON for {root_spec}:\n{proc.stderr.strip()}"
            )
        spec_json = json.loads(proc.stdout)
        for node in parse_spec_json(spec_json):
            h = node.get("hash")
            if not h:
                continue
            nodes_by_hash[h] = node
            origin_specs.setdefault(h, set()).add(root_spec)

        if verbose:
            print(f"[verbose] analyzed root spec: {root_spec}")

    return nodes_by_hash, origin_specs, analyzed_roots


def gather_installed_hashes(install_tree: str) -> dict[str, dict[str, Any]]:
    cmd = ["spack", "find", "--json"]
    if install_tree:
        cmd.extend(["--install-tree", install_tree])
    proc = run(cmd)
    if proc.returncode != 0:
        raise RuntimeError(f"spack find --json failed:\n{proc.stderr.strip()}")
    data = json.loads(proc.stdout or "[]")
    installed: dict[str, dict[str, Any]] = {}
    for node in data:
        h = node.get("hash")
        if h:
            installed[h] = node
    return installed


def main() -> int:
    args = parse_args()
    source_env_dir = Path(args.source_env_dir).resolve()
    stage_root = Path(args.stage_root).resolve()

    if not ensure_spack_available():
        return fail("spack not found in PATH", EXIT_PRECONDITION)
    if not source_env_dir.is_dir():
        return fail(f"source env dir not found: {source_env_dir}", EXIT_PRECONDITION)

    if os.environ.get("SYGALDRY_IN_CONTAINER") != "1":
        print(
            "WARNING: SYGALDRY_IN_CONTAINER!=1; tool is intended for Zephyr container usage.",
            file=sys.stderr,
        )

    stage_root.mkdir(parents=True, exist_ok=True)
    stage_dir = Path(tempfile.mkdtemp(prefix="run-", dir=str(stage_root))).resolve()
    install_tree = args.install_tree
    if not install_tree:
        default_tree = Path("/opt/spack_store/install_tree")
        if default_tree.exists():
            install_tree = str(default_tree)

    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_json = (
        Path(args.output_json).resolve()
        if args.output_json
        else (stage_root / f"report-{ts}.json").resolve()
    )

    manifest_path = stage_dir / "spack.yaml"
    lock_copied = False
    report: dict[str, Any] = {}

    try:
        manifest_path, lock_copied = copy_source_env(source_env_dir, stage_dir)
        if args.verbose:
            print(f"[verbose] stage dir: {stage_dir}")
            print(f"[verbose] manifest: {manifest_path}")
            print(f"[verbose] lock copied: {lock_copied}")

        for spec in args.spec:
            proc_add = run(["spack", "-e", str(stage_dir), "add", spec])
            if proc_add.returncode != 0:
                return fail(
                    f"failed to add spec '{spec}':\n{proc_add.stderr.strip()}",
                    EXIT_PRECONDITION,
                )

        conc_cmd = ["spack", "-e", str(stage_dir), "concretize", "--force"]
        if args.allow_deprecated:
            conc_cmd.append("--deprecated")
        proc_conc = run(conc_cmd)
        if proc_conc.returncode != 0:
            return fail(
                f"concretization failed:\n{proc_conc.stderr.strip()}",
                EXIT_CONCRETIZE_FAILED,
            )

        nodes_by_hash, origin_specs, analyzed_roots = gather_concretized_nodes(
            stage_dir=stage_dir,
            requested_specs=args.spec,
            verbose=args.verbose,
        )
        installed = gather_installed_hashes(install_tree=install_tree)

        forbidden = re.compile(args.forbidden_regex, re.IGNORECASE)
        missing: list[dict[str, Any]] = []
        for h, node in nodes_by_hash.items():
            if h in installed:
                continue
            name = node.get("name", "")
            version = node.get("version", "")
            missing.append(
                {
                    "name": name,
                    "version": version,
                    "hash": h,
                    "forbidden_match": bool(forbidden.search(name)),
                    "origin_specs": sorted(origin_specs.get(h, set())),
                }
            )

        missing.sort(key=lambda x: (x["name"], x["version"], x["hash"]))

        report = {
            "source_env_dir": str(source_env_dir),
            "stage_dir": str(stage_dir),
            "stage_manifest": str(manifest_path),
            "stage_lock_copied_from_source": lock_copied,
            "requested_specs": args.spec,
            "analyzed_root_specs": analyzed_roots,
            "installed_install_tree": install_tree or "all",
            "concretization_success": True,
            "forbidden_regex": args.forbidden_regex,
            "totals": {
                "concretized_nodes": len(nodes_by_hash),
                "installed_nodes_matched": len(nodes_by_hash) - len(missing),
                "missing_nodes": len(missing),
                "forbidden_missing_nodes": sum(
                    1 for m in missing if m["forbidden_match"]
                ),
            },
            "missing": missing,
            "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        }

        output_json.parent.mkdir(parents=True, exist_ok=True)
        with output_json.open("w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, sort_keys=False)
            f.write("\n")

        print("Concretization analysis complete")
        print(f"  source env: {source_env_dir}")
        print(f"  stage dir:  {stage_dir}")
        print(f"  report:     {output_json}")
        print(f"  roots:      {len(analyzed_roots)}")
        print(f"  nodes:      {report['totals']['concretized_nodes']}")
        print(f"  missing:    {report['totals']['missing_nodes']}")
        print(f"  forbidden:  {report['totals']['forbidden_missing_nodes']}")

        if missing:
            print("\nTop missing packages:")
            for item in missing[:20]:
                flag = " [FORBIDDEN]" if item["forbidden_match"] else ""
                print(f"  - {item['name']}@{item['version']} /{item['hash']}{flag}")

    except FileNotFoundError as exc:
        return fail(str(exc), EXIT_PRECONDITION)
    except json.JSONDecodeError as exc:
        return fail(f"JSON parse error: {exc}", EXIT_PARSE_FAILED)
    except Exception as exc:  # pylint: disable=broad-except
        return fail(str(exc), EXIT_PARSE_FAILED)
    finally:
        if not args.keep_stage:
            shutil.rmtree(stage_dir, ignore_errors=True)

    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
