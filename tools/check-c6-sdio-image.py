#!/usr/bin/env python3
"""Apply the native SRAM/ROM/image audit to the standalone CPU0 C6 fixture."""
import importlib.util
import json
from pathlib import Path
import sys


def main():
    if len(sys.argv) not in (4, 5):
        raise SystemExit("usage: check-c6-sdio-image.py ELF BIN|--elf-only REPORT.json [at|hosted]")
    protocol = sys.argv[4] if len(sys.argv) == 5 else 'at'
    if protocol not in ('at', 'hosted'):
        raise SystemExit('unknown C6 protocol')
    path = Path(__file__).with_name("check-c6-sram-boundary.py")
    spec = importlib.util.spec_from_file_location("native_image_audit", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    image = None if sys.argv[2] == "--elf-only" else Path(sys.argv[2]).read_bytes()
    required = (
        "nih_c6_main", "nih_c6_exception", "nih_c6_reset", "nih_c6_pads_init", "nih_c6_fourbit_pins",
    )
    if protocol == 'hosted':
        required += ('nih_c6_power_enable', 'c6_probe.exerciseHosted')
    elf = Path(sys.argv[1]).read_bytes()
    report = module.audit(elf, image, "integer", required_functions=required)
    report.update(backend="native-c6-boot-fixture", protocol=protocol, intended_cpu_count=1, execution_qualified=False)
    report["heap"].update(owner_count=0, used=False)
    Path(sys.argv[3]).write_text(json.dumps(report, indent=2) + "\n")
    print("C6 fixture audit passed: SRAM/ROM only, no RTOS/FP; execution unqualified")


if __name__ == "__main__":
    main()
