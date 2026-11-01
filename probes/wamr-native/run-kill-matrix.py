#!/usr/bin/env python3
"""Four host-file cut points, each recovered in a fresh process."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from shutil import copyfile


def main():
    out = Path(sys.argv[1]).resolve()
    exe = out / "package-process"
    helper = Path(__file__).with_name("kill-package-process.py")
    results = []
    pids = set()
    original_trust = (out / "trust.bin").read_bytes()
    original_counter = (out / "counter.bin").read_bytes()
    with (out / "kill-matrix.log").open("w") as log:
        for point, sequence in (("clear", 1), ("payload", 1), ("record", 1), ("committed", 2)):
            phase = f"cut-{point}"
            media = out / f"{phase}.bin"
            status = out / f"{phase}-status.txt"
            copyfile(out / "package-sequence1.bin", media)
            killed = subprocess.run(
                [sys.executable, str(helper), str(exe), str(out / "trust.bin"),
                 str(out / "counter.bin"), str(media), str(status), phase],
                capture_output=True, text=True, timeout=20, check=True,
            )
            log.write(killed.stdout)
            recovery = subprocess.run(
                [str(exe), "recover-old" if sequence == 1 else "recover-new",
                 str(out / "trust.bin"), str(out / "counter.bin"), str(media)],
                capture_output=True, text=True, timeout=10, check=True,
            )
            log.write(recovery.stderr)
            checkpoint = dict(x.split("=", 1) for x in killed.stdout.split()[1:])
            recovered = dict(x.split("=", 1) for x in recovery.stderr.split()[1:])
            termination = dict(x.split("=", 1) for x in status.read_text().split()[1:])
            assert termination["signal"] == "SIGKILL" and termination["returncode"] == "-9"
            assert termination["pid"] == checkpoint["pid"]
            assert recovered["sequence"] == str(sequence)
            for pid in (checkpoint["pid"], recovered["pid"]):
                assert pid not in pids
                pids.add(pid)
            assert (out / "trust.bin").read_bytes() == original_trust
            assert (out / "counter.bin").read_bytes() == original_counter
            results.append({"phase": phase, "sequence": sequence,
                            "partial_bytes": int(checkpoint["partial_bytes"]),
                            "package_syncs": int(checkpoint["package_syncs"]),
                            "writer_pid": int(checkpoint["pid"]),
                            "recovery_pid": int(recovered["pid"]),
                            "media": media.name,
                            "sha256": hashlib.sha256(media.read_bytes()).hexdigest()})
    (out / "kill-matrix.json").write_text(json.dumps({"evidence": "host-process-sigkill",
        "cases": results}, indent=2) + "\n")
    print("package SIGKILL matrix: 4 cuts, 8 distinct processes, exact package recovery")


if __name__ == "__main__":
    main()
