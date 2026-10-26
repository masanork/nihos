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



def main():
    import serial
    from esptool.reset import HardReset

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("output", type=Path)
    parser.add_argument("image_audit", type=Path)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--jpki", action="store_true", help="require PIN-free JPKI serial and unchanged retries")
    parser.add_argument("--card", action="store_true", help="require PIN-free Input Support and touch readiness")
    parser.add_argument("--touch", action="store_true", help="require native display and four-quadrant touch feedback, with no USB card operations")
    parser.add_argument("--card-read", action="store_true", help="one local explicit Input Support read; never records PIN/attributes")
    parser.add_argument("--keypad", action="store_true", help="require count-only keypad erase/cancel/confirm and rendered states, without card communication")
    parser.add_argument("--install", type=Path, help="explicitly install a native build directory before qualification")
    args = parser.parse_args()
    if sum((args.card, args.jpki, args.touch, args.keypad, args.card_read)) > 1:
        parser.error("--card, --jpki, --touch and --keypad are separate qualification modes")
    if not 1 <= args.runs <= 10:
        parser.error("runs must be 1..10")
    if args.card_read and args.runs != 1:
        parser.error("authenticated reads require --runs 1; no automatic repeat sessions")
    args.output.mkdir(parents=True, exist_ok=True)
    checker = Path(__file__).with_name("check-native-log.py")
    completion = args.output / "exclusive-complete.json"
    completion.unlink(missing_ok=True)
    failures = []
    installation = None
    if args.install:
        try:
            installation, args.image_audit = snapshot_install(args.install, args.image_audit, args.output)
        except (ValueError, FileExistsError) as error:
            parser.error(str(error))
    with serial.Serial(args.port, 115200, timeout=0.15, exclusive=True) as console:
        print("Exclusive serial lease acquired for the full qualification", flush=True)
        if installation:
            tool(console, args.output / "flash.log", "write_flash", installation)
            tool(console, args.output / "verify-before.log", "verify_flash", installation)
        for run in range(1, args.runs + 1):
            raw = bytearray()
            completed = None
            announced_touch = False
            announced_preview = False
            raw_path = args.output / f"boot-{run}.raw.log"
            log_path = args.output / f"boot-{run}.log"
            report_path = args.output / f"boot-{run}.json"
            report_path.unlink(missing_ok=True)
            with raw_path.open("wb") as output:
                console.dtr = False
                console.reset_input_buffer()
                HardReset(console, uses_usb=True)()
                deadline = time.monotonic() + (900 if args.card_read else 180 if args.keypad else 160 if args.touch else 45)
                while time.monotonic() < deadline:
                    chunk = console.read(max(1, console.in_waiting))
                    if chunk:
                        raw.extend(chunk)
                        output.write(chunk)
                        output.flush()
                    start_marker = b"NIHOS_NATIVE_CARD_READ_READY " if args.card_read else b"NIHOS_NATIVE_KEYPAD_START " if args.keypad else b"NIHOS_NATIVE_TOUCH_START "
                    if args.card_read and not announced_preview and b"NIHOS_NATIVE_CARD_READ_START_TOUCH " in raw:
                        print("Synthetic overview ready; tap and release once to open the local PIN screen", flush=True)
                        announced_preview = True
                    if (args.touch or args.keypad or args.card_read) and not announced_touch and start_marker in raw:
                        print("Input Support PIN screen ready; one local submission only" if args.card_read else "Keypad demonstration active; no card/PIN transmission" if args.keypad else "Touch input active: tap the four quadrants and lift your finger; no PIN input", flush=True)
                        announced_touch = True
                    marker = b"NIHOS_NATIVE_CARD_READ_DONE " if args.card_read else b"NIHOS_NATIVE_KEYPAD_CHECK " if args.keypad else b"NIHOS_NATIVE_TOUCH_CHECK " if args.touch else b"NIHOS_NATIVE_CARD_CHECK " if args.card else b"NIHOS_NATIVE_FP_PASS"
                    if (marker in raw or b"NIHOS_NATIVE_FAIL" in raw) and completed is None:
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
            command = ([sys.executable, str(checker.with_name("check-native-card-read-log.py")), str(log_path), str(args.image_audit), str(report_path)] if args.card_read else
                       [sys.executable, str(checker.with_name("check-native-keypad-log.py")), str(log_path), str(args.image_audit), str(report_path)] if args.keypad else
                       [sys.executable, str(checker.with_name("check-native-touch-log.py")), str(log_path), str(args.image_audit), str(report_path)] if args.touch else
                       [sys.executable, str(checker), str(log_path), str(report_path), "integer", "32M", str(args.image_audit), "physical-device", "usb,card" if args.card else "usb,jpki" if args.jpki else "usb"])
            checked = subprocess.run(command)
            if checked.returncode:
                failures.append(run)
            print(f"Native USB boot {run}: {'failed' if checked.returncode else 'passed'} ({log_path})", flush=True)

        if installation:
            tool(console, args.output / "verify-after.log", "verify_flash", installation)
        if failures:
            raise SystemExit(f"Qualification failed on boots {failures}; evidence retained, no completion marker")
        completion.write_text(json.dumps({
            "runs": args.runs, "jpki": args.jpki, "card": args.card, "touch": args.touch, "keypad": args.keypad, "card_read": args.card_read, "exclusive_descriptor_held": True,
            "installed": bool(installation), "postverify": bool(installation),
        }, indent=2) + "\n")
        print("Qualification complete; releasing serial lease", flush=True)



def snapshot_install(build, audit_path, output):
    audit_bytes = audit_path.read_bytes()
    audit = json.loads(audit_bytes)
    if audit.get("rtos_linked") is not False or audit.get("memory", {}).get("profile") != "device":
        raise ValueError("installation requires an audited native device image")
    retained = output / "installed"
    retained.mkdir()  # A fresh output preserves previous evidence on rerun.
    paths = {
        "0x2000": build / "loader/bootloader/bootloader.bin",
        "0x8000": build / "loader/partition_table/partition-table.bin",
        "0x10000": build / "nihos-native.bin",
    }
    installation = {}
    for address, source in paths.items():
        destination = retained / source.name
        shutil.copy2(source, destination)
        installation[address] = destination
    if hashlib.sha256(installation["0x10000"].read_bytes()).hexdigest() != audit.get("image_sha256"):
        raise ValueError("retained installation image differs from the supplied audit")
    frozen_audit = retained / "image-audit.json"
    frozen_audit.write_bytes(audit_bytes)
    return installation, frozen_audit


def tool(console, log, action, paths):
    import esptool

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
