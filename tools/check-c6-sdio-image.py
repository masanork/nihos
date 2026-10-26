#!/usr/bin/env python3
"""Apply the native SRAM/ROM/image audit to the standalone CPU0 C6 fixture."""
import importlib.util
import json
from pathlib import Path
import sys


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: check-c6-sdio-image.py ELF BIN|--elf-only REPORT.json")
    path = Path(__file__).with_name("check-native-image.py")
    spec = importlib.util.spec_from_file_location("native_image_audit", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    image = None if sys.argv[2] == "--elf-only" else Path(sys.argv[2]).read_bytes()
    report = module.audit(Path(sys.argv[1]).read_bytes(), image, "integer", required_functions=(
        "nih_c6_main", "nih_c6_exception", "nih_c6_reset", "nih_c6_pads_init", "nih_c6_fourbit_pins",
    ))
    report.update(backend="native-c6-boot-fixture", intended_cpu_count=1, execution_qualified=False)
    report["heap"].update(owner_count=0, used=False)
    Path(sys.argv[3]).write_text(json.dumps(report, indent=2) + "\n")
    print("C6 fixture audit passed: SRAM/ROM only, no RTOS/FP; execution unqualified")


if __name__ == "__main__":
    main()
