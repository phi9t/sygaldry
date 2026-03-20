#!/usr/bin/env python3
"""
tools/agentic/temporal_probe.py — Lightweight connectivity probe for Temporal.
"""

import socket
import time


class TemporalProbe:
    def __init__(self, address: str):
        self.address = address

    def is_reachable(self, timeout: float = 3.0) -> bool:
        """
        Attempt a TCP connection to the Temporal address to check reachability.
        """
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

    def wait_until_ready(self, timeout_secs: float = 60, poll_interval: float = 5) -> bool:
        """
        Poll is_reachable() until it returns True or timeout is reached.
        """
        deadline = time.time() + timeout_secs
        while time.time() < deadline:
            if self.is_reachable():
                return True
            time.sleep(poll_interval)
        return self.is_reachable()


if __name__ == "__main__":
    import sys

    addr = sys.argv[1] if len(sys.argv) > 1 else "localhost:7233"
    probe = TemporalProbe(addr)
    if probe.is_reachable():
        print(f"Temporal at {addr} is REACHABLE")
    else:
        print(f"Temporal at {addr} is UNREACHABLE")
        sys.exit(1)
