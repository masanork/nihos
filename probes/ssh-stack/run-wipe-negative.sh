#!/bin/sh
# Negative control: deliberately release the test stack too soon. Never flash.
set -eu
: "${NIHOS_EMU:?set NIHOS_EMU to ESP-EMU 0.50.0}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${ZIG:-"$root/.tools/zig-0.17.0/zig"}
tool_root=${NIHOS_TOOLS_ROOT:-"$root/.tools"}
[ -x "$zig" ] && [ -d "$tool_root" ] && [ "$("$zig" version)" = 0.17.0 ]
"$NIHOS_EMU" --version | grep -q 'esp-emu 0.50.0'
mkdir -p "$root/build"
out=$(mktemp -d "$root/build/ssh-stack-wipe-negative.XXXXXX")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nihos-ssh-stack-wipe-negative.XXXXXX")
cleanup() {
    if [ -f "$tmp/tree/.git" ]; then git -C "$root" worktree remove --force "$tmp/tree"; fi
    rmdir "$tmp" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
git -C "$root" worktree add --detach "$tmp/tree" HEAD
ln -s "$tool_root" "$tmp/tree/.tools"
git -C "$tmp/tree" apply --unidiff-zero "$root/probes/ssh-stack/emulator-fixture.patch"
python3 - "$tmp/tree/src/platform/native/ssh_foreground_stack.zig" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); text = p.read_text()
old = '    std.crypto.secureZero(u8, stack[16..]);\n    // The real admission gate must still reject reentry after the wipe.'
new = '    tasks.memory.stacks.endForeground(); // deliberate negative control\n' + old
if text.count(old) != 1: raise SystemExit('negative control insertion point differs')
p.write_text(text.replace(old, new))
PY
(
    cd "$tmp/tree"
    ZIG="$zig" NIHOS_NATIVE_BOOT_TEST=1 sh tools/build-native.sh emulator > "$out/build.log" 2>&1
    image=build/native-emulator
    "$NIHOS_EMU" --chip esp32p4 --firmware "$image/nihos-native-flash.bin" --elf "$image/nihos-native.elf" \
        --psram-size 8M --timeout 45s --exit-on NIHOS_NATIVE_TASK_FAIL > "$out/emulator.log" 2>&1
    python3 - "$image" "$out" "$root/probes/ssh-stack/emulator-fixture.patch" <<'PY'
import hashlib, json, pathlib, subprocess, sys
image, out, patch = map(pathlib.Path, sys.argv[1:])
log = (out / 'emulator.log').read_text()
if 'NIHOS_NATIVE_NORMAL_READY' not in log or 'NIHOS_NATIVE_TASK_FAIL caller=' not in log or 'NIHOS_SSH_STACK_FIXTURE_PASS' in log:
    raise SystemExit('early-release negative control did not trigger the expected rejection')
audit = json.loads((image / 'image-audit.json').read_text())
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
if digest(image / 'nihos-native.elf') != audit['elf_sha256'] or digest(image / 'nihos-native.bin') != audit['image_sha256']:
    raise SystemExit('fixture image digest differs from audit')
result = {'profile': 'headless ESP-EMU 0.50.0; deliberate early release; no SSH',
          'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'fixture_patch_sha256': digest(patch), 'elf_sha256': audit['elf_sha256'],
          'image_sha256': audit['image_sha256'], 'emulator_log_sha256': digest(out / 'emulator.log'),
          'expected': 'foreground gate rejected early release'}
(out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, sort_keys=True))
PY
)
printf 'Evidence: %s\n' "$out"
