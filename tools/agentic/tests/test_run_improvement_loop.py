from __future__ import annotations

import json
import os
import stat
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
RUN_LOOP = REPO_ROOT / "tools" / "agentic" / "run_improvement_loop.sh"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_run_loop_writes_artifacts_with_fake_temporal(tmp_path):
    repo_dir = tmp_path / "repo"
    repo_dir.mkdir()
    (repo_dir / "temporal").mkdir()
    (repo_dir / "README.md").write_text("hello\n", encoding="utf-8")

    subprocess.run(["git", "init", "-b", "main"], cwd=repo_dir, check=True)
    subprocess.run(
        ["git", "config", "user.name", "Test User"], cwd=repo_dir, check=True
    )
    subprocess.run(
        ["git", "config", "user.email", "test@example.com"], cwd=repo_dir, check=True
    )
    subprocess.run(["git", "add", "README.md"], cwd=repo_dir, check=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=repo_dir, check=True)

    issues_file = tmp_path / "issues.json"
    issues_file.write_text(
        json.dumps(
            [
                {
                    "id": "issue-shellcheck-1",
                    "priority": 2,
                    "type": "shellcheck",
                    "title": "Fix shellcheck issue",
                    "description": "desc",
                    "files": ["tools/example.sh"],
                    "context": "{}",
                }
            ]
        ),
        encoding="utf-8",
    )

    fakebin = tmp_path / "fakebin"
    fakebin.mkdir()
    write_executable(
        fakebin / "nc",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    write_executable(
        fakebin / "go",
        """#!/usr/bin/env bash
set -eu -o pipefail
workflow_id=""
log_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    run)
      shift
      ;;
    -workflow-id)
      workflow_id="$2"
      shift 2
      ;;
    -log-dir)
      log_dir="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "$log_dir"
cat >"${log_dir}/${workflow_id}_fake-run_plan.json" <<JSON
{"workflowId":"${workflow_id}","runId":"fake-run","steps":[]}
JSON
cat >"${log_dir}/events.jsonl" <<JSONL
{"timestamp":"2026-03-07T00:00:00Z","workflowId":"${workflow_id}","runId":"fake-run","stepId":"validate","stepName":"validate","status":"step_finished","exitCode":0,"durationSec":1,"stdoutPath":"","stderrPath":"","structuredPath":"","message":""}
{"timestamp":"2026-03-07T00:00:01Z","workflowId":"${workflow_id}","runId":"fake-run","stepId":"create_pr","stepName":"create_pr","status":"step_finished","exitCode":0,"durationSec":1,"stdoutPath":"","stderrPath":"","structuredPath":"","message":""}
JSONL
cat <<JSON
{
  "workflowId": "${workflow_id}",
  "runId": "fake-run",
  "async": false,
  "result": {
    "succeeded": true,
    "steps": [
      {"id":"create_pr","result":{"outputs":{"pr_url":"https://example.test/pr/1"}}}
    ]
  }
}
JSON
""",
    )

    artifacts_dir = tmp_path / "artifacts"
    env = dict(os.environ)
    env["PATH"] = f"{fakebin}:{env['PATH']}"

    result = subprocess.run(
        [
            str(RUN_LOOP),
            "--repo-dir",
            str(repo_dir),
            "--run-id",
            "testrun",
            "--artifacts-dir",
            str(artifacts_dir),
            "--issues-file",
            str(issues_file),
        ],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 0, result.stderr
    run_meta = json.loads((artifacts_dir / "run.json").read_text(encoding="utf-8"))
    assert run_meta["counts"]["processed"] == 1
    assert run_meta["counts"]["succeeded"] == 1
    assert (
        json.loads(
            (artifacts_dir / "discovered_issues.json").read_text(encoding="utf-8")
        )[0]["id"]
        == "issue-shellcheck-1"
    )

    attempt_rows = [
        json.loads(line)
        for line in (artifacts_dir / "issue_attempts.jsonl")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip()
    ]
    assert attempt_rows[0]["status"] == "success"
    assert attempt_rows[0]["prUrl"] == "https://example.test/pr/1"
    assert (
        subprocess.check_output(
            ["git", "branch", "--show-current"], cwd=repo_dir, text=True
        ).strip()
        == "main"
    )


def test_run_loop_accepts_direct_landing_success(tmp_path):
    repo_dir = tmp_path / "repo"
    repo_dir.mkdir()
    (repo_dir / "temporal").mkdir()
    (repo_dir / "README.md").write_text("hello\n", encoding="utf-8")

    subprocess.run(["git", "init", "-b", "main"], cwd=repo_dir, check=True)
    subprocess.run(
        ["git", "config", "user.name", "Test User"], cwd=repo_dir, check=True
    )
    subprocess.run(
        ["git", "config", "user.email", "test@example.com"], cwd=repo_dir, check=True
    )
    subprocess.run(["git", "add", "README.md"], cwd=repo_dir, check=True)
    subprocess.run(["git", "commit", "-m", "init"], cwd=repo_dir, check=True)

    issues_file = tmp_path / "issues.json"
    issues_file.write_text(
        json.dumps(
            [
                {
                    "id": "issue-todo-1",
                    "priority": 2,
                    "type": "todo",
                    "title": "Fix todo issue",
                    "description": "desc",
                    "files": ["README.md"],
                    "context": "{}",
                }
            ]
        ),
        encoding="utf-8",
    )

    fakebin = tmp_path / "fakebin"
    fakebin.mkdir()
    write_executable(
        fakebin / "nc",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    write_executable(
        fakebin / "go",
        """#!/usr/bin/env bash
set -eu -o pipefail
workflow_id=""
log_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    run)
      shift
      ;;
    -workflow-id)
      workflow_id="$2"
      shift 2
      ;;
    -log-dir)
      log_dir="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "$log_dir"
cat >"${log_dir}/${workflow_id}_fake-run_plan.json" <<JSON
{"workflowId":"${workflow_id}","runId":"fake-run","steps":[]}
JSON
cat <<JSON
{
  "workflowId": "${workflow_id}",
  "runId": "fake-run",
  "async": false,
  "result": {
    "succeeded": true,
    "steps": [
      {"id":"validate","state":"success","result":{"exitCode":0}},
      {"id":"commit_pr","state":"success","result":{"exitCode":0}},
      {"id":"push_branch","state":"success","result":{"exitCode":0}},
      {"id":"create_pr","state":"success","result":{"outputs":{"landed_branch":"main"}}}
    ]
  }
}
JSON
""",
    )

    artifacts_dir = tmp_path / "artifacts"
    env = dict(os.environ)
    env["PATH"] = f"{fakebin}:{env['PATH']}"

    result = subprocess.run(
        [
            str(RUN_LOOP),
            "--repo-dir",
            str(repo_dir),
            "--run-id",
            "testrun-direct",
            "--artifacts-dir",
            str(artifacts_dir),
            "--issues-file",
            str(issues_file),
        ],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 0, result.stderr
    run_meta = json.loads((artifacts_dir / "run.json").read_text(encoding="utf-8"))
    assert run_meta["config"]["repo"]["landingMode"] == "direct"

    attempted_rows = [
        json.loads(line)
        for line in (repo_dir / ".agentic" / "attempted.jsonl")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip()
    ]
    assert attempted_rows[0]["status"] == "landed"
    assert attempted_rows[0]["branch"] == "main"
