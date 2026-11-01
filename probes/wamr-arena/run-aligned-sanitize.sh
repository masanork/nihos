#!/bin/sh
# Host lab: experimental WAMR alignment patch; Zig arena remains ReleaseSafe.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
lab="$root/build/wamr-align-lab"
patch="$root/probes/wamr-host/patches/classic-frame-align-experiment.patch"
[ "$(git -C "$lab" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || exit 1
git -C "$lab" diff --binary > "$root/build/wamr-arena-lab.diff"
cmp -s "$patch" "$root/build/wamr-arena-lab.diff" || { echo 'Unexpected WAMR lab patch' >&2; exit 1; }
git -C "$lab" diff --cached --quiet || exit 1
[ -z "$(git -C "$lab" ls-files --others --exclude-standard)" ] || exit 1
# Refresh the ReleaseSafe arena object and its independent tests.
sh "$root/probes/wamr-arena/run.sh"
obj="$root/build/wamr-arena/arena.o"
out="$root/build/wamr-arena-sanitize"
flags='-fsanitize=address,undefined -fno-omit-frame-pointer -DWASM_CPU_SUPPORTS_UNALIGNED_ADDR_ACCESS=0'
cmake -S "$root/probes/wamr-quota" -B "$out" -DWAMR_ROOT_DIR="$lab" -DCMAKE_BUILD_TYPE=Debug -DNIHOS_WAMR_BUDDY=ON -DNIHOS_ARENA_OBJ="$obj" "-DCMAKE_C_FLAGS=$flags" '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined'
cmake --build "$out" --parallel 4
python3 - "$out/wamr-quota" "$root/build/rust-wasm-small/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm" <<'PYTEST'
import os, re, subprocess, sys
binary, module = sys.argv[1:]
env=dict(os.environ,ASAN_OPTIONS='halt_on_error=1',UBSAN_OPTIONS='halt_on_error=1')
base=subprocess.run([binary,module,'0','65536'],capture_output=True,text=True,timeout=15,env=env,check=True)
if 'buddy_recovered=1' not in base.stdout: raise SystemExit('baseline arena not recovered')
trap=subprocess.run([binary,module,'0','65536','trap'],capture_output=True,text=True,timeout=15,env=env,check=True)
if 'buddy_recovered=1' not in trap.stdout: raise SystemExit('trap arena not recovered')
print('Guest memory trap: buddy arenas recovered')
count=int(re.search(r'attempts=(\d+)',base.stdout).group(1))
for n in range(1,count+1):
    r=subprocess.run([binary,module,str(n),'65536'],capture_output=True,text=True,timeout=15,env=env)
    if r.returncode or 'injected=1' not in r.stdout or 'runtime_live=0 linear_live=0 runtime_blocks=0 linear_blocks=0' not in r.stdout or 'buddy_recovered=1' not in r.stdout:
        raise SystemExit(f'failure {n}/{count}: exit={r.returncode}; {r.stdout}; {r.stderr[-1500:]}')
print(f'Patched WAMR ASan/UBSan + Zig ReleaseSafe arena: {count}/{count} fault points recovered')
PYTEST
