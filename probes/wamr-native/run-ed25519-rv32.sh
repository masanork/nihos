#!/bin/sh
# Compile-only RV32 closure audit. Runtime/stack evidence is in run-emulator.sh.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/package-ed25519-rv32"
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
[ -x "$zig" ] || { echo 'Set NIHOS_ZIG to Zig 0.17.0' >&2; exit 1; }
cc_path=$(command -v "$cc") || { echo 'Set NIHOS_RISCV_CC' >&2; exit 1; }
prefix=${cc_path%gcc}
mkdir -p "$out"
"$zig" build-obj -target riscv32-freestanding-none \
    -mcpu generic_rv32+m+a+c+zicsr+zifencei -O ReleaseSmall \
    -femit-bin="$out/verifier.o" \
    --dep package_ed25519 --dep app_package --dep app_policy \
    -Mroot="$root/probes/wamr-native/ed25519-rv32.zig" \
    --dep app_package -Mpackage_ed25519="$root/src/app/package_ed25519.zig" \
    --dep app_policy -Mapp_package="$root/src/app/package.zig" \
    -Mapp_policy="$root/src/app/module_policy.zig"
"${prefix}size" -A "$out/verifier.o" > "$out/size.txt"
"${prefix}nm" -u "$out/verifier.o" > "$out/undefined.txt"
"${prefix}readelf" -h -A "$out/verifier.o" > "$out/attributes.txt"
python3 - "$out/undefined.txt" "$out/attributes.txt" <<'PY'
import re, sys
from pathlib import Path
undefined={line.split()[-1] for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()}
expected={'__lshrdi3','memcpy','memset'}
if undefined != expected:
    raise SystemExit(f'unexpected RV32 imports: {sorted(undefined)}')
attributes=Path(sys.argv[2]).read_text()
if 'soft-float ABI' not in attributes or not re.search(r'Tag_RISCV_arch: "rv32i[^\"]*_m[^\"]*_a[^\"]*_c',attributes):
    raise SystemExit('RV32IMAC soft-float attributes missing')
PY
cat "$out/size.txt"
cat "$out/undefined.txt"
echo 'Ed25519 RV32 compile closure: ok'
