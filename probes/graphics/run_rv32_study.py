#!/usr/bin/env python3
"""Reproducible host/RV32 oracle comparison and instruction-observed SP peaks."""
from pathlib import Path
import hashlib
from datetime import datetime, timezone
import re
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
negative = {}
for pool, records, stacks in [(16384, 256, [128, 4096, 16384, 32768]), (2048, 512, []), (2048, 1024, [4096, 8192])]:
    print(f"render pool {pool}, records {records}: build host and RV32", flush=True)
    profile = OUT / "profiles" / f"pool{pool}-records{records}"
    profile.mkdir(parents=True, exist_ok=True)
    for target in ("host", "target"):
        args = ["cmake", "-S", ROOT / "probes/graphics", "-B", OUT / target,
                "-DPROBE_LINK_ORACLE=ON", "-DCMAKE_BUILD_TYPE=", f"-DPROBE_FT_RENDER_POOL_BYTES={pool}",
                f"-DPROBE_ALLOCATION_RECORDS={records}",
                "-DPROBE_SANITIZERS=" + ("ON" if target == "host" else "OFF"),
                "-DPROBE_GENERATED=" + str(OUT / "generated"), "-DPROBE_SOURCES=" + str(SOURCES),
                "-DPROBE_BUDDY_OBJECT=" + str(ROOT / "build/graphics-probe/buddy" / ("backing.o" if target == "host" else "backing-rv32.o"))]
        if target == "target":
            args.append("-DCMAKE_TOOLCHAIN_FILE=" + str(ROOT / "probes/graphics/rv32_toolchain.cmake"))
        run(args, profile / f"{target}-configure.log", env)
        run(["cmake", "--build", OUT / target, "--parallel", "4"], profile / f"{target}-build.log", env)
    fonts = [SOURCES / "BIZUDGothic-Regular.ttf", SOURCES / "BIZUDMincho-Regular.ttf"]
    image = profile / "oracle.elf"
    shutil.copy2(OUT / "target/font-link-oracle", image)
    shutil.copy2(OUT / "target/oracle.map", profile / "oracle.map")
    modes = []
    mode_cases = [] if records == 512 else [(0, "default", stacks)]
    if records == 1024:
        mode_cases += [(1, "auto", [4096, 8192, 16384, 32768]), (2, "none", [4096, 8192])]
    for mode, label, mode_stacks in mode_cases:
        with (profile / f"host-{label}.json").open("w") as stream:
            subprocess.run([str(OUT / "host/font-link-oracle")] + list(map(str, fonts)) + [str(mode)], stdout=stream, env=env, check=True)
        host = json.loads((profile / f"host-{label}.json").read_text())
        assert host["rc"] == 0 and host["runs"] == 16
        cases = []
        for stack in mode_stacks:
            print(f"render pool {pool}, hint {label}: execute RV32 with stack {stack}", flush=True)
            result_path = profile / f"isa-{label}-{stack}.json"
            with result_path.open("w") as stream, (profile / f"isa-{label}-{stack}.log").open("w") as errors:
                p = subprocess.run([str(OUT / "isa-stack-runner"), str(image)] + list(map(str, fonts)) + [str(stack), str(mode)], stdout=stream, stderr=errors)
            case = json.loads(result_path.read_text())
            assert case["status"] in ("pass", "stack_guard"), case
            assert p.returncode == (0 if case["status"] == "pass" else 10)
            if case["status"] == "pass":
                assert case["hashes"] == host["hashes"] and case["runs"] == 16
                assert case["runtime_malloc_calls"] == case["unavailable_calls"] == 0
                assert case["allocation_failures"] == case["record_failures"] == 0
                assert case["record_peak"] <= case["record_capacity"] == records
                paths = case["path_entries"]
                if mode == 1:
                    assert all(paths[n] > 0 for n in ("af_autofitter_load_glyph", "af_cjk_metrics_init_widths", "af_latin_metrics_init_widths")), paths
                    assert paths["TT_RunIns"] == 0, paths
                elif mode == 2:
                    assert not any(paths.values()), paths
                else:
                    assert paths["TT_RunIns"] > 0 and paths["af_autofitter_load_glyph"] == 0, paths
            case["min_function"] = subprocess.check_output([PREFIX + "addr2line", "-C", "-f", "-e", str(image), hex(case["min_pc"])], text=True).strip()
            case["result_sha256"] = sha(result_path)
            cases.append(case)
        assert any(x["status"] == "pass" for x in cases)
        modes.append({"load_mode": mode, "hinting": label, "host": host, "cases": cases})
    if records in (256, 512):
        # This used to crash inside FreeType after exhausting allocation records.
        print(f"verify {records}-record auto-hint refusal and full client cleanup", flush=True)
        negative[str(records)] = {}
        for target, args in [("host", [str(OUT / "host/font-link-oracle")] + list(map(str, fonts)) + ["1"]),
                             ("rv32", [str(OUT / "isa-stack-runner"), str(image)] + list(map(str, fonts)) + ["65536", "1"])]:
            result_path = profile / f"{target}-auto-record-refusal.json"
            with result_path.open("w") as stream, (profile / f"{target}-auto-record-refusal.log").open("w") as errors:
                p = subprocess.run(args, stdout=stream, stderr=errors, env=env)
            case = json.loads(result_path.read_text())
            assert p.returncode == 20 and case["stage"] == 90 and case["record_failures"] > 0, case
            assert case["record_peak"] == case["record_capacity"] == records and case["retained"] == 65792, case
            assert case["runs"] < 16, case
            if target == "rv32":
                assert case["status"] == "allocation_refused", case
            case["result_sha256"] = sha(result_path)
            negative[str(records)][target] = case
    static = frames(OUT / "target", image)
    (profile / "stack-frames.json").write_text(json.dumps(static, indent=2) + "\n")
    sizes = elf(image)
    undefined = subprocess.check_output([PREFIX + "nm", "-u", str(image)], text=True).strip()
    assert not undefined, undefined
    disassembly = subprocess.check_output([PREFIX + "objdump", "-d", "--no-show-raw-insn", str(image)], text=True)
    fp = [line for line in disassembly.splitlines() if re.match(r"^\s*[0-9a-f]+:\s+f[a-z0-9.]+\s", line) and not re.search(r"\bfence", line)]
    assert not fp, fp[:10]
    profiles.append({"render_pool_bytes": pool, "allocation_records": records, "modes": modes, "sizes": sizes,
                     "elf_sha256": sha(image), "map_sha256": sha(profile / "oracle.map"),
                     "largest_linked_c_frames": [x for x in static if x["linked"]][:12],
                     "unresolved_symbols": [], "floating_point_instructions": len(fp),
                     "riscv_attributes": subprocess.check_output([PREFIX + "readelf", "-A", str(image)], text=True),
                     "flash_payload_bytes": sizes["text_and_rodata"] + sizes["data"],
                     "static_writable_bytes": sizes["data"] + sizes["bss"]})
