#!/usr/bin/env python3
"""Reject damaged committed payloads, then undo damage and recover exact bytes."""
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path


def main():
    out = Path(sys.argv[1]).resolve()
    committed = (out / "cut-committed.bin").read_bytes()
    baseline = (out / "package-sequence1.bin").read_bytes()
    trust = (out / "trust.bin").read_bytes()
    counter = (out / "counter.bin").read_bytes()
    stride = 512 + 144
    payload_length = struct.unpack_from("<I", committed, stride + 16)[0]
    assert len(committed) == 2 * stride and len(baseline) == len(committed)
    assert committed[stride:stride + 8] == b"NIHPKG01"
    assert struct.unpack_from("<Q", committed, stride + 24)[0] == 2
    assert struct.unpack_from("<Q", baseline, 24)[0] == 1
    assert struct.unpack_from("<I", baseline, 16)[0] == payload_length
    results = []
    pids = set()
    with (out / "corruption-controls.log").open("w") as log:
        for name in ("corrupt-payload", "substitute-old"):
            damaged = bytearray(committed)
            if name == "corrupt-payload":
                damaged[stride + 144] ^= 1
            else:
                damaged[stride:stride + payload_length] = baseline[:payload_length]
            assert damaged != committed
            assert damaged[:stride] == committed[:stride]
            assert damaged[stride + 512:] == committed[stride + 512:]
            media = out / f"{name}.bin"
            media.write_bytes(damaged)
            rejection = subprocess.run(
                [str(out / "package-process"), "reject-corrupt", str(out / "trust.bin"),
                 str(out / "counter.bin"), str(media)],
                capture_output=True, text=True, timeout=10, check=True,
            )
            log.write(rejection.stderr)
            fields = dict(x.split("=", 1) for x in rejection.stderr.split()[1:])
            assert fields["boot_rejected"] == "ActivePackageInvalid"
            assert fields["install_rejected"] == "ActivePackageInvalid"
            assert fields["writes"] == "0"
            assert media.read_bytes() == damaged
            # Reverse only the changed package range; preserve both records.
            restored = bytearray(damaged)
            restored[stride:stride + payload_length] = committed[stride:stride + payload_length]
            assert restored == committed
            restored_path = out / f"{name}-restored.bin"
            restored_path.write_bytes(restored)
            recovery = subprocess.run(
                [str(out / "package-process"), "recover-new", str(out / "trust.bin"),
                 str(out / "counter.bin"), str(restored_path)],
                capture_output=True, text=True, timeout=10, check=True,
            )
            log.write(recovery.stderr)
            ready = dict(x.split("=", 1) for x in recovery.stderr.split()[1:])
            assert ready["sequence"] == "2"
            for pid in (fields["pid"], ready["pid"]):
                assert pid not in pids
                pids.add(pid)
            assert (out / "trust.bin").read_bytes() == trust
            assert (out / "counter.bin").read_bytes() == counter
            assert restored_path.read_bytes() == committed
            results.append({"case": name, "rejected": "ActivePackageInvalid",
                            "rejection_pid": int(fields["pid"]),
                            "restoration_pid": int(ready["pid"]),
                            "restored_sequence": 2, "media": media.name,
                            "sha256": hashlib.sha256(damaged).hexdigest(),
                            "restored_media": restored_path.name,
                            "restored_sha256": hashlib.sha256(restored).hexdigest()})
    (out / "corruption-controls.json").write_text(json.dumps({
        "evidence": "host-process-committed-payload-corruption", "cases": results,
    }, indent=2) + "\n")
    print("committed corruption controls: 2 rejections, 2 restored recoveries, no fallback")


if __name__ == "__main__":
    main()
