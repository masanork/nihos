#!/bin/sh
# Research only: compare the pinned upstream source and a local experimental patch.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
base="$root/build/wamr-2.4.5"
lab="$root/build/wamr-align-lab"
patch="$root/probes/wamr-host/patches/classic-frame-align-experiment.patch"
[ "$(git -C "$base" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || { echo 'Run probes/wamr-host/run.sh first' >&2; exit 1; }
[ -z "$(git -C "$base" status --porcelain)" ] || { echo 'Base source modified' >&2; exit 1; }
if [ ! -d "$lab/.git" ]; then
    git clone --shared --no-checkout "$base" "$lab"
    git -C "$lab" checkout --detach 25bd7eb63e828e4bd242cc9b38d260b4b31c6605
    git -C "$lab" apply "$patch"
fi
[ "$(git -C "$lab" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || exit 1
git -C "$lab" diff --binary > "$root/build/wamr-align-lab.diff"
git -C "$lab" diff --cached --quiet || { echo "Lab has staged changes" >&2; exit 1; }
cmp -s "$patch" "$root/build/wamr-align-lab.diff" || { echo 'Lab patch mismatch' >&2; exit 1; }
[ -z "$(git -C "$lab" ls-files --others --exclude-standard)" ] || { echo 'Lab has untracked source' >&2; exit 1; }
sh "$root/probes/wamr-host/run-small.sh"
flags='-fsanitize=address,undefined -fno-omit-frame-pointer -DWASM_CPU_SUPPORTS_UNALIGNED_ADDR_ACCESS=0'
for kind in stock patched; do
    if [ "$kind" = stock ]; then source="$base"; else source="$lab"; fi
    out="$root/build/wamr-align-lab-$kind"
    cmake -S "$root/probes/wamr-host" -B "$out" -DWAMR_ROOT_DIR="$source" -DCMAKE_BUILD_TYPE=Debug -DNIHOS_WAMR_FAST=0 "-DCMAKE_C_FLAGS=$flags" '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined'
    cmake --build "$out" --parallel 4
done
python3 - "$root" <<'PY'
import os, pathlib, subprocess, sys
root=pathlib.Path(sys.argv[1]); module=root/'build/rust-wasm-small/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm'
env=dict(os.environ,ASAN_OPTIONS='halt_on_error=1',UBSAN_OPTIONS='halt_on_error=1')
for kind in ('stock','patched'):
    binary=root/f'build/wamr-align-lab-{kind}/nihos-wamr-host'
    result=subprocess.run([str(binary),str(module),'4194304','fixed-memory'],capture_output=True,text=True,timeout=20,env=env)
    log=root/f'build/wamr-align-lab-{kind}.log'
    log.write_text(result.stdout+result.stderr)
    if kind == 'stock':
        if result.returncode == 0 or 'misaligned address' not in result.stderr or 'WASMBranchBlock' not in result.stderr:
            raise SystemExit(f'negative control not reproduced: {result.returncode}; {result.stderr[-1500:]}')
        print('Stock classic: expected WASMBranchBlock UBSan failure reproduced')
    else:
        if result.returncode or 'runtime error:' in result.stderr or 'ERROR: AddressSanitizer' in result.stderr:
            raise SystemExit(f'patched sanitizer failure: {result.returncode}; {result.stderr[-1500:]}')
        if 'WAMR 16 trap/destroy cycles' not in result.stdout:
            raise SystemExit('patched run incomplete')
        print('Patched classic + split access: ASan/UBSan fixture passed')
PY

out="$root/build/wamr-align-lab-quota"
cmake -S "$root/probes/wamr-quota" -B "$out" -DWAMR_ROOT_DIR="$lab" -DCMAKE_BUILD_TYPE=Debug "-DCMAKE_C_FLAGS=$flags" '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined'
cmake --build "$out" --parallel 4
python3 - "$root" <<'PY'
import os, pathlib, re, subprocess, sys
root=pathlib.Path(sys.argv[1]); binary=root/'build/wamr-align-lab-quota/wamr-quota'; module=root/'build/rust-wasm-small/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm'
env=dict(os.environ,ASAN_OPTIONS='halt_on_error=1',UBSAN_OPTIONS='halt_on_error=1')
base=subprocess.run([str(binary),str(module),'0','65536'],capture_output=True,text=True,timeout=15,env=env,check=True)
count=int(re.search(r'attempts=(\d+)',base.stdout).group(1))
for n in range(1,count+1):
    result=subprocess.run([str(binary),str(module),str(n),'65536'],capture_output=True,text=True,timeout=15,env=env)
    if result.returncode or 'injected=1' not in result.stdout or 'runtime_live=0 linear_live=0 runtime_blocks=0 linear_blocks=0' not in result.stdout:
        raise SystemExit(f'failure injection {n}/{count}: exit={result.returncode}; {result.stdout}; {result.stderr[-1000:]}')
print(f'Patched ASan/UBSan allocation failures: {count}/{count} tracked allocations reclaimed')
PY
