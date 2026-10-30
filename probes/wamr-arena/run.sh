#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
[ -x "$zig" ] && [ "$("$zig" version)" = 0.17.0 ] || { echo 'Set NIHOS_ZIG to Zig 0.17.0' >&2; exit 1; }
base="$root/build/wamr-2.4.5"
[ "$(git -C "$base" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || exit 1
[ -z "$(git -C "$base" status --porcelain)" ] || exit 1
sh "$root/probes/wamr-host/run-small.sh"
out="$root/build/wamr-arena"
mkdir -p "$out"
"$zig" test -O ReleaseSafe --dep buddy_heap -Mroot="$root/probes/wamr-arena/arena.zig" -Mbuddy_heap="$root/src/kernel/buddy_heap.zig"
"$zig" build-obj -O ReleaseSafe -femit-bin="$out/arena.o" --dep buddy_heap -Mroot="$root/probes/wamr-arena/arena.zig" -Mbuddy_heap="$root/src/kernel/buddy_heap.zig"
cmake -S "$root/probes/wamr-quota" -B "$out" -DWAMR_ROOT_DIR="$base" -DCMAKE_BUILD_TYPE=Release -DNIHOS_WAMR_BUDDY=ON -DNIHOS_ARENA_OBJ="$out/arena.o"
cmake --build "$out" --parallel 4
module="$root/build/rust-wasm-small/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm"
"$out/wamr-quota" "$module" 0 65536
"$out/wamr-quota" "$module" 0 65536 trap
"$out/wamr-quota" "$module" 0 65535

python3 - "$out/wamr-quota" "$module" <<'PYTEST'
import re, subprocess, sys
binary, module = sys.argv[1:]
base = subprocess.run([binary,module,'0','65536'],capture_output=True,text=True,timeout=10,check=True)
count = int(re.search(r'attempts=(\d+)',base.stdout).group(1))
for n in range(1,count+1):
    result=subprocess.run([binary,module,str(n),'65536'],capture_output=True,text=True,timeout=10)
    if result.returncode or 'injected=1' not in result.stdout or 'runtime_live=0 linear_live=0 runtime_blocks=0 linear_blocks=0' not in result.stdout or 'buddy_recovered=1' not in result.stdout:
        raise SystemExit(f'fault {n}/{count}: {result.returncode} {result.stdout} {result.stderr}')
print(f'WAMR buddy arena fault injections: {count}/{count} fully recovered')
PYTEST
