#!/bin/sh
# Host-only multi-process persistence probe; not device or cold-power evidence.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
out="$root/build/package-process"
zig=${NIHOS_ZIG:-"$root/.tools/zig-0.17.0/zig"}
mkdir -p "$out"
rm -f "$out/trust.bin" "$out/counter.bin" "$out/package.bin" "$out/process.log"
"$zig" build-exe -O ReleaseSafe -femit-bin="$out/package-process" \
    --dep app_boot --dep app_install --dep app_package --dep app_policy --dep package_ed25519 --dep trust_snapshot --dep trust_snapshot_ed25519 --dep trust_snapshot_store \
    -Mroot="$root/probes/wamr-native/package-process.zig" \
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
for phase in provision interrupt recover-old install recover-new; do
    if [ "$phase" = interrupt ]; then
        python3 "$root/probes/wamr-native/kill-package-process.py" \
            "$out/package-process" "$out/trust.bin" "$out/counter.bin" \
            "$out/package.bin" "$out/kill-status.txt" >> "$out/process.log" 2>&1
    else
        "$out/package-process" "$phase" "$out/trust.bin" "$out/counter.bin" \
            "$out/package.bin" >> "$out/process.log" 2>&1
    fi
    if [ "$phase" = provision ]; then cp "$out/package.bin" "$out/package-sequence1.bin"; fi
done
python3 "$root/probes/wamr-native/run-kill-matrix.py" "$out"
python3 "$root/probes/wamr-native/run-corruption-controls.py" "$out"
cp "$out/trust.bin" "$out/trust-epoch1.bin"
for phase in interrupt-trust reject-unsealed seal-revoked; do
    phase_status=0
    "$out/package-process" "$phase" "$out/trust.bin" "$out/counter.bin" \
        "$out/package.bin" >> "$out/process.log" 2>&1 || phase_status=$?
    if [ "$phase" = interrupt-trust ]; then
        [ "$phase_status" -eq 86 ] || { echo "expected immediate exit 86, got $phase_status" >&2; exit 1; }
        echo "interrupt-trust exit_status=$phase_status" > "$out/termination-status.txt"
        cp "$out/counter.bin" "$out/counter-lagging.bin"
        cp "$out/trust.bin" "$out/trust-committed.bin"
    else
        [ "$phase_status" -eq 0 ] || exit "$phase_status"
    fi
done
cmp "$out/trust-committed.bin" "$out/trust.bin"
shasum -a 256 "$out/trust.bin" "$out/counter.bin" "$out/package.bin" \
    > "$out/rejection-before-sha256.txt"
"$out/package-process" reject-revoked "$out/trust.bin" "$out/counter.bin" \
    "$out/package.bin" >> "$out/process.log" 2>&1
shasum -a 256 "$out/trust.bin" "$out/counter.bin" "$out/package.bin" \
    > "$out/rejection-after-sha256.txt"
cmp "$out/rejection-before-sha256.txt" "$out/rejection-after-sha256.txt"
"$out/package-process" reject-rollback "$out/trust-epoch1.bin" "$out/counter.bin" \
    "$out/package.bin" >> "$out/process.log" 2>&1
python3 - "$out/process.log" <<'PY'
import re, sys
from pathlib import Path
lines=Path(sys.argv[1]).read_text().splitlines()
phases=[]
pids=[]
for line in lines:
    match=re.fullmatch(r'NIHOS_BOOT_PROCESS phase=([^ ]+) .* pid=([0-9]+)',line)
    if match:
        phases.append(match.group(1))
        pids.append(match.group(2))
expected=['provision','interrupt','recover-old','install','recover-new',
          'interrupt-trust','reject-unsealed','seal-revoked',
          'reject-revoked','reject-rollback']
if phases != expected or len(set(pids)) != len(expected):
    raise SystemExit(f'process-boundary evidence differs: phases={phases} pids={pids}')
if 'abrupt_exit=86' not in lines[5]:
    raise SystemExit('immediate process exit marker missing')
if 'await_sigkill=1' not in lines[1]:
    raise SystemExit('parent-kill checkpoint missing')
print('boot admission process-boundary fixture: ok')
PY
shasum -a 256 "$out/trust.bin" "$out/trust-epoch1.bin" "$out/counter.bin" \
    "$out/counter-lagging.bin" "$out/package.bin" \
    > "$out/media-sha256.txt"
cat "$out/process.log"
