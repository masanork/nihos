#!/bin/sh
# Independent host experiment; does not change native firmware or access hardware.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
out="$repo_root/build/graphics-probe"
mkdir -p "$out"
rm -f "$out/report.json" "$out/pool-result.json" "$out/font-result.json" "$out/metadata-rv32.o"
sanitizers=${NIHOS_GRAPHICS_SANITIZERS:-ON}
case "$sanitizers" in ON|OFF) ;; *) echo 'NIHOS_GRAPHICS_SANITIZERS must be ON or OFF' >&2; exit 1 ;; esac
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_stack_use_after_return=1}
UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}
export ASAN_OPTIONS UBSAN_OPTIONS
sources=$(python3 probes/graphics/fetch_sources.py)
if ! cmake -S probes/graphics -B "$out/host" -DPROBE_SOURCES="$sources" \
    -DPROBE_SANITIZERS="$sanitizers" -DCMAKE_BUILD_TYPE=RelWithDebInfo > "$out/configure.log" 2>&1; then
    tail -60 "$out/configure.log" >&2; exit 1
fi
if ! cmake --build "$out/host" --parallel 4 > "$out/build.log" 2>&1; then
    tail -60 "$out/build.log" >&2; exit 1
fi
"$out/host/pool-test" > "$out/pool-result.json"
"$out/host/font-probe" "$sources/BIZUDGothic-Regular.ttf" "$sources/BIZUDMincho-Regular.ttf" > "$out/font-result.json"
if [ -n "${NIHOS_GRAPHICS_RV32_CXX:-}" ]; then
    "$NIHOS_GRAPHICS_RV32_CXX" -std=c++17 -Os -fdata-sections -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
        -c probes/graphics/metadata_size.cpp -o "$out/metadata-rv32.o"
fi
python3 - "$out" "$sanitizers" <<'PY'
from pathlib import Path
import hashlib,json,os,struct,subprocess,sys
out=Path(sys.argv[1])
report={"scope":"host memory/lifetime probe; not native GUI or hardware evidence",
        "sanitizers":sys.argv[2],"base_commit":subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        "asan_options":os.environ.get('ASAN_OPTIONS'),"ubsan_options":os.environ.get('UBSAN_OPTIONS'),
        "compiler":subprocess.check_output(['c++','--version'],text=True).splitlines()[0],
        "pool":json.loads((out/'pool-result.json').read_text()),
        "font":json.loads((out/'font-result.json').read_text()),
        "source_sha256":{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                         sorted(Path('probes/graphics').iterdir())+[Path('tools/run-graphics-memory-probe.sh'),Path('provenance.toml')] if p.is_file()},
        "limits":["64-bit host requested backing; not resident memory or native PSRAM measurement",
                  "Backing excludes controller, libc stdio, stack, code/rodata and host OS file cache",
                  "No glyph bitmap cache, paragraph/ruby layout, editor document, framebuffer or scanout tested",
                  "Sessions overlap in lifetime; worker calls are serialized, not parallel threads",
                  "Backing uses host posix_memalign/free; native task-ledger/page integration is not implemented",
                  "Shared library allocations stay live for service lifetime; forced task teardown/restart unqualified"]}
if os.environ.get('NIHOS_GRAPHICS_RV32_CXX'):
    obj=(out/'metadata-rv32.o').read_bytes()
    assert obj[:6]==b'\x7fELF\x01\x01'
    shoff=struct.unpack_from('<I',obj,32)[0]
    entsize,num,strings=struct.unpack_from('<HHH',obj,46)
    sections=[struct.unpack_from('<10I',obj,shoff+i*entsize) for i in range(num)]
    stringsection=sections[strings];names=obj[stringsection[4]:stringsection[4]+stringsection[5]]
    section=next(s for s in sections if names[s[0]:].split(b'\0',1)[0] in
                 (b'.rodata.nih_graphics_controller_bytes',b'.srodata.nih_graphics_controller_bytes'))
    size=struct.unpack_from('<I',obj,section[4])[0];assert size<=8192
    report['rv32_compile_only']={"controller_bytes":size,"object_sha256":hashlib.sha256(obj).hexdigest(),
                                "compiler":subprocess.check_output([os.environ['NIHOS_GRAPHICS_RV32_CXX'],'--version'],text=True).splitlines()[0],
                                "native_runtime_tested":False}
path=out/'report.json';temporary=path.with_suffix('.json.next')
temporary.write_text(json.dumps(report,indent=2)+'\n');temporary.replace(path)
print(path.read_text(),end='')
PY
