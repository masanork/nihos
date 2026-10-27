#!/usr/bin/env python3
"""Write a receipt only after all selected backends and comparisons pass."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys


def elf_u32(path, symbol):
    obj = path.read_bytes()
    assert obj[:6] == b"\x7fELF\x01\x01", "expected little-endian ELF32"
    shoff = struct.unpack_from("<I", obj, 32)[0]
    size, count = struct.unpack_from("<HH", obj, 46)
    sections = [struct.unpack_from("<10I", obj, shoff + i * size) for i in range(count)]
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        strings = sections[section[6]]
        names = obj[strings[4]:strings[4] + strings[5]]
        for at in range(section[4], section[4] + section[5], section[9]):
            name, value, length, _, _, index = struct.unpack_from("<IIIBBH", obj, at)
            if names[name:].split(b"\0", 1)[0] == symbol.encode():
                assert length == 4 and 0 < index < len(sections)
                return struct.unpack_from("<I", obj, sections[index][4] + value)[0]
    raise ValueError("missing ELF symbol: " + symbol)


out = Path(sys.argv[1])
kernel = sys.argv[3] == "1"
inputs = sorted(Path("probes/graphics").iterdir()) + [
    Path("tools/run-graphics-memory-probe.sh"), Path("provenance.toml")]
report = {
    "scope": "host memory/lifetime probe; not native GUI or hardware evidence",
    "sanitizers": sys.argv[2],
    "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "asan_options": os.environ.get("ASAN_OPTIONS"),
    "ubsan_options": os.environ.get("UBSAN_OPTIONS"),
    "compiler": subprocess.check_output(["c++", "--version"], text=True).splitlines()[0],
    "pool": json.loads((out / "pool-result.json").read_text()),
    "font": json.loads((out / "font-result.json").read_text()),
    "limits": [
        "64-bit host requested backing; not resident memory or physical PSRAM measurement",
        "Backing excludes controller, libc stdio, stack, code/rodata and host OS file cache",
        "No glyph bitmap cache, paragraph/ruby layout, editor document, framebuffer or scanout tested",
        "Sessions overlap in lifetime; worker calls are serialized, not parallel threads",
        "C/C++ and libraries are sanitizer-instrumented; Zig bridge is ReleaseSafe, not ASan-instrumented",
        "Logical suballocation lifetime is checked by records/canaries, not ASan redzones per object",
        "Shared HB state stays live; actual font-service teardown/restart remains unqualified",
    ],
}
if kernel:
    results = {name: json.loads((out / file).read_text()) for name, file in [
        ("backing", "backing-test-result.json"), ("pool", "pool-buddy-result.json"),
        ("font", "font-buddy-result.json")]}
    for key in ["gothic_horizontal_hash", "gothic_vertical_hash", "mincho_vertical_hash", "oom_points"]:
        assert report["font"][key] == results["font"][key], key
    assert results["font"]["kernel_raw_peak"] == 2 * 1024 * 1024 + 128 * 1024
    assert results["font"]["kernel_raw_after_close"] == 128 * 1024
    assert results["backing"]["full_heap_recovered"]
    assert results["backing"]["peer_survives_retirement"]
    report["kernel_backing"] = {
        "results": results,
        "zig_version": subprocess.check_output([os.environ["NIHOS_GRAPHICS_ZIG_USED"], "version"], text=True).strip(),
        "host_object_sha256": hashlib.sha256((out / "buddy/backing.o").read_bytes()).hexdigest(),
        "task_parent_limit": 2,
        "small_parent_raw_bytes": 128 * 1024,
        "active_parent_raw_bytes": 2 * 1024 * 1024,
        "host_owner_heap_backing_bytes": 15596992,
        "physical_device_tested": False,
    }
    inputs += [Path("src/kernel/buddy_heap.zig"), Path("src/kernel/task_resources.zig"),
               Path("src/kernel/slab.zig"), Path("src/kernel/size_pool.zig"),
               Path("src/kernel/c_allocator.zig"), Path("tools/bootstrap-zig.sh")]
    report["limits"] += [
        "Kernel algorithms execute over a host array emulating the 32 MiB layout's CPU0 heap",
        "Probe bridge uses one fixed service key; native scheduling, interrupts and identity routing are not integrated",
        "Two-parent compatibility uses a shared 2 MiB active parent; fine-grained logical frees do not always return physical buddy capacity",
        "Service retirement test uses no HB objects and does not prove safe restart of process-global library state",
    ]
else:
    report["limits"].append("POSIX backing only; kernel backing variant was not selected")
if os.environ.get("NIHOS_GRAPHICS_RV32_CXX"):
    obj = out / "metadata-rv32.o"
    size = elf_u32(obj, "nih_graphics_controller_bytes")
    assert size <= 8192
    report["rv32_compile_only"] = {
        "controller_bytes": size, "object_sha256": hashlib.sha256(obj.read_bytes()).hexdigest(),
        "compiler": subprocess.check_output([os.environ["NIHOS_GRAPHICS_RV32_CXX"], "--version"], text=True).splitlines()[0],
        "native_runtime_tested": False,
    }
    if kernel:
        obj = out / "buddy/backing-rv32.o"
        extra = elf_u32(obj, "nih_graphics_backing_control_size")
        assert size + extra + 64 <= 8192  # allow independent-global alignment padding
        report["rv32_compile_only"]["backing_state_size_sum"] = extra
        report["rv32_compile_only"]["combined_control_sum"] = size + extra
        report["rv32_compile_only"]["backing_object_sha256"] = hashlib.sha256(obj.read_bytes()).hexdigest()
        report["rv32_compile_only"]["allocator_object_sha256"] = hashlib.sha256(
            (out / "buddy/lazy-pool-rv32.o").read_bytes()).hexdigest()
report["source_sha256"] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}
path = out / "report.json"
temporary = path.with_suffix(".json.next")
temporary.write_text(json.dumps(report, indent=2) + "\n")
temporary.replace(path)
print(path.read_text(), end="")
