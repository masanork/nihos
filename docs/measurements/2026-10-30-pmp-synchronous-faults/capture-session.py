#!/usr/bin/env python3
"""Back up the connected Tab5, write the PMP probe, capture serial, then restore.

This is a one-shot copy of the backup and restore path in
tools/qualify-storage-io.py. It does not retry a write. A failed restore stops.
"""
import contextlib
import fcntl
import re
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, "/private/tmp/nihos-pr76-completion/tools")

import esptool
import serial
from esptool.reset import HardReset
from native_serial import capture_serial_class, disconnected

REPO = Path("/private/tmp/nihos-pr76-completion")
CANDIDATE = REPO / "build/native-device-pmp-probe"
PORT = "/dev/cu.usbmodem101"
EXPECTED = {"chip": "ESP32-P4 (revision v1.3)", "mac": "e8:f6:0a:e2:e8:9c"}
OUT = Path("/private/tmp/nihos-pr76-sbe-matrix-physical-3")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    app = CANDIDATE / "nihos-native.bin"
    loader = Path("/private/tmp/nihos-pr76-rom-physical-1/bootloader.bin")
    table = Path("/private/tmp/nihos-pr76-rom-physical-1/partition-table.bin")
    for path in (app, loader, table):
        if not path.is_file():
            raise SystemExit("missing candidate: " + str(path))
    options = (CANDIDATE / "native_options.zig").read_text()
    if "pub const pmp_case: ?u32 = null;" not in options:
        raise SystemExit("Refusing anything except complete matrix")
    app_size = app.stat().st_size
    loader_size = loader.stat().st_size
    if not 0 < loader_size <= 0x6000 or not 0 < app_size < 0x100000:
        raise SystemExit("candidate exceeds the qualification layout")
    if OUT.exists():
        raise SystemExit("flash work directory already exists; refusing to reuse it")
    os.umask(0o077)
    OUT.mkdir(mode=0o700)
    for source, name in ((app, "nihos-native.bin"), (loader, "bootloader.bin"), (table, "partition-table.bin")):
        shutil.copy2(source, OUT / name)
    owners = subprocess.run(["lsof", "-t", PORT], capture_output=True, text=True, check=False)
    if owners.stdout.strip():
        raise SystemExit("Serial already in use: " + owners.stdout.strip())

    changed = False
    restored_ok = False
    outcome = "not-started"
    with capture_serial_class(serial.Serial)(PORT, 115200, timeout=0.2, exclusive=True) as port:
        aliases = {PORT, PORT.replace("/cu.", "/tty.")}
        owners = subprocess.run(["lsof", "-t", *sorted(aliases)], capture_output=True, text=True, check=False)
        foreign = {int(pid) for pid in owners.stdout.split()} - {os.getpid()}
        if foreign:
            raise SystemExit("Serial already held by another writer: " + str(sorted(foreign)))

        def reopen():
            owners = subprocess.run(["lsof", "-t", PORT], capture_output=True, text=True, check=False)
            if owners.stdout.strip():
                raise RuntimeError("Serial acquired by another owner: " + owners.stdout.strip())
            port.passive_open = False
            port.dtr = False
            port.rts = False
            port.open()

        def connect():
            deadline = time.monotonic() + 60
            while True:
                try:
                    if not port.is_open:
                        reopen()
                    port.baudrate = 115200
                    esp = esptool.detect_chip(port=port, baud=115200)
                    break
                except (serial.SerialException, OSError) as error:
                    if not disconnected(error) or time.monotonic() >= deadline:
                        raise
                    port.close()
                    time.sleep(0.2)
            identity = {"chip": esp.get_chip_description(), "mac": ":".join(f"{b:02x}" for b in esp.read_mac())}
            if identity != EXPECTED:
                raise RuntimeError("Device identity mismatch; refusing Flash access: " + str(identity))
            return esp, identity

        def command(name, arguments):
            esp, _identity = connect()
            print(name, flush=True)
            with (OUT / (name + ".log")).open("w") as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                esptool.main(["--chip", "esp32p4", "--baud", "460800", "--after", "no_reset", *arguments], esp=esp)

        _esp, identity = connect()
        (OUT / "device.json").write_text(
            '{"chip": "%s", "mac": "%s"}\n' % (identity["chip"], identity["mac"])
        )
        print("IDENTITY chip=%s mac=%s" % (identity["chip"], identity["mac"]), flush=True)
        backup = OUT / "flash-before.bin"
        backup.touch(mode=0o600)
        command("backup-before", ["read_flash", "0", "0x1000000", str(backup)])
        if digest(backup) != "d9411b6af948100f86e61b88fd8b6ab9e92f50f5ddbfddc78eecd34500c08f10":
            print("BASELINE_CHANGED preserving the current concurrent-work image byte for byte", flush=True)
        if backup.stat().st_size != 16 << 20:
            raise RuntimeError("Incomplete Flash backup")
        raw = backup.read_bytes()
        table_bytes = (OUT / "partition-table.bin").read_bytes()
        if raw[0x8000:0x8000 + len(table_bytes)] != table_bytes:
            raise RuntimeError("Partition table differs; no Flash written")
        print("BACKUP bytes=%d sha256=%s" % (len(raw), digest(backup)), flush=True)
        old_loader = OUT / "loader-before.bin"
        old_app = OUT / "app-before.bin"
        app_span = (app_size + 4095) & ~4095
        for path, data in (
            (old_loader, raw[0x2000:0x8000]),
            (old_app, raw[0x10000:0x10000 + app_span]),
        ):
            path.touch(mode=0o600)
            path.write_bytes(data)
        body_error = None
        try:
            changed = True  # A partial write must still be restored.
            print("WRITE probe", flush=True)
            command(
                "write-candidate",
                ["write_flash", "0x2000", str(OUT / "bootloader.bin"), "0x10000", str(OUT / "nihos-native.bin")],
            )
            command(
                "verify-candidate",
                [
                    "verify_flash",
                    "0x2000",
                    str(OUT / "bootloader.bin"),
                    "0x8000",
                    str(OUT / "partition-table.bin"),
                    "0x10000",
                    str(OUT / "nihos-native.bin"),
                ],
            )
            port.baudrate = 115200
            port.dtr = False
            port.reset_input_buffer()
            HardReset(port, uses_usb=True)()
            print("CAPTURE begin", flush=True)
            raw_log = bytearray()
            path = OUT / "probe.log"
            began = time.monotonic()
            while time.monotonic() - began < 15:
                raw_log.extend(port.read(max(1, port.in_waiting)))
                path.write_bytes(raw_log)
                if re.search(rb"NIHOS_NATIVE_PMP_OBSERVER [^\r\n]*\r\n", raw_log):
                    outcome = "observed"
                    break
                if b"NIHOS_NATIVE_PMP_PROBE_PASS cases=12 kernel=1\r\n" in raw_log:
                    outcome = "pass"
                    break
                if b"NIHOS_NATIVE_FAIL" in raw_log or b"NIHOS_NATIVE_TRAP" in raw_log:
                    outcome = "fail"
                    break
            else:
                outcome = "timeout"
            path.write_bytes(raw_log)
            print("CAPTURE %s bytes=%d" % (outcome, len(raw_log)), flush=True)
            if outcome == "pass":
                for repetition in (2, 3):
                    command("verify-candidate-" + str(repetition), ["verify_flash", "0x2000", str(OUT / "bootloader.bin"), "0x8000", str(OUT / "partition-table.bin"), "0x10000", str(OUT / "nihos-native.bin")])
                    port.baudrate = 115200
                    port.dtr = False
                    port.reset_input_buffer()
                    HardReset(port, uses_usb=True)()
                    again = bytearray()
                    began = time.monotonic()
                    while time.monotonic() - began < 15:
                        again.extend(port.read(max(1, port.in_waiting)))
                        if b"NIHOS_NATIVE_PMP_PROBE_PASS cases=12 kernel=1\r\n" in again:
                            break
                        if b"NIHOS_NATIVE_FAIL" in again:
                            outcome = "fail"
                            break
                    else:
                        outcome = "timeout"
                    (OUT / ("probe-" + str(repetition) + ".log")).write_bytes(again)
                    print("REPEAT %d %s bytes=%d" % (repetition, outcome, len(again)), flush=True)
                    if outcome != "pass":
                        break

        except Exception as error:
            body_error = error
            if outcome == "not-started":
                outcome = "write-failed"
            print("WRITE_ERROR %s: %s" % (type(error).__name__, error), flush=True)
        finally:
            if changed:
                print("RESTORE begin", flush=True)
                command("restore-before", ["write_flash", "0x2000", str(old_loader), "0x10000", str(old_app)])
                command("verify-restored-full-flash", ["verify_flash", "0", str(backup)])
                (OUT / "restored.json").write_text('{"verified": true, "sha256": "%s"}\n' % digest(backup))
                restored_ok = True
                print("RESTORE verified", flush=True)
                try:
                    port.baudrate = 115200
                    port.dtr = False
                    port.reset_input_buffer()
                    HardReset(port, uses_usb=True)()
                except Exception as error:
                    print("RESTORE_RESET %s: %s" % (type(error).__name__, error), flush=True)
    if not restored_ok:
        raise SystemExit(4)
    if body_error is not None and outcome != "pass":
        print("OUTCOME %s restored=1 error=%s" % (outcome, body_error), flush=True)
        return 2
    if not restored_ok:
        raise SystemExit("restore did not verify")
    print("OUTCOME %s restored=1" % outcome, flush=True)
    return 0 if outcome == "pass" else 2


if __name__ == "__main__":
    try:
        with open("/private/tmp/nihos-tab5-e8f60ae2e89c-write.lock", "a+b") as device_lease:
            fcntl.flock(device_lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            raise SystemExit(main())
    except SystemExit as stop:
        code = stop.code if isinstance(stop.code, int) else 1
        print("FLASH_EXIT %s" % code, flush=True)
        raise
    except Exception as error:
        print("FLASH_ERROR %s: %s" % (type(error).__name__, error), flush=True)
        raise SystemExit(1)
