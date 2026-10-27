#!/usr/bin/env python3
"""Common task runtime and native trap/return evidence, not P4 boot evidence."""
from datetime import datetime, timezone
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import unicorn

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(sys.argv[1]).resolve()
CXX = Path(os.environ["NIHOS_GRAPHICS_RV32_CXX"])
PREFIX = str(CXX).removesuffix("g++")
SOURCES = ROOT / "build/graphics-probe/sources"
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(args, log, env=None):
    with log.open("w") as stream:
        result = subprocess.run(list(map(str, args)), stdout=stream, stderr=subprocess.STDOUT, env=env)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {log}")


def configure(target, worker=False):
    args = ["cmake", "-S", ROOT / "probes/graphics", "-B", OUT / target,
            "-DPROBE_LINK_ORACLE=ON", "-DCMAKE_BUILD_TYPE=", "-DPROBE_FT_RENDER_POOL_BYTES=2048",
            "-DPROBE_ALLOCATION_RECORDS=1024", "-DPROBE_TASK_ORACLE=" + ("ON" if worker else "OFF"),
            "-DPROBE_SANITIZERS=" + ("ON" if target == "host" else "OFF"),
            "-DPROBE_GENERATED=" + str(OUT / "generated"), "-DPROBE_SOURCES=" + str(SOURCES),
            "-DPROBE_BUDDY_OBJECT=" + str(ROOT / "build/graphics-probe/buddy" / ("backing.o" if target == "host" else "backing-rv32.o"))]
    if target != "host":
        args += ["-DCMAKE_TOOLCHAIN_FILE=" + str(ROOT / "probes/graphics/rv32_toolchain.cmake"),
                 "-DPROBE_WORKER_OBJECT=" + str(OUT / "runtime.o")]
    label = target + ("-worker" if worker else "-plain")
    run(args, OUT / (label + "-configure.log"), env)
    run(["cmake", "--build", OUT / target, "--parallel", "4"], OUT / (label + "-build.log"), env)


def execute(args, name, expected=0):
    path = OUT / (name + ".json")
    with path.open("w") as output, (OUT / (name + ".log")).open("w") as errors:
        result = subprocess.run(list(map(str, args)), stdout=output, stderr=errors, env=env)
    case = json.loads(path.read_text())
    assert result.returncode == expected, (name, result.returncode, case)
    case["result_sha256"] = sha(path)
    return case


assert unicorn.__version__ == "2.1.4"
package = Path(unicorn.__file__).parent
library = next(p for p in [package / "lib/libunicorn.2.dylib", package / "lib/libunicorn.so.2"] if p.exists())
env = os.environ.copy()
if sys.platform == "darwin" and not env.get("MACOSX_DEPLOYMENT_TARGET"):
    env["MACOSX_DEPLOYMENT_TARGET"] = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
env.setdefault("ASAN_OPTIONS", "detect_stack_use_after_return=1")
env.setdefault("UBSAN_OPTIONS", "halt_on_error=1:print_stacktrace=1")
for source, name in [(ROOT / "probes/graphics/worker/runner.cpp", "worker-runner"),
                     (ROOT / "probes/graphics/isa_stack_runner.cpp", "plain-runner")]:
    run(["c++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror", "-I" + str(package / "include"),
         source, library, "-Wl,-rpath," + str(library.parent), "-o", OUT / name], OUT / (name + "-build.log"))
print("build host and plain RV32 regression", flush=True)
configure("host")
configure("target")
shutil.copy2(OUT / "target/font-link-oracle", OUT / "plain.elf")
shutil.copy2(OUT / "target/oracle.map", OUT / "plain.map")
fonts = [SOURCES / "BIZUDGothic-Regular.ttf", SOURCES / "BIZUDMincho-Regular.ttf"]
host = {}
for mode, name in [(0, "default"), (1, "auto")]:
    host[name] = execute([OUT / "host/font-link-oracle", *fonts, mode], "host-" + name)
    assert host[name]["runs"] == 16 and host[name]["rc"] == 0
