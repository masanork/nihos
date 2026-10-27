#!/usr/bin/env python3
"""Reproducible host/RV32 oracle comparison and instruction-observed SP peaks."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import unicorn

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]).resolve()
CXX = Path(os.environ["NIHOS_GRAPHICS_RV32_CXX"])
PREFIX = str(CXX).removesuffix("g++")
SOURCES = ROOT / "build/graphics-probe/sources"
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(args, log, env=None):
    with log.open("w") as stream:
        p = subprocess.run(list(map(str, args)), stdout=stream, stderr=subprocess.STDOUT, env=env)
    if p.returncode:
        raise RuntimeError(f"command failed ({p.returncode}); see {log}")


def elf(path):
    data = path.read_bytes()
    assert data[:6] == b"\x7fELF\x01\x01"
    off = struct.unpack_from("<I", data, 32)[0]
    step, count, strings = struct.unpack_from("<HHH", data, 46)
    sections = [struct.unpack_from("<10I", data, off + i * step) for i in range(count)]
    table = sections[strings]
    names = data[table[4]:table[4] + table[5]]
    named = {names[s[0]:].split(b"\0", 1)[0].decode(): s for s in sections}
    assert named.get(".init_array", [0] * 6)[5] == 0
    return {"text_and_rodata": sum(named[n][5] for n in (".text", ".rodata")),
            "data": named[".data"][5], "bss": named[".bss"][5],
            "elf_flags": struct.unpack_from("<I", data, 36)[0]}


def frames(build, image):
    symbols = subprocess.check_output([PREFIX + "nm", str(image)], text=True)
    functions = {line.split()[-1] for line in symbols.splitlines() if len(line.split()) >= 3}
    result = []
    for path in build.rglob("*.su"):
        for line in path.read_text().splitlines():
            cols = line.rsplit("\t", 2)
            if len(cols) != 3 or not cols[1].isdigit():
                continue
            name = cols[0].split(":", 3)[-1]
            # This exact-name membership covers the large FreeType C frames.
            linked = name in functions or any(n.startswith(name + ".") for n in functions)
            result.append({"function": name, "frame_bytes": int(cols[1]), "kind": cols[2], "linked": linked})
    return sorted(result, key=lambda x: x["frame_bytes"], reverse=True)


assert unicorn.__version__ == "2.1.4"
package = Path(unicorn.__file__).parent
library = next((package / "lib" / n for n in ["libunicorn.2.dylib", "libunicorn.so.2", "libunicorn.so"] if (package / "lib" / n).exists()), None)
assert library, "Unicorn shared library not found"
run(["c++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror", "-I" + str(package / "include"),
     ROOT / "probes/graphics/isa_stack_runner.cpp", library, "-Wl,-rpath," + str(library.parent),
     "-o", OUT / "isa-stack-runner"], OUT / "runner-build.log")
env = os.environ.copy()
if sys.platform == "darwin" and not env.get("MACOSX_DEPLOYMENT_TARGET"):
    env["MACOSX_DEPLOYMENT_TARGET"] = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
env.setdefault("ASAN_OPTIONS", "detect_stack_use_after_return=1")
env.setdefault("UBSAN_OPTIONS", "halt_on_error=1:print_stacktrace=1")
profiles = []
for pool, stacks in [(16384, [128, 4096, 16384, 32768]), (2048, [4096, 8192])]:
    print(f"render pool {pool}: build host and RV32", flush=True)
    profile = OUT / "profiles" / f"pool{pool}"
    profile.mkdir(parents=True, exist_ok=True)
    for target in ("host", "target"):
        args = ["cmake", "-S", ROOT / "probes/graphics", "-B", OUT / target,
                "-DPROBE_LINK_ORACLE=ON", "-DCMAKE_BUILD_TYPE=", f"-DPROBE_FT_RENDER_POOL_BYTES={pool}",
                "-DPROBE_SANITIZERS=" + ("ON" if target == "host" else "OFF"),
                "-DPROBE_GENERATED=" + str(OUT / "generated"), "-DPROBE_SOURCES=" + str(SOURCES),
                "-DPROBE_BUDDY_OBJECT=" + str(ROOT / "build/graphics-probe/buddy" / ("backing.o" if target == "host" else "backing-rv32.o"))]
        if target == "target":
            args.append("-DCMAKE_TOOLCHAIN_FILE=" + str(ROOT / "probes/graphics/rv32_toolchain.cmake"))
        run(args, profile / f"{target}-configure.log", env)
        run(["cmake", "--build", OUT / target, "--parallel", "4"], profile / f"{target}-build.log", env)
    fonts = [SOURCES / "BIZUDGothic-Regular.ttf", SOURCES / "BIZUDMincho-Regular.ttf"]
    with (profile / "host-result.json").open("w") as stream:
        subprocess.run([str(OUT / "host/font-link-oracle")] + list(map(str, fonts)), stdout=stream, env=env, check=True)
    host = json.loads((profile / "host-result.json").read_text())
    assert host["rc"] == 0 and host["runs"] == 16
    image = profile / "oracle.elf"
    shutil.copy2(OUT / "target/font-link-oracle", image)
    shutil.copy2(OUT / "target/oracle.map", profile / "oracle.map")
    cases = []
    for stack in stacks:
        print(f"render pool {pool}: execute RV32 with stack {stack}", flush=True)
        with (profile / f"isa-{stack}.json").open("w") as stream, (profile / f"isa-{stack}.log").open("w") as errors:
            p = subprocess.run([str(OUT / "isa-stack-runner"), str(image)] + list(map(str, fonts)) + [str(stack)], stdout=stream, stderr=errors)
        case = json.loads((profile / f"isa-{stack}.json").read_text())
        assert case["status"] in ("pass", "stack_guard"), case
        assert p.returncode == (0 if case["status"] == "pass" else 10)
        if case["status"] == "pass":
            assert case["hashes"] == host["hashes"] and case["runs"] == 16
            assert case["runtime_malloc_calls"] == case["unavailable_calls"] == 0
        case["min_function"] = subprocess.check_output([PREFIX + "addr2line", "-C", "-f", "-e", str(image), hex(case["min_pc"])], text=True).strip()
        cases.append(case)
    assert any(x["status"] == "pass" for x in cases)
    static = frames(OUT / "target", image)
    (profile / "stack-frames.json").write_text(json.dumps(static, indent=2) + "\n")
    profiles.append({"render_pool_bytes": pool, "host": host, "cases": cases, "sizes": elf(image),
                     "elf_sha256": sha(image), "map_sha256": sha(profile / "oracle.map"),
                     "largest_linked_c_frames": [x for x in static if x["linked"]][:12]})
assert profiles[0]["host"]["hashes"] == profiles[1]["host"]["hashes"]
assert profiles[0]["cases"][1]["status"] == "stack_guard"
assert profiles[1]["cases"][0]["status"] == "pass"
report = {"scope": "symbol-closed synthetic link and Unicorn RV32 ISA execution; not ESP32-P4 boot/peripheral or physical-device evidence",
          "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
          "unicorn_version": unicorn.__version__, "unicorn_library_sha256": sha(library),
          "compiler": subprocess.check_output([str(CXX), "--version"], text=True).splitlines()[0],
          "profiles": profiles,
          "limits": ["Full pinned TTFs are mapped external read-only test inputs, not native FS reads or fonts embedded in Flash footprint",
                     "All target instructions are observed for SP; guard check stops before out-of-range stack use",
                     "16 fixed cases: two fonts, 12/16/24/32 px body, half-size ruby run, horizontal and vertical shaping",
                     "No native SD/VFS, interrupts, dispatcher, task stop/restart, real Flash mapping or physical timing tested",
                     "4 KiB minus observed 3808-byte peak, 16-byte guard and 128-byte context frame leaves only 144 bytes before native caller/IO overhead",
                     "Registered auto-hinter has larger linked static frames; forced auto-hint/fallback-font paths are not executed or stack-qualified",
                     "FreeType uses explicit callbacks and no environment configuration; unavailable default memory/file entry points fail explicitly",
                     "Target newlib has one fixed reent context and bounded malloc hooks; unused nosys stubs remain and are execution-forbidden",
                     "Static stack frames are not whole-call-chain upper bounds; no worst-case stack certificate for arbitrary fonts/text"],
          "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / "probes/graphics").iterdir()) if p.is_file()}}
report["source_sha256"].update({str(p.relative_to(ROOT)): sha(p) for p in
    [ROOT / "tools/run-graphics-rv32-probe.sh", ROOT / "src/kernel/task_resources.zig", ROOT / "src/kernel/extent_groups.zig", ROOT / "src/kernel/buddy_heap.zig"]})
temporary = OUT / "report.json.next"
temporary.write_text(json.dumps(report, indent=2) + "\n")
temporary.replace(OUT / "report.json")
print("RV32 oracle passed; negative stack controls and exact host pixel/advance hashes retained.", flush=True)
