from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path


class WorkerManager:
    """Start, stop, restart, and health-check the Temporal worker subprocess."""

    def __init__(self, temporal_dir: str, log_file: str) -> None:
        self.temporal_dir = Path(temporal_dir)
        self.log_file = Path(log_file)
        self._proc: subprocess.Popen[bytes] | None = None

    def start(self) -> subprocess.Popen[bytes]:
        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        log_handle = self.log_file.open("ab")
        self._proc = subprocess.Popen(
            ["go", "run", "./cmd/worker"],
            cwd=self.temporal_dir,
            stdout=log_handle,
            stderr=log_handle,
        )
        return self._proc

    def stop(self, timeout: float = 10.0) -> None:
        proc = self._proc
        if proc is None:
            return
        try:
            proc.terminate()
        except OSError:
            return
        deadline = time.time() + timeout
        while time.time() < deadline:
            if proc.poll() is not None:
                self._proc = None
                return
            time.sleep(0.1)
        try:
            proc.kill()
        except OSError:
            pass
        proc.wait()
        self._proc = None

    def restart(self) -> subprocess.Popen[bytes]:
        self.stop()
        return self.start()

    def is_alive(self) -> bool:
        proc = self._proc
        if proc is None:
            return False
        return proc.poll() is None


def worker_info_from_pid_file(pid_file: Path) -> tuple[int | None, bool]:
    """Read a PID file and check whether the referenced process is alive."""
    if not pid_file.exists():
        return None, False
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None, False
    try:
        os.kill(pid, 0)
    except OSError:
        return pid, False
    return pid, True
