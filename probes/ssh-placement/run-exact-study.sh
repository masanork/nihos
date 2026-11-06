#!/bin/sh
# Link-only study; images are invalid and must never be executed or flashed.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
tool_root=${NIHOS_TOOLS_ROOT:-"$root/.tools"}
zig=${ZIG:-"$tool_root/zig-0.17.0/zig"}
[ -x "$zig" ] && [ "$("$zig" version)" = 0.17.0 ]
mkdir -p "$root/build"
out=$(mktemp -d "$root/build/ssh-exact-placement-study.XXXXXX")
temp_root=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
tmp=$(mktemp -d "$temp_root/nihos-ssh-exact-placement.XXXXXX")
cleanup() {
    if [ -f "$tmp/tree/.git" ]; then git -C "$root" worktree remove --force "$tmp/tree"; fi
    rmdir "$tmp" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
git -C "$root" worktree add --detach "$tmp/tree" HEAD
ln -s "$tool_root" "$tmp/tree/.tools"
git -C "$tmp/tree" apply "$root/probes/ssh-placement/exact-link-only.patch"
(
    cd "$tmp/tree"
    ZIG="$zig" NIHOS_NATIVE_EXPERIMENTAL_TCP=1 sh tools/build-native.sh device integer > "$out/build.log" 2>&1
    grep -q 'Study-only exact function audit passed: 104 functions;' "$out/build.log"
    dir=build/native-device-network-tcp-experiment-devices-camera-sqld
    image="$dir/nihos-native.elf"
    if python3 tools/check-native-image.py "$image" "$dir/nihos-native.bin" "$out/standard-audit.json" integer device \
        "$dir/loader/bootloader/bootloader.elf" "$dir/loader/config/sdkconfig.h" \
        --normal-fs "$dir/normal-fs-manifest.json" --sqld "$dir/sqld-manifest.json" > "$out/standard-audit.log" 2>&1; then
        echo 'Study unexpectedly passed the unmodified standard audit' >&2
        exit 1
    fi
    grep -q 'Native image audit failed: unapproved xy Flash function:' "$out/standard-audit.log"
    cp "$dir/image-audit.json" "$out/study-audit.json"
    python3 "$root/probes/ssh-placement/test-audit-negative.py" "$image" > "$out/negative-controls.log"
    if [ -n "${NIHOS_OBJDUMP:-}" ]; then
        python3 "$root/probes/ssh-placement/inspect-irq-edges.py" "$NIHOS_OBJDUMP" "$image" "$out/irq-edges.json" > "$out/irq-summary.log"
    fi
    python3 "$root/tools/audit-ssh-ed25519-table.py" "$image" --require-flash > "$out/table-audit.json"
    python3 - "$image" "$out" "$root/probes/ssh-placement/exact-link-only.patch" <<'PY'
import hashlib, json, pathlib, struct, subprocess, sys
image, out, patch = map(pathlib.Path, sys.argv[1:])
b = image.read_bytes()
h = struct.unpack_from('<16sHHIIIIIHHHHHH', b)
if h[0][:6] != b'\x7fELF\x01\x01': raise SystemExit('expected ELF32')
sections = [struct.unpack_from('<10I', b, h[6] + i*h[11]) for i in range(h[12])]
symbols = {}
for sec in sections:
    if sec[1] != 2: continue
    st = sections[sec[6]]; strings = b[st[4]:st[4]+st[5]]
    for off in range(sec[4], sec[4]+sec[5], sec[9]):
        n, value, _, _, _, _ = struct.unpack_from('<IIIBBH', b, off)
        end = strings.find(b'\0', n)
        if end < 0: raise SystemExit('invalid ELF symbol')
        name = strings[n:end].decode('utf-8', 'replace')
        if name in ('__heap_start', '__heap_end'): symbols[name] = value
if set(symbols) != {'__heap_start', '__heap_end'} or symbols['__heap_end'] != 0x4ff28000:
    raise SystemExit('unexpected heap layout')
heap = symbols['__heap_end'] - symbols['__heap_start']
if heap < 49152: raise SystemExit('study heap below the unchanged 48 KiB floor')
result = {'profile': 'link-only; entropy unavailable; do not flash or execute',
          'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'fixture_patch_sha256': hashlib.sha256(patch.read_bytes()).hexdigest(),
          'elf_sha256': hashlib.sha256(b).hexdigest(), 'heap_bytes': heap,
          'normal_audit': 'rejected unapproved xy Flash functions',
          'study_audit': 'exact function names and structural image checks passed; not cache-off qualification',
          'negative_controls': 'misplaced function and full SRAM code copy rejected',
          'table_audit': json.loads((out / 'table-audit.json').read_text())}
irq = out / 'irq-edges.json'
if irq.exists():
    graph = json.loads(irq.read_text())
    result['irq_graph'] = {key: graph[key] for key in ('directly_reachable_functions', 'directly_reachable_ssh_crypto_names', 'directly_reachable_placed_functions', 'unresolved_indirect_count', 'possible_jump_table_hints', 'limitations')}
    result['irq_graph_sha256'] = hashlib.sha256(irq.read_bytes()).hexdigest()
(out / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, sort_keys=True))
PY
)
printf 'Study report: %s\n' "$out"
