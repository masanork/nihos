#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
wamr="$root/build/wamr-2.4.5"
[ "$(git -C "$wamr" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || exit 1
[ -z "$(git -C "$wamr" status --porcelain)" ] || exit 1
sh "$root/probes/wamr-host/run-small.sh"
cmake -S "$root/probes/wamr-quota" -B "$root/build/wamr-quota" -DWAMR_ROOT_DIR="$wamr" -DCMAKE_BUILD_TYPE=Release
cmake --build "$root/build/wamr-quota" --parallel 4
module="$root/build/rust-wasm-small/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm"
bin="$root/build/wamr-quota/wamr-quota"
"$bin" "$module" 0 65536
"$bin" "$module" 0 65535

python3 - "$bin" "$module" <<'PYTEST'
import re, subprocess, sys
binary, module = sys.argv[1:]
base = subprocess.run([binary,module,'0','65536'], capture_output=True, text=True, timeout=10, check=True)
match = re.search(r'attempts=(\d+)', base.stdout)
if not match: raise SystemExit('missing allocation count')
count = int(match.group(1))
recovered, optional = 0, 0
for n in range(1,count+1):
    p = subprocess.run([binary,module,str(n),'65536'], capture_output=True, text=True, timeout=10)
    if p.returncode or 'injected=1' not in p.stdout or 'runtime_live=0 linear_live=0 runtime_blocks=0 linear_blocks=0' not in p.stdout:
        raise SystemExit(f'failure injection {n}/{count} failed: exit={p.returncode} stdout={p.stdout!r} stderr={p.stderr!r}')
    if 'success=1' in p.stdout: optional += 1
    else: recovered += 1
print(f'WAMR allocation failure injection: {count}/{count} reclaimed; failed={recovered}, continued={optional}')
try:
    subprocess.run([binary,module,'1','65536','combined-init'], capture_output=True, text=True, timeout=2)
except subprocess.TimeoutExpired:
    print('Negative control: combined init with first allocation failure deadlocks (WAMR 2.4.5/macOS)')
else:
    raise SystemExit('Expected combined-init deadlock negative control did not reproduce')
PYTEST
