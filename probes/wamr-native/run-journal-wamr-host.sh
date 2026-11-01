#!/bin/sh
# Rust -> signed journals -> fresh admission process -> WAMR host execution.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/journal-wamr-host"
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
wamr="$root/build/wamr-2.4.5"
[ "$(git -C "$wamr" rev-parse HEAD)" = 25bd7eb63e828e4bd242cc9b38d260b4b31c6605 ]
[ -z "$(git -C "$wamr" status --porcelain)" ]
mkdir -p "$out"
RUSTFLAGS='-C link-arg=-zstack-size=16384 -C link-arg=--initial-memory=65536 -C link-arg=--max-memory=65536' \
    CARGO_TARGET_DIR="$out/rust-target" cargo build --locked --release \
    --target wasm32-unknown-unknown --manifest-path "$root/probes/rust-wasm/Cargo.toml"
cp "$out/rust-target/wasm32-unknown-unknown/release/nihos_rust_wasm_probe.wasm" "$out/app.wasm"
build_fixture() {
    "$zig" build-exe -lc -O ReleaseSafe -femit-bin="$out/$1" \
        --dep process_adapter --dep app_boot --dep app_install --dep app_package --dep app_policy --dep package_ed25519 --dep trust_snapshot --dep trust_snapshot_ed25519 --dep trust_snapshot_store \
        -Mroot="$root/probes/wamr-native/$2" \
        --dep app_boot --dep app_install --dep app_package --dep app_policy --dep package_ed25519 --dep trust_snapshot --dep trust_snapshot_ed25519 --dep trust_snapshot_store \
        -Mprocess_adapter="$root/probes/wamr-native/package-process.zig" \
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
}
build_fixture package-pack package-ed25519-pack.zig
build_fixture media-pack boot-media-pack.zig
build_fixture boot-export boot-file-export.zig
"$zig" build-lib -static -fPIC -O ReleaseSafe -lc -fcompiler-rt \
    -femit-bin="$out/libboot-admission.a" \
    --dep app_boot --dep app_install --dep app_package --dep app_policy --dep package_ed25519 --dep trust_snapshot_ed25519 --dep trust_snapshot_store \
    -Mroot="$root/probes/wamr-native/boot-buffer-host.zig" \
    --dep app_install --dep app_policy --dep package_ed25519 --dep trust_snapshot --dep trust_snapshot_ed25519 --dep trust_snapshot_store \
    -fPIC -Mapp_boot="$root/src/app/boot_admission.zig" \
    --dep app_package --dep app_policy -fPIC -Mapp_install="$root/src/app/package_install.zig" \
    --dep app_policy -fPIC -Mapp_package="$root/src/app/package.zig" \
    -fPIC -Mapp_policy="$root/src/app/module_policy.zig" \
    --dep app_package -fPIC -Mpackage_ed25519="$root/src/app/package_ed25519.zig" \
    --dep app_package -fPIC -Mtrust_snapshot="$root/src/app/trust_snapshot.zig" \
    --dep app_package --dep package_ed25519 --dep trust_snapshot --dep trust_snapshot_store \
    -fPIC -Mtrust_snapshot_ed25519="$root/src/app/trust_snapshot_ed25519.zig" \
    -fPIC -Mtrust_snapshot_store="$root/src/app/trust_snapshot_store.zig"
"$out/package-pack" "$out/app.wasm" "$out/app.nihpkg"
"$out/media-pack" "$out/app.nihpkg" "$out/trust.bin" "$out/package.bin" \
    "$out/counter.bin" "$out/root.pub"
"$out/boot-export" "$out/trust.bin" "$out/counter.bin" "$out/package.bin" \
    "$out/root.pub" "$out/admitted.wasm" 1 > "$out/admission.log" 2>&1
cmp "$out/app.wasm" "$out/admitted.wasm"
cmake -S "$root/probes/wamr-host" -B "$root/build/wamr-host" \
    -DWAMR_ROOT_DIR="$wamr" -DNIHOS_BOOT_LIBRARY="$out/libboot-admission.a" \
    -DCMAKE_BUILD_TYPE=Release > "$out/runtime-build.log" 2>&1
cmake --build "$root/build/wamr-host" --parallel 4 >> "$out/runtime-build.log" 2>&1
"$root/build/wamr-host/nihos-wamr-host" "$out/admitted.wasm" 262144 fixed-memory \
    > "$out/runtime.log" 2>&1
