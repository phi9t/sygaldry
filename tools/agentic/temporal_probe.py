from __future__ import annotations

import socket
import time


class TemporalProbe:
    """Check whether the Temporal server is reachable."""

    def __init__(self, address: str, namespace: str) -> None:
        self.address = address
        self.namespace = namespace

    def is_reachable(self, timeout: float = 5.0) -> bool:
        host, sep, port_text = self.address.partition(":")
        if not sep:
            host = self.address
            port_text = "7233"
        try:
            port = int(port_text)
        except ValueError:
            return False
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return True
        except OSError:
            return False

    def wait_until_ready(self, max_wait: float = 60.0) -> bool:
        deadline = time.time() + max_wait
        while time.time() < deadline:
            if self.is_reachable():
                return True
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            time.sleep(min(2.0, remaining))
        return False
