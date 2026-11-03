#!/usr/bin/env python3
"""Compare two prebuilt Rust test binaries on the same pinned MeOS workload."""

import argparse
import hashlib
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

MILESTONE = re.compile(r"Shooter first ship: (\d+) steps, ([0-9.]+)(ns|µs|ms|s)")
UNITS = {"ns": 1e-9, "µs": 1e-6, "ms": 1e-3, "s": 1.0}


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def run(binary: Path, env: dict[str, str]) -> tuple[int, float]:
    result = subprocess.run(
        [str(binary), "experimental_meos_shooter_arrow_moves_ship", "--ignored", "--nocapture"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    matches = MILESTONE.findall(result.stdout)
    if result.returncode or len(matches) != 1 or "test result: ok. 1 passed" not in result.stdout:
        raise RuntimeError(f"benchmark failed for {binary}:\n{result.stdout}")
    steps, value, unit = matches[0]
    return int(steps), float(value) * UNITS[unit]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, help="prebuilt baseline Rust test binary")
    parser.add_argument("experiment", type=Path, help="prebuilt candidate Rust test binary")
    parser.add_argument("app", type=Path, help="pinned MeOS m5os.bin")
    parser.add_argument("rom", type=Path, help="pinned ESP32-P4 ROM ELF")
    parser.add_argument("--pairs", type=int, default=6, help="alternating pairs, 1–20 (default: 6)")
    args = parser.parse_args()
    if not 1 <= args.pairs <= 20:
        parser.error("--pairs must be between 1 and 20")
    files = {name: getattr(args, name).resolve(strict=True) for name in ("baseline", "experiment", "app", "rom")}
    for name, path in files.items():
        print(f"{name}: {path} sha256={digest(path)}", flush=True)
    env = os.environ.copy()
    env["NIHOS_EMU_ESP_APP"] = str(files["app"])
    env["NIHOS_EMU_ROM_ELF"] = str(files["rom"])
    samples: dict[str, list[float]] = {"baseline": [], "experiment": []}
    expected_steps = None
    for pair in range(args.pairs):
        order = ("baseline", "experiment") if pair % 2 == 0 else ("experiment", "baseline")
        for name in order:
            steps, seconds = run(files[name], env)
            if expected_steps is None:
                expected_steps = steps
            if steps != expected_steps:
                raise RuntimeError(f"instruction milestone changed: {steps} != {expected_steps}")
            samples[name].append(seconds)
            print(f"pair {pair + 1} {name}: {steps} steps, {seconds:.6f} s", flush=True)
    for name, values in samples.items():
        print(f"{name}: median {statistics.median(values):.6f} s; range {min(values):.6f}–{max(values):.6f} s")
    print("Host contention, GUI responsiveness and physical timing are not controlled by this benchmark.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
