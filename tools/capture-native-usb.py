#!/usr/bin/env python3
"""Qualify native USB/JPKI under one serial lease; --install explicitly flashes."""
import argparse
import contextlib
import hashlib
import json
import shutil
from pathlib import Path
import subprocess
import sys
import time

import serial
import esptool
from esptool.reset import HardReset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("output", type=Path)
    parser.add_argument("image_audit", type=Path)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--jpki", action="store_true", help="require PIN-free JPKI serial and unchanged retries")
    parser.add_argument("--install", type=Path, help="explicitly install a native build directory before qualification")
    args = parser.parse_args()
    if not 1 <= args.runs <= 10:
        parser.error("runs must be 1..10")
    args.output.mkdir(parents=True, exist_ok=True)
    checker = Path(__file__).with_name("check-native-log.py")
    installation = None
    if args.install:
        audit = json.loads(args.image_audit.read_text())
        paths = {
            "0x2000": args.install / "loader/bootloader/bootloader.bin",
            "0x8000": args.install / "loader/partition_table/partition-table.bin",
            "0x10000": args.install / "nihos-native.bin",
        }
        if audit.get("rtos_linked") is not False or audit.get("memory", {}).get("profile") != "device":
            parser.error("installation requires an audited native device image")
        if hashlib.sha256(paths["0x10000"].read_bytes()).hexdigest() != audit.get("image_sha256"):
            parser.error("installation image differs from the supplied audit")
        retained = args.output / "installed"
        retained.mkdir(exist_ok=True)
        installation = {}
        for address, source in paths.items():
            destination = retained / source.name
            shutil.copy2(source, destination)
            installation[address] = destination
        shutil.copy2(args.image_audit, retained / "image-audit.json")
    with serial.Serial(args.port, 115200, timeout=0.15, exclusive=True) as console:
        print("Exclusive serial lease acquired for the full qualification", flush=True)
        if installation:
            tool(console, args.output / "flash.log", "write_flash", installation)
            tool(console, args.output / "verify-before.log", "verify_flash", installation)
        for run in range(1, args.runs + 1):
            raw = bytearray()
            completed = None
            raw_path = args.output / f"boot-{run}.raw.log"
            log_path = args.output / f"boot-{run}.log"
            report_path = args.output / f"boot-{run}.json"
            report_path.unlink(missing_ok=True)
            with raw_path.open("wb") as output:
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
                            "integer", "32M", str(args.image_audit), "physical-device", "usb,jpki" if args.jpki else "usb"], check=True)
            print(f"Native USB boot {run}: passed ({log_path})", flush=True)

        if installation:
            tool(console, args.output / "verify-after.log", "verify_flash", installation)
        (args.output / "exclusive-complete.json").write_text(json.dumps({
            "runs": args.runs, "jpki": args.jpki, "exclusive_descriptor_held": True,
            "installed": bool(installation), "postverify": bool(installation),
        }, indent=2) + "\n")
        print("Qualification complete; releasing serial lease", flush=True)


def tool(console, log, action, paths):
    with log.open("w") as output, contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        device = esptool.detect_chip(port=console, baud=115200)
        arguments = ["--chip", "esp32p4", "--baud", "460800", "--after", "hard_reset", action]
        if action == "write_flash":
            arguments += ["--flash_mode", "dio", "--flash_size", "16MB", "--flash_freq", "80m"]
        for address, path in paths.items():
            arguments += [address, str(path)]
        esptool.main(arguments, esp=device)
    console.baudrate = 115200


if __name__ == "__main__":
    main()
