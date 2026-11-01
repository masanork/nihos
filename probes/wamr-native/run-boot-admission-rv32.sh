#!/bin/sh
# Compile-only RV32 check for boot trust/package composition. Not runtime proof.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/boot-admission-rv32"
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
cc=${NIHOS_RISCV_CC:-riscv32-esp-elf-gcc}
[ -x "$zig" ] || { echo 'Set NIHOS_ZIG to Zig 0.17.0' >&2; exit 1; }
cc_path=$(command -v "$cc") || { echo 'Set NIHOS_RISCV_CC' >&2; exit 1; }
prefix=${cc_path%gcc}
mkdir -p "$out"
"$zig" build-obj -target riscv32-freestanding-none \
    -mcpu generic_rv32+m+a+c+zicsr+zifencei -O ReleaseSmall \
    -femit-bin="$out/boot-admission.o" \
    --dep app_boot \
    -Mroot="$root/probes/wamr-native/boot-admission-rv32.zig" \
    --dep app_install --dep app_policy --dep package_ed25519 --dep trust_snapshot --dep trust_snapshot_ed25519 --dep trust_snapshot_store \
    -Mapp_boot="$root/src/app/boot_admission.zig" \
    --dep app_package --dep app_policy -Mapp_install="$root/src/app/package_install.zig" \
    --dep app_policy -Mapp_package="$root/src/app/package.zig" \
    -Mapp_policy="$root/src/app/module_policy.zig" \
    --dep app_package -Mpackage_ed25519="$root/src/app/package_ed25519.zig" \
    --dep app_package -Mtrust_snapshot="$root/src/app/trust_snapshot.zig" \
    --dep app_package --dep package_ed25519 --dep trust_snapshot --dep trust_snapshot_store \
    -Mtrust_snapshot_ed25519="$root/src/app/trust_snapshot_ed25519.zig" \
    -Mtrust_snapshot_store="$root/src/app/trust_snapshot_store.zig"
"${prefix}size" -A "$out/boot-admission.o" > "$out/size.txt"
"${prefix}nm" -u "$out/boot-admission.o" > "$out/undefined.txt"
"${prefix}readelf" -h -A "$out/boot-admission.o" > "$out/attributes.txt"
python3 - "$out/undefined.txt" "$out/attributes.txt" <<'PY'
import re, sys
from pathlib import Path
undefined={line.split()[-1] for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()}
allowed={'__lshrdi3','memcpy','memset'}
if undefined != allowed:
    raise SystemExit(f'unexpected RV32 imports: {sorted(undefined)}')
attributes=Path(sys.argv[2]).read_text()
if 'soft-float ABI' not in attributes or not re.search(r'Tag_RISCV_arch: "rv32i[^"]*_m[^"]*_a[^"]*_c', attributes):
    raise SystemExit('RV32IMAC soft-float attributes missing')
PY
cat "$out/size.txt"
cat "$out/undefined.txt"
echo 'Boot admission RV32 compile closure: ok'
