#!/usr/bin/env python3
"""Reject missing/partial passes, traps, reboots and stopped hart/timer progress."""
import json
from pathlib import Path
import re
import sys


def check(log):
    log = log.replace("\\r", "").replace("\r", "")
    if log.count("NIHOS_NATIVE_BOOT backend=zig-sram rtos=none") != 1:
        raise ValueError("missing boot or unexpected reboot")
    if "NIHOS_NATIVE_FAIL" in log or "NIHOS_NATIVE_TRAP" in log:
        raise ValueError("native failure/trap")
    if "NIHOS_NATIVE_CRT_PASS bss=zero data=valid ecall=returned" not in log:
        raise ValueError("missing CRT/exception pass")
    pattern = (r"NIHOS_NATIVE_HEARTBEAT round=([0-9a-f]{8}) cpu0=([0-9a-f]{8}) "
               r"cpu1=([0-9a-f]{8}) ticks0=([0-9a-f]{8}) ticks1=([0-9a-f]{8})")
    samples = [tuple(int(value, 16) for value in match)
               for match in re.findall(pattern, log)]
    if len(samples) < 31 or samples[0][0] != 1 or samples[-1][0] < 300:
        raise ValueError("incomplete heartbeat sequence")
    for previous, current in zip(samples, samples[1:]):
        if any(value <= old for value, old in zip(current, previous)):
            raise ValueError("hart, timer, or round stopped progressing")
    if (log.count("NIHOS_NATIVE_SMP_PASS rounds=100 timers=both rtos=none") < 3 or
            "NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none" not in log):
        raise ValueError("missing continuous execution pass")
    pattern = (r"NIHOS_NATIVE_TASKS hart=([0-9a-f]{8}) work0=([0-9a-f]{8}) "
               r"work1=([0-9a-f]{8}) cap0=([0-9a-f]{8}) cap1=([0-9a-f]{8}) "
               r"switches=([0-9a-f]{8}) calls=([0-9a-f]{8}) reaped=([0-9a-f]{8}) "
               r"sleeps=([0-9a-f]{8}) elapsed=([0-9a-f]{8})")
    owners = [[], []]
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2:
            raise ValueError("invalid task owner")
        work0, work1, cap0, cap1, switches, calls, reaped, sleeps, elapsed = values
        if (min(work0, work1) == 0 or min(cap0, cap1) < 4 or switches < 8 or
                calls < 12 or reaped != 2 or sleeps != 2 or elapsed == 0):
            raise ValueError("incomplete task lifecycle/preemption")
        if owners[hart] and any(values[index] <= owners[hart][-1][index]
                                for index in (0, 1, 2, 3, 4, 8)):
            raise ValueError("worker or preemption stopped progressing")
        owners[hart].append(values)
    if any(len(records) != 3 for records in owners):
        raise ValueError("missing per-hart task checkpoints")
    names = ("sent", "received", "ipis", "delivered", "woken", "rejected",
             "from_idle", "entries", "returns", "pending_before_wfi", "timer_start", "timer_end", "queued")
    pattern = r"NIHOS_NATIVE_IPI hart=([0-9a-f]{8})" + "".join(
        " " + name + r"=([0-9a-f]{8})" for name in names)
    ipi_owners = {}
    for match in re.findall(pattern, log):
        hart, *values = [int(value, 16) for value in match]
        if hart >= 2 or hart in ipi_owners:
            raise ValueError("invalid/duplicate IPI owner")
        record = dict(zip(names, values))
        if (any(record[name] != 64 for name in ("sent", "received", "delivered", "woken")) or
                record["ipis"] < 64 or record["from_idle"] < 64 or
                record["returns"] < 64 or record["entries"] < record["returns"] or
                record["pending_before_wfi"] != 1 or
                record["rejected"] != 0 or record["queued"] != 0):
            raise ValueError("incomplete IPI delivery/idle wake")
        if record["timer_start"] != record["timer_end"]:
            raise ValueError("periodic timer used during IPI-only idle")
        ipi_owners[hart] = record
    if (set(ipi_owners) != {0, 1} or
            "NIHOS_NATIVE_IPI_IDLE_PASS exchanges=64 timer_fallback=none" not in log):
        raise ValueError("missing native IPI/idle evidence")
    return {"schema": 1, "backend": "native-sram", "evidence": "emulator",
            "rounds": samples[-1][0], "samples": len(samples),
            "cpu0_progress": samples[-1][1], "cpu1_progress": samples[-1][2],
            "cpu0_interrupts": samples[-1][3], "cpu1_interrupts": samples[-1][4],
            "tasks": [{"hart": hart, "progress": values[-1][:2],
                       "timer_captures": values[-1][2:4], "switches": values[-1][4],
                       "calls": values[-1][5], "reaped": values[-1][6],
                       "sleeps": values[-1][7], "elapsed_ticks": values[-1][8]}
                      for hart, values in enumerate(owners)],
            "ipi_idle": [{"hart": hart, **ipi_owners[hart]} for hart in (0, 1)]}


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: check-native-log.py LOG REPORT.json")
    try:
        report = check(Path(sys.argv[1]).read_text())
    except ValueError as error:
        raise SystemExit("Native smoke failed: " + str(error)) from error
    Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + "\n")
    print("Native smoke passed: 300 rounds, task lifecycle, and 64 IPI-only idle exchanges")


if __name__ == "__main__":
    main()
