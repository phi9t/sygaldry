from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DISCOVER_PATH = REPO_ROOT / "tools" / "agentic" / "discover_issues.py"


def load_module():
    spec = importlib.util.spec_from_file_location("discover_issues", DISCOVER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_discover_todos_ignores_string_literals_but_keeps_real_annotations(
    tmp_path: Path,
) -> None:
    module = load_module()
    repo_dir = tmp_path / "repo"
    repo_dir.mkdir()

    todo_tag = "TO" "DO"
    fixme_tag = "FIX" "ME"
    hack_tag = "HA" "CK"

    (repo_dir / "sample.py").write_text(
        "\n".join(
            [
                f'message = "{fixme_tag}: string literal only"',
                f'note = "# {todo_tag}: still part of a string"',
                f"value = 1  # {hack_tag}: real inline comment",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (repo_dir / "notes.org").write_text(
        "\n".join(
            [
                f"** {todo_tag} retained org heading",
                f"| {todo_tag}/{fixme_tag}/{hack_tag} | descriptive table row |",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    subprocess.run(["git", "init"], cwd=repo_dir, check=True, capture_output=True)
    subprocess.run(["git", "add", "."], cwd=repo_dir, check=True, capture_output=True)

    issues = module.discover_todos(repo_dir, 20)

    assert [issue["description"] for issue in issues] == [
        "notes.org:1: ** TODO retained org heading",
        "sample.py:3: value = 1  # HACK: real inline comment",
    ]
    assert [issue["priority"] for issue in issues] == [3, 2]
