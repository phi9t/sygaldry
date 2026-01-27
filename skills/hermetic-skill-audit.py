#!/usr/bin/env python3
"""Audit a skill directory for hermetic global-promotion readiness."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

TEXT_SUFFIXES = {
    ".md",
    ".txt",
    ".sh",
    ".bash",
    ".zsh",
    ".py",
    ".yaml",
    ".yml",
    ".json",
    ".toml",
    ".ini",
    ".cfg",
}


@dataclass(frozen=True)
class PatternRule:
    name: str
    regex: re.Pattern[str]
    reason: str


FORBIDDEN_PATTERNS = [
    PatternRule(
        name="workspace-path",
        regex=re.compile(r"/workspace/"),
        reason="Repo/container workspace path dependency.",
    ),
    PatternRule(
        name="repo-container-path",
        regex=re.compile(r"(^|[\s`\"'])\./container/"),
        reason="Repo-relative container path dependency.",
    ),
    PatternRule(
        name="repo-tools-path",
        regex=re.compile(r"(^|[\s`\"'])tools/"),
        reason="Repo-root tools path dependency.",
    ),
    PatternRule(
        name="vendor-runtime-path",
        regex=re.compile(r"\.sygaldry/"),
        reason="Repo-vendored runtime path dependency.",
    ),
    PatternRule(
        name="abs-repo-path",
        regex=re.compile(
            r"/mnt/data_infra/workspace/sygaldry|/home/phi9t/workspace/sygaldry"
        ),
        reason="Absolute checkout path dependency.",
    ),
    PatternRule(
        name="opt-sygaldry-path",
        regex=re.compile(r"/opt/sygaldry/"),
        reason="Image-specific sygaldry path dependency.",
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit skill directory for hermetic global-promotion requirements."
    )
    parser.add_argument(
        "skill_paths",
        nargs="+",
        help="One or more skill directories (e.g. skills/codex-headless).",
    )
    return parser.parse_args()


def should_scan_file(path: Path) -> bool:
    if not path.is_file():
        return False
    if path.suffix.lower() in TEXT_SUFFIXES:
        return True
    return path.name in {"SKILL.md", "openai.yaml"}


def check_required_files(skill_dir: Path) -> list[str]:
    errors: list[str] = []
    required = [
        skill_dir / "SKILL.md",
        skill_dir / "agents" / "openai.yaml",
    ]
    for path in required:
        if not path.exists():
            errors.append(f"missing required file: {path}")
    return errors


def check_resource_hints(skill_dir: Path, skill_md_text: str) -> list[str]:
    errors: list[str] = []
    hint_to_path = {
        "scripts/": skill_dir / "scripts",
        "references/": skill_dir / "references",
        "assets/": skill_dir / "assets",
    }
    for hint, path in hint_to_path.items():
        if hint in skill_md_text and not path.exists():
            errors.append(f"SKILL.md references {hint} but missing path: {path}")
    return errors


def find_pattern_hits(skill_dir: Path) -> list[str]:
    errors: list[str] = []
    for file_path in sorted(skill_dir.rglob("*")):
        if not should_scan_file(file_path):
            continue
        try:
            text = file_path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line_num, line in enumerate(text.splitlines(), start=1):
            for rule in FORBIDDEN_PATTERNS:
                if rule.regex.search(line):
                    rel = file_path.as_posix()
                    snippet = line.strip()
                    errors.append(
                        f"{rel}:{line_num}: forbidden '{rule.name}' ({rule.reason}) :: {snippet}"
                    )
    return errors


def audit_skill(skill_dir: Path) -> int:
    print(f"== Auditing {skill_dir} ==")
    errors: list[str] = []

    if not skill_dir.exists() or not skill_dir.is_dir():
        print(f"ERROR: skill directory does not exist: {skill_dir}", file=sys.stderr)
        return 1

    errors.extend(check_required_files(skill_dir))

    skill_md = skill_dir / "SKILL.md"
    skill_md_text = ""
    if skill_md.exists():
        skill_md_text = skill_md.read_text(encoding="utf-8")
        errors.extend(check_resource_hints(skill_dir, skill_md_text))

    errors.extend(find_pattern_hits(skill_dir))

    if errors:
        for err in errors:
            print(f"ERROR: {err}")
        print(f"FAIL: {skill_dir} ({len(errors)} issue(s))")
        return 1

    print(f"PASS: {skill_dir}")
    return 0


def main() -> int:
    args = parse_args()
    exit_code = 0
    for raw_path in args.skill_paths:
        skill_dir = Path(raw_path).resolve()
        rc = audit_skill(skill_dir)
        if rc != 0:
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
