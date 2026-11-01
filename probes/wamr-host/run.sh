#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
wamr="$root/build/wamr-2.4.5"
if [ ! -d "$wamr/.git" ]; then
  git clone --depth 1 --branch WAMR-2.4.5 https://github.com/bytecodealliance/wasm-micro-runtime.git "$wamr"
fi
[ "$(git -C "$wamr" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ] || { echo 'WAMR revision mismatch' >&2; exit 1; }
[ -z "$(git -C "$wamr" status --porcelain)" ] || { echo 'WAMR source modified' >&2; exit 1; }
sh "$root/probes/rust-wasm/run-host.sh"
cmake -S "$root/probes/wamr-host" -B "$root/build/wamr-host" -DWAMR_ROOT_DIR="$wamr" -DCMAKE_BUILD_TYPE=Release
cmake --build "$root/build/wamr-host" --parallel 4
"$root/build/wamr-host/nihos-wamr-host" "$root/build/rust-wasm-probe/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm"

set +e
"$root/build/wamr-host/nihos-wamr-host" "$root/build/rust-wasm-probe/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm" 4096 > "$root/build/wamr-host-small-pool.log" 2>&1
small_result=$?
set -e
[ "$small_result" -eq 7 ] || { echo "Expected exec env allocation failure, got $small_result" >&2; exit 1; }
printf 'WAMR small-pool exec env allocation failure: ok\n'
printf '\000asm\001' > "$root/build/wamr-host/truncated.wasm"
set +e
"$root/build/wamr-host/nihos-wamr-host" "$root/build/wamr-host/truncated.wasm" > "$root/build/wamr-host-truncated.log" 2>&1
malformed_result=$?
set -e
[ "$malformed_result" -eq 5 ] || { echo "Expected invalid module load failure, got $malformed_result" >&2; exit 1; }
printf 'WAMR truncated module rejection: ok\n'