"$root/build/wamr-host/nihos-wamr-journal" "$out/trust.bin" "$out/counter.bin" \
    "$out/package.bin" "$out/root.pub" > "$out/direct-runtime.log" 2>&1
python3 - "$out" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1])
data=bytearray((out/'package.bin').read_bytes())
data[144] ^= 1
(out/'corrupt-package.bin').write_bytes(data)
(out/'wrong-root.pub').write_bytes(bytes(32))
(out/'unsealed-counter.bin').write_bytes(bytes(8))
for name in ('rejected-corrupt.wasm','rejected-root.wasm'):
    (out/name).unlink(missing_ok=True)
PY
if "$out/boot-export" "$out/trust.bin" "$out/counter.bin" "$out/corrupt-package.bin" \
    "$out/root.pub" "$out/rejected-corrupt.wasm" 1 > "$out/rejected-corrupt.log" 2>&1; then
    echo "damaged journal unexpectedly exported" >&2; exit 1
fi
if "$out/boot-export" "$out/trust.bin" "$out/counter.bin" "$out/package.bin" \
    "$out/wrong-root.pub" "$out/rejected-root.wasm" 1 > "$out/rejected-root.log" 2>&1; then
    echo "wrong root unexpectedly exported" >&2; exit 1
fi
[ ! -e "$out/rejected-corrupt.wasm" ] && [ ! -e "$out/rejected-root.wasm" ]
for kind in corrupt root unsealed denied; do
    media="$out/package.bin"
    key="$out/root.pub"
    counter_media="$out/counter.bin"
    case "$kind" in
        corrupt) media="$out/corrupt-package.bin" ;;
        root) key="$out/wrong-root.pub" ;;
        unsealed) counter_media="$out/unsealed-counter.bin" ;;
    esac
    direct_status=0
    if [ "$kind" = denied ]; then
        "$root/build/wamr-host/nihos-wamr-journal" "$out/trust.bin" "$counter_media" \
            "$media" "$key" deny-graphics > "$out/direct-rejected-$kind.log" 2>&1 || direct_status=$?
    else
        "$root/build/wamr-host/nihos-wamr-journal" "$out/trust.bin" "$counter_media" \
            "$media" "$key" > "$out/direct-rejected-$kind.log" 2>&1 || direct_status=$?
    fi
    [ "$direct_status" -eq 20 ] || { echo "expected direct admission rejection, got $direct_status" >&2; exit 1; }
done
python3 - "$out" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1])
assert (out/'rejected-corrupt.log').read_text().strip() == 'error: ActivePackageInvalid'
assert (out/'rejected-root.log').read_text().strip() == 'error: InvalidActiveSnapshot'
runtime=(out/'runtime.log').read_text()
for marker in ('WAMR fixed-memory growth rejection: ok',
               'WAMR 16 trap/destroy cycles returned runtime pool to baseline: ok',
               'WAMR classic interpreter Rust app and bounds: ok'):
    assert marker in runtime, marker
direct=(out/'direct-runtime.log').read_text()
wasm_bytes=len((out/'app.wasm').read_bytes())
assert f'NIHOS_BOOT_BUFFER status=0 wasm_bytes={wasm_bytes} services=1' in direct
assert 'NIHOS_IMPORT_OWNER denied_service=1 inactive=1 mismatched=1 detached=1 calls=0 effective_services=1' in direct
assert 'WAMR classic interpreter Rust app and bounds: ok' in direct
for kind in ('corrupt','root','unsealed','denied'):
    rejected=(out/f'direct-rejected-{kind}.log').read_text()
    assert rejected.strip() == 'NIHOS_BOOT_BUFFER status=2 wasm_bytes=0 services=0'
PY
shasum -a 256 "$out/app.wasm" "$out/app.nihpkg" "$out/trust.bin" \
    "$out/package.bin" "$out/counter.bin" "$out/root.pub" "$out/admitted.wasm" \
    "$out/libboot-admission.a" "$root/build/wamr-host/nihos-wamr-journal" \
    > "$out/artifacts-sha256.txt"
cat "$out/admission.log" "$out/runtime.log" "$out/direct-runtime.log"
echo 'Rust journal -> boot admission -> WAMR host: ok; damaged package/wrong root emit no payload'
