#!/usr/bin/env python3
"""Exercise bounded UART failure paths against one unchanged native image."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def record(log, marker):
    rows = re.findall(r"^" + marker + r" (.+)$", log, re.M)
    if len(rows) != 1:
        raise RuntimeError(f"expected one {marker} record")
    return {key: int(value, 16) for key, value in
            (field.split("=", 1) for field in rows[0].split())}


def main():
    emulator, directory = sys.argv[1:]
    out = Path(directory).resolve()
    firmware = out / "nihos-native-flash.bin"
    elf = out / "nihos-native-image.elf"
    firmware_hash = hashlib.sha256(firmware.read_bytes()).hexdigest()
    elf_hash = hashlib.sha256(elf.read_bytes()).hexdigest()
    # name, bytes injected, fixture status, uart status, received, frames,
    # unsupported bytes processed, total accepted drawing imports.
    cases = [
        ("noinput", "", 42, 2, 0, 0, 0, 11),
        ("partial", "0", 42, 2, 1, 1, 0, 13),
        ("early-quit", "q", 44, 1, 1, 0, 0, 11),
        ("overflow", "x" * 17, 43, 0, 17, 0, 16, 11),
        ("wrong-order", "1", 44, 0, 1, 0, 0, 11),
        ("extra-frame", "0x100q", 44, 0, 5, 3, 1, 17),
    ]
    results = []
    for name, injected, code, status, received, frames, rejected, calls in cases:
        args = [emulator, "--chip", "esp32p4", "--firmware", str(firmware),
                "--elf", str(elf), "--psram-size", "4M", "--timeout", "60s",
                "--exit-on", "NIHOS_NATIVE_FAIL"]
        if injected:
            args += ["--inject", injected, "--inject-on", "NIHOS_WAMR_UART_READY"]
        result = subprocess.run(args, capture_output=True, text=True, timeout=65)
        log = result.stdout
        (out / f"emulator-{name}.log").write_text(log)
        (out / f"emulator-{name}-stderr.log").write_text(result.stderr)
        if result.returncode != 0:
            raise RuntimeError(f"{name}: emulator exit {result.returncode}")
        if len(re.findall(r"^NIHOS_WAMR_UART_READY$", log, re.M)) != 1:
            raise RuntimeError(f"{name}: UART ready marker differs")
        wamr = record(log, "NIHOS_NATIVE_WAMR")
        uart = record(log, "NIHOS_NATIVE_WAMR_UART")
        owner = record(log, "NIHOS_NATIVE_WAMR_OWNER")
        surface = record(log, "NIHOS_NATIVE_WAMR_SURFACE")
        if (wamr["status"] != code or wamr["calls"] != calls or
                wamr["recovered"] != 1 or wamr["cycle_recovered"] != 1 or
                owner["released"] != 1 or owner["checks"] != 15 or
                surface["checks"] != 95):
            raise RuntimeError(f"{name}: failure/cleanup mismatch: {wamr} {owner} {surface}")
        expected = {"status": status, "bytes": received, "frames": frames, "rejected": rejected}
        if uart != expected:
            raise RuntimeError(f"{name}: UART mismatch: {uart}, expected {expected}")
        if "NIHOS_NATIVE_FAIL WAMR fixture" not in log or "NIHOS_NATIVE_FP_PASS" in log:
            raise RuntimeError(f"{name}: expected diagnostic failure before normal completion")
        if hashlib.sha256(firmware.read_bytes()).hexdigest() != firmware_hash:
            raise RuntimeError("firmware bytes changed during matrix")
        if hashlib.sha256(elf.read_bytes()).hexdigest() != elf_hash:
            raise RuntimeError("ELF bytes changed during matrix")
        results.append({"case": name, "injected_ascii": injected, "fixture_status": code,
                        "uart": uart, "calls": calls, "owners_released": 1,
                        "arenas_recovered": 1, "surface_detached_and_guards": 1})
        print(f"UART {name}: expected status {code}, {frames} frames, complete cleanup", flush=True)
    (out / "uart-matrix.json").write_text(json.dumps({
        "evidence": "native-emulator-uart-negative-matrix",
        "firmware_sha256": firmware_hash, "elf_sha256": elf_hash, "cases": results,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
