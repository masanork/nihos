#!/usr/bin/env python3
"""Reset and qualify an already installed native USB probe; never flashes."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

import serial
from esptool.reset import HardReset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("output", type=Path)
    parser.add_argument("image_audit", type=Path)
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.runs <= 10:
        parser.error("runs must be 1..10")
    args.output.mkdir(parents=True, exist_ok=True)
    checker = Path(__file__).with_name("check-native-log.py")
    for run in range(1, args.runs + 1):
        raw = bytearray()
        completed = None
        raw_path = args.output / f"boot-{run}.raw.log"
        log_path = args.output / f"boot-{run}.log"
        report_path = args.output / f"boot-{run}.json"
        report_path.unlink(missing_ok=True)
        with serial.Serial(args.port, 115200, timeout=0.15, exclusive=True) as console, raw_path.open("wb") as output:
            console.dtr = False
            console.reset_input_buffer()
            HardReset(console, uses_usb=True)()
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                chunk = console.read(max(1, console.in_waiting))
                if chunk:
                    raw.extend(chunk)
                    output.write(chunk)
                    output.flush()
                if (b"NIHOS_NATIVE_FP_PASS" in raw or b"NIHOS_NATIVE_FAIL" in raw) and completed is None:
                    completed = time.monotonic()
                if completed is not None and time.monotonic() - completed >= 1:
                    break
        # USB UART may emit a fragment from the previous boot during RTS reset.
        # Retain that fragment in .raw.log; validate only from the ROM banner.
        start = raw.find(b"ESP-ROM:esp32p4")
        if start < 0:
            log_path.write_bytes(raw)
            raise SystemExit("Missing ROM boot banner; inspect " + str(raw_path))
        log_path.write_bytes(raw[start:])
        subprocess.run([sys.executable, str(checker), str(log_path), str(report_path),
                        "integer", "32M", str(args.image_audit), "physical-device", "usb"], check=True)
        print(f"Native USB boot {run}: passed ({log_path})", flush=True)


if __name__ == "__main__":
    main()
