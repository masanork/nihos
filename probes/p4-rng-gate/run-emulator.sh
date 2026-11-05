#!/bin/sh
# Safe, non-secret P4 RNG gate fixture. Never flash the generated image.
set -eu
: "${NIHOS_EMU:?set NIHOS_EMU to ESP-EMU 0.50.0}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${ZIG:-"$root/.tools/zig-0.17.0/zig"}
tool_root=${NIHOS_TOOLS_ROOT:-"$root/.tools"}
[ -x "$zig" ] && [ -d "$tool_root" ]
[ "$($zig version)" = 0.17.0 ]
"$NIHOS_EMU" --version | grep -q "esp-emu 0.50.0"
mkdir -p "$root/build"
out=$(mktemp -d "$root/build/p4-rng-gate-fixture.XXXXXX")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nihos-p4-rng-gate-fixture.XXXXXX")
cleanup() {
    if [ -f "$tmp/tree/.git" ]; then git -C "$root" worktree remove --force "$tmp/tree"; fi
    rmdir "$tmp" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
git -C "$root" worktree add --detach "$tmp/tree" HEAD
ln -s "$tool_root" "$tmp/tree/.tools"
git -C "$tmp/tree" apply --unidiff-zero "$root/probes/p4-rng-gate/emulator-fixture.patch"
(
    cd "$tmp/tree"
    ZIG="$zig" NIHOS_NATIVE_BOOT_TEST=1 sh tools/build-native.sh emulator > "$out/build.log" 2>&1
    image=build/native-emulator
    "$NIHOS_EMU" --chip esp32p4 --firmware "$image/nihos-native-flash.bin" --elf "$image/nihos-native.elf" \
        --psram-size 8M --timeout 45s --exit-on NIHOS_RNG_GATE_FIXTURE_PASS > "$out/emulator.log" 2>&1
    python3 - "$image" "$out" "$root/probes/p4-rng-gate/emulator-fixture.patch" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
image, out, patch = map(pathlib.Path, sys.argv[1:])
log = (out / 'emulator.log').read_text()
if 'NIHOS_NATIVE_NORMAL_READY' not in log or 'NIHOS_RNG_GATE_FIXTURE_PASS' not in log:
    raise SystemExit('fixture did not reach its success marker')
if any(x in log for x in ('NIHOS_NATIVE_FAIL', 'NIHOS_NATIVE_PANIC', 'NIHOS_NATIVE_TRAP')):
    raise SystemExit('native failure marker in fixture log')
audit = json.loads((image / 'image-audit.json').read_text())
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
if digest(image / 'nihos-native.elf') != audit['elf_sha256'] or digest(image / 'nihos-native.bin') != audit['image_sha256']:
    raise SystemExit('fixture image digest differs from audit')
result = {'profile': 'headless ESP-EMU 0.50.0; single-core gate; no hardware entropy',
          'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'emulator_sha256': digest(pathlib.Path(os.environ['NIHOS_EMU'])),
          'fixture_patch_sha256': digest(patch), 'elf_sha256': audit['elf_sha256'],
          'image_sha256': audit['image_sha256'], 'heap_bytes': audit['heap']['bytes'],
          'emulator_log_sha256': digest(out / 'emulator.log'),
          'checks': ['SQLite and entropy gate exclusion', 'stale token rejection', 'release and reacquisition']}
(out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, sort_keys=True))
PY
    # Preserve the exact audited fixture objects; never flash the test image.
    cp "$image/nihos-native.elf" "$out/fixture-do-not-flash.elf"
    cp "$image/nihos-native.bin" "$out/fixture-do-not-flash.bin"
    cp "$image/image-audit.json" "$out/image-audit.json"
)
printf 'Evidence: %s\n' "$out"