assert profiles[0]["modes"][0]["host"]["hashes"] == profiles[2]["modes"][0]["host"]["hashes"]
assert profiles[0]["modes"][0]["cases"][1]["status"] == "stack_guard"
assert profiles[2]["modes"][0]["cases"][0]["status"] == "pass"
# Ensure a flag accidentally ignored by both host and target cannot look correct.
assert len({tuple(m["host"]["hashes"]) for m in profiles[2]["modes"]}) == 3
report = {"scope": "symbol-closed synthetic link and Unicorn RV32 ISA execution; not ESP32-P4 boot/peripheral or physical-device evidence",
          "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
          "unicorn_version": unicorn.__version__, "unicorn_library_sha256": sha(library),
          "compiler": subprocess.check_output([str(CXX), "--version"], text=True).splitlines()[0],
          "profiles": profiles,
          "allocation_negative_control": negative,
          "limits": ["Full pinned TTFs are mapped external read-only test inputs, not native FS reads or fonts embedded in Flash footprint",
                     "All target instructions are observed for SP; guard check stops before out-of-range stack use",
                     "16 fixed cases: two fonts, 12/16/24/32 px body, half-size ruby run, horizontal and vertical shaping",
                     "No native SD/VFS, interrupts, dispatcher, task stop/restart, real Flash mapping or physical timing tested",
                     "Existing 4 KiB native worker stacks are not approved by these standalone measurements",
                     "Default, forced auto-hint and unhinted paths are qualified only for the pinned fonts and fixed cases; arbitrary fallback fonts remain untested",
                     "FreeType uses explicit callbacks and no environment configuration; unavailable default memory/file entry points fail explicitly",
                     "Target newlib has one fixed reent context and bounded malloc hooks; unused nosys stubs remain and are execution-forbidden",
                     "Static stack frames are not whole-call-chain upper bounds; no worst-case stack certificate for arbitrary fonts/text"],
          "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / "probes/graphics").iterdir()) if p.is_file()}}
report["source_sha256"].update({str(p.relative_to(ROOT)): sha(p) for p in (ROOT / "probes/graphics/patches").glob("*.patch")})
report["source_sha256"].update({str(p.relative_to(ROOT)): sha(p) for p in
    [ROOT / "tools/run-graphics-rv32-probe.sh", ROOT / "src/kernel/task_resources.zig", ROOT / "src/kernel/extent_groups.zig", ROOT / "src/kernel/buddy_heap.zig"]})
report["created_utc"] = datetime.now(timezone.utc).isoformat()
report["input_fonts"] = [{"name": p.name, "bytes": p.stat().st_size, "sha256": sha(p)} for p in fonts]
report["runtime_archives"] = {}
for name in ("libc.a", "libm.a", "libgcc.a", "libnosys.a", "libstdc++.a"):
    path = Path(subprocess.check_output([str(CXX), "-march=rv32imac_zicsr_zifencei", "-mabi=ilp32", "-fno-rtti", "-print-file-name=" + name], text=True).strip())
    report["runtime_archives"][name] = {"path": str(path), "sha256": sha(path)}
report["provenance_sha256"] = sha(ROOT / "provenance.toml")
report["checks"] = {"host_oracle_sanitizers": "ASan/UBSan", "native_fonts_executed_on_hardware": False,
                    "memory_probe_replayed": True, "memory_probe_log_sha256": sha(OUT / "memory-base.log")}
temporary = OUT / "report.json.next"
temporary.write_text(json.dumps(report, indent=2) + "\n")
temporary.replace(OUT / "report.json")
print("RV32 oracle passed; negative stack controls and exact host pixel/advance hashes retained.", flush=True)
