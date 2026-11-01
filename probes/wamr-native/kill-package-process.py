#!/usr/bin/env python3
"""Kill only our own journal-writer child at a validated update checkpoint."""
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path


def main():
    executable, trust, counter, package, status_path = sys.argv[1:6]
    phase = sys.argv[6] if len(sys.argv) == 7 else "interrupt"
    syncs = {"cut-clear": 1, "cut-payload": 1, "cut-record": 2, "cut-committed": 3}
    if phase != "interrupt" and phase not in syncs:
        raise ValueError("unknown checkpoint phase")
    child = subprocess.Popen(
        [executable, phase, trust, counter, package],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.monotonic() + 10
        output = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while b"\n" not in output:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise RuntimeError("writer did not reach update checkpoint")
                chunk = os.read(child.stdout.fileno(), 4096)
                if not chunk:
                    raise RuntimeError("writer exited before update checkpoint")
                output.extend(chunk)
                if len(output) > 4096:
                    raise RuntimeError("unexpected writer output size")
        if phase == "interrupt":
            prefix = rb"NIHOS_BOOT_PROCESS phase=interrupt trust_epoch=1 sequence=1 package_syncs=2 await_sigkill=1"
        else:
            prefix = (re.escape(f"NIHOS_PACKAGE_CUT phase={phase} package_syncs={syncs[phase]}".encode())
                      + rb" partial_bytes=" + (rb"[1-9][0-9]*" if phase in ("cut-payload", "cut-record") else rb"0"))
        expected = prefix + rb" pid=" + str(child.pid).encode("ascii") + rb"\n"
        if not re.fullmatch(expected, output):
            raise RuntimeError(f"writer checkpoint differs: {output!r}")
        child.kill()
        result = child.wait(timeout=5)
        if result != -signal.SIGKILL:
            raise RuntimeError(f"expected SIGKILL termination, got {result}")
        sys.stdout.buffer.write(output)
        Path(status_path).write_text(
            f"{phase} pid={child.pid} signal=SIGKILL returncode={result}\n"
        )
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        child.stdout.close()


if __name__ == "__main__":
    main()
