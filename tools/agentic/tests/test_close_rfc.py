from __future__ import annotations

import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CLOSE_RFC_PATH = REPO_ROOT / "tools" / "agentic" / "close_rfc.py"


def load_module():
    spec = importlib.util.spec_from_file_location("close_rfc", CLOSE_RFC_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _make_rfc_file(tmp_path: Path, num: str, title: str) -> Path:
    docs = tmp_path / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    rfc_file = docs / f"RFC-{num}-{title.replace(' ', '-')}.md"
    rfc_file.write_text(
        f"# RFC-{num}: {title}\n\n**Status:** Draft — v1\n\n## Problem\n\nSome problem.\n",
        encoding="utf-8",
    )
    return rfc_file


def _make_index(tmp_path: Path, open_rows: list[str]) -> Path:
    docs = tmp_path / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    index = docs / "RFC-INDEX.md"
    rows = "\n".join(open_rows)
    index.write_text(
        f"# RFC Index\n\n**Total RFCs:** {len(open_rows)} open\n\n"
        "## Open RFCs\n\n"
        "| # | Title | Status | Priority | Effort | Blocked By |\n"
        "|---|-------|--------|----------|--------|------------|\n"
        f"{rows}\n\n"
        "---\n\n"
        "## Closed RFCs\n\n"
        "| # | Title | Resolution |\n"
        "|---|-------|------------|\n"
        "| RFC-001 | Old RFC | Done |\n",
        encoding="utf-8",
    )
    return index


def test_update_rfc_status_replaces_draft(tmp_path: Path) -> None:
    m = load_module()
    _make_rfc_file(tmp_path, "055", "Auto-Close RFC")
    rfc_file = tmp_path / "docs" / "RFC-055-Auto-Close-RFC.md"

    changed = m._update_rfc_status(rfc_file, "abc1234")

    assert changed is True
    text = rfc_file.read_text(encoding="utf-8")
    assert "Done — SAIL (commit abc1234)" in text
    assert "Draft" not in text


def test_update_rfc_status_no_op_when_no_draft_line(tmp_path: Path) -> None:
    m = load_module()
    rfc_file = tmp_path / "rfc.md"
    rfc_file.write_text("# RFC-099\n\n**Status:** Done — already\n", encoding="utf-8")

    changed = m._update_rfc_status(rfc_file, "deadbeef")

    assert changed is False
    assert "already" in rfc_file.read_text(encoding="utf-8")


def test_update_index_moves_row_from_open_to_closed(tmp_path: Path) -> None:
    m = load_module()
    _make_index(
        tmp_path,
        [
            "| RFC-055 | Auto-Close RFC Documents | Draft — v1 | Medium | S | |",
            "| RFC-057 | Add dry-run flag | Draft — v1 | Medium | M | |",
        ],
    )

    changed = m._update_index(tmp_path, "rfc-055", "Auto-Close RFC Documents")

    assert changed is True
    text = (tmp_path / "docs" / "RFC-INDEX.md").read_text(encoding="utf-8")

    # Row removed from Open section
    open_section = text.split("## Open RFCs")[1].split("##")[0]
    assert "RFC-055" not in open_section

    # Row added to Closed section
    closed_section = text.split("## Closed RFCs")[1]
    assert "RFC-055" in closed_section
    assert "Done — SAIL" in closed_section


def test_update_index_decrements_open_count(tmp_path: Path) -> None:
    m = load_module()
    _make_index(
        tmp_path,
        ["| RFC-055 | Auto-Close RFC | Draft — v1 | Medium | S | |"],
    )

    m._update_index(tmp_path, "rfc-055", "Auto-Close RFC")

    text = (tmp_path / "docs" / "RFC-INDEX.md").read_text(encoding="utf-8")
    assert "0 open" in text


def test_update_index_returns_false_when_rfc_not_in_open(tmp_path: Path) -> None:
    m = load_module()
    _make_index(tmp_path, ["| RFC-057 | Some other RFC | Draft — v1 | Low | S | |"])

    changed = m._update_index(tmp_path, "rfc-055", "Missing RFC")

    assert changed is False


def test_find_rfc_file_returns_first_match(tmp_path: Path) -> None:
    m = load_module()
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "RFC-054-Some-Title.md").write_text("content", encoding="utf-8")

    result = m._find_rfc_file(tmp_path, "rfc-054")

    assert result is not None
    assert result.name == "RFC-054-Some-Title.md"


def test_find_rfc_file_returns_none_when_missing(tmp_path: Path) -> None:
    m = load_module()
    (tmp_path / "docs").mkdir()

    result = m._find_rfc_file(tmp_path, "rfc-099")

    assert result is None
