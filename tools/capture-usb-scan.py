#!/usr/bin/env python3
"""Reset an already installed USB probe and capture its bounded scan to a log.

Run with ESP-IDF's Python environment (pyserial and esptool). Does not flash.
"""
import argparse
from pathlib import Path
import time

import serial
from esptool.reset import HardReset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    raw = bytearray()
    with serial.Serial(args.port, 115200, timeout=0.2, exclusive=True) as console:
        console.dtr = False
        console.reset_input_buffer()
        HardReset(console, uses_usb=True)()
        deadline = time.monotonic() + 50
        with args.log.open("wb") as output:
            while time.monotonic() < deadline:
                chunk = console.read(max(1, console.in_waiting))
                if chunk:
                    raw.extend(chunk)
                    output.write(chunk)
                    output.flush()
                if b"NIHOS_USB_SCAN_END" in raw:
                    break
    print(raw.decode("utf-8", errors="replace"), end="")
    if b"NIHOS_USB_SCAN_BEGIN" not in raw or b"NIHOS_USB_SCAN_END" not in raw:
        raise SystemExit("Incomplete USB scan; inspect the saved log")


if __name__ == "__main__":
    main()