plain = execute([OUT / "plain-runner", OUT / "plain.elf", *fonts, 4096, 0], "plain-regression")
assert plain["status"] == "pass" and plain["hashes"] == host["default"]["hashes"]
print("build native-context worker fixture", flush=True)
configure("target", True)
shutil.copy2(OUT / "target/font-link-oracle", OUT / "worker.elf")
shutil.copy2(OUT / "target/oracle.map", OUT / "worker.map")
undefined = subprocess.check_output([PREFIX + "nm", "-u", str(OUT / "worker.elf")], text=True).strip()
assert not undefined, undefined
attributes = subprocess.check_output([PREFIX + "readelf", "-A", str(OUT / "worker.elf")], text=True)
assert not re.search(r"_[fd][0-9]", attributes), attributes
disassembly = subprocess.check_output([PREFIX + "objdump", "-d", "--no-show-raw-insn", str(OUT / "worker.elf")], text=True)
fp = [line for line in disassembly.splitlines() if re.match(r"^\s*[0-9a-f]+:\s+f[a-z0-9.]+\s", line) and not re.search(r"\bfence", line)]
assert not fp, fp[:10]
cases = []
for name, stack, mode, timers, reads in [
        ("guard-16k", 16384, 1, 1, 0), ("control", 32768, 1, 0, 0),
        ("preempt", 32768, 1, 1, 0), ("callback-yield", 32768, 0, 0, 1)]:
    print("execute " + name, flush=True)
    case = execute([OUT / "worker-runner", OUT / "worker.elf", *fonts, stack, mode, timers, reads], name, 10 if name == "guard-16k" else 0)
    if name == "guard-16k":
        assert case["status"] == "stack_guard" and case["graphics"]["runs"] == 0
    else:
        w, g = case["worker"], case["graphics"]
        assert case["status"] == "pass" and g["runs"] == 16 and w["reaped"] == 2 and w["failure"] == 0
        assert g["hashes"] == host["auto" if mode else "default"]["hashes"]
        assert g["retained"] == 65792 and g["runtime_malloc_calls"] == g["unavailable_calls"] == 0
        assert w["irq_samples"] == w["timer_traps"] + w["call_traps"]
        if name == "control":
            assert w["peer_progress"] == w["timer_traps"] == w["read_yields"] == 0
        if name == "preempt":
            assert case["hb_injected"] and case["deep_injected"]
            assert w["peer_progress"] > 0 and w["font_captures"] == w["timer_traps"] == case["timer_injections"]
            assert w["read_yields"] == 0
        if name == "callback-yield":
            assert w["peer_progress"] > 0 and w["read_yields"] > 0 and w["timer_traps"] == 0
    for field in ("min_font_pc", "hb_pc", "deep_pc"):
        if case[field]:
            case[field + "_function"] = subprocess.check_output([PREFIX + "addr2line", "-C", "-f", "-e", str(OUT / "worker.elf"), hex(case[field])], text=True).strip()
    case["name"] = name
    cases.append(case)
assert cases[1]["graphics"]["hashes"] == cases[2]["graphics"]["hashes"]
code = OUT / "worker.elf"
data = code.read_bytes()
offset = struct.unpack_from("<I", data, 32)[0]
step, count, strings = struct.unpack_from("<HHH", data, 46)
sections = [struct.unpack_from("<10I", data, offset + i * step) for i in range(count)]
table = sections[strings]
names = data[table[4]:table[4] + table[5]]
named = {names[s[0]:].split(b"\0", 1)[0].decode(): s for s in sections}
assert named.get(".init_array", [0] * 6)[5] == 0
assert named[".stacks"][1] == 8 and named[".stacks"][2] == 3 and named[".stacks"][3:4] == (0x4ff60000,)
report = {
    "created_utc": datetime.now(timezone.utc).isoformat(),
    "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "scope": "RV32 ISA execution of shared task runtime, task calls and unchanged native trap ASM; synthetic event delivery and mappings, not ESP32-P4 boot",
    "cases": cases, "host": host, "plain_regression": plain,
    "worker_elf_sha256": sha(code), "worker_map_sha256": sha(OUT / "worker.map"),
    "plain_elf_sha256": sha(OUT / "plain.elf"), "runner_sha256": sha(OUT / "worker-runner"),
    "unicorn_version": unicorn.__version__, "unicorn_library_sha256": sha(library),
    "sizes": {name: named[name][5] for name in (".text", ".rodata", ".data", ".bss", ".stacks")},
    "riscv_attributes": attributes, "floating_point_instructions": len(fp),
    "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / "probes/graphics").rglob("*")) if p.is_file() and "__pycache__" not in p.parts},
    "input_fonts": [{"name": p.name, "bytes": p.stat().st_size, "sha256": sha(p)} for p in fonts],
    "limits": [
        "Timer traps are injected at instruction boundaries while MIE is enabled; no P4 CLIC/timer controller or real IRQ latency is modeled",
        "ECALL entry CSR effects are supplied by the harness; the real native integer save/dispatch/restore/MRET path executes",
        "Only hart 0 executes; the peer is another task on that hart, not an SMP/physical-device result",
        "Full TTF inputs are external read-only mappings, not native SD/VFS reads",
        "Source callback yields test suspended library frames, not an asynchronous storage driver or filesystem lifetime",
        "The allocator still owns an isolated modeled heap and ledger; it is not bound to native OS task-resource ownership or native PSRAM initialization",
        "Both client sessions close before task return; 65792 bytes of HB service backing remain; reaping a task does not prove service shutdown/restart cleanup",
        "Synthetic stacks occupy a 96 KiB NOLOAD span including unused alignment padding; no production native stack bank or Flash allowlist is changed",
        "No loader collision audit, firmware image, cache-off code, interrupt nesting, physical display or hardware timing is qualified"
    ]}
for p in [ROOT / "tools/run-graphics-worker-probe.sh", ROOT / "src/platform/native/start.S",
          ROOT / "src/arch/riscv32/task_runtime.zig", ROOT / "src/arch/riscv32/context.zig",
          ROOT / "src/arch/riscv32/task_calls.zig", ROOT / "src/kernel/scheduler.zig", ROOT / "src/kernel/task_control.zig",
          ROOT / "src/kernel/buddy_heap.zig", ROOT / "src/kernel/task_resources.zig", ROOT / "src/kernel/extent_groups.zig"]:
    report["source_sha256"][str(p.relative_to(ROOT))] = sha(p)
report["checks"] = {"host_asan_ubsan": True, "memory_probe_log_sha256": sha(OUT / "memory-base.log"), "unresolved_symbols": []}
(OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print("Worker context, timer preemption, callback yields and negative controls passed", flush=True)
