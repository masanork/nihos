#!/usr/bin/env python3
"""Bind the optional read-only photo codec to exact C objects and source inputs."""
import hashlib,importlib.util,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('c_manifest',ROOT/'tools/native-sqlite-manifest.py')
C=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(C)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    build=Path(sys.argv[1]);manifest=json.loads((ROOT/'src/graphics/card_read_font.json').read_text())
    automatic='pub const card_auto = true;' in (build/'native_options.zig').read_text()
    probe='pub const card_auto_probe = true;' in (build/'native_options.zig').read_text()
    if automatic:
        manifest=json.loads((ROOT/'src/graphics/card_auto_font.json').read_text())
        manifest['allowed_functions']=[name for name in manifest['allowed_functions'] if not name.startswith('card_read.')]
        manifest['automatic_cards']={'schema':2,'kinds':['mynumber','license','myna_license'],'credential_budget_per_pin':1,'read_enabled':not probe,'notice_scanout':'sram-double-bank-v1','jis_bytes':0 if probe else 17672,'jis_sha256':sha(ROOT/'src/card/jis0208.bin'),'trust_bytes':0 if probe else (ROOT/'src/card/license_trust.bin').stat().st_size,'trust_sha256':sha(ROOT/'src/card/license_trust.bin')}
        if 'pub const card_scene_exercise = true;' in (build/'native_options.zig').read_text():
            manifest['automatic_cards']['scene_exercise']=True
            manifest['allowed_functions']=[name for name in manifest['allowed_functions'] if not name.startswith('usb_probe.Device.')]
    objects={p.name:{'sha256':sha(p),'functions':C.functions(p)} for p in sorted(build.glob('photo_*.o'))}
    source=ROOT/'build/openjpeg/openjpeg-2.5.4/src/lib/openjp2'
    paths=list(source.glob('*.c'))+list(source.glob('*.h'))+list((ROOT/'probes/photo').glob('*'))
    paths += [ROOT/p for p in ('src/card/service.zig','src/card/surface.zig','src/card/wire_policy.zig','src/platform/native/photo_runtime.zig','src/platform/native/display_service.zig','src/platform/native/display_probe.zig','src/graphics/photo_fixture.zig','src/graphics/photo_fixture.jp2','tools/build-native.sh','tools/build-native-elf.sh','tools/build-photo-codec.sh','tools/bootstrap-openjpeg.sh')]
    paths += [ROOT/'src/platform/native/foreground_timer.zig']
    paths += [ROOT/p for p in ('src/platform/native/keypad_display.zig','src/platform/native/display_runtime.zig','src/platform/native/dma_memory.zig', 'src/platform/native/memory.zig', 'src/platform/native/base_sram.c','src/platform/native/sram_pool.h','src/platform/native/esp32p4.ld')]
    if automatic:
        paths += [ROOT/p for p in ('src/board/tab5/notice_sparse.h','src/board/tab5/native_scanout.c','src/board/tab5/keypad_sparse.h','src/board/tab5/scene_pixels.h','tools/build-native-elf.sh')]
        paths += [ROOT/p for p in ('src/card/license.zig','src/card/jis0208.zig','src/card/jis0208.bin','src/card/jis0208.json','src/card/presence.zig','src/card/ccid_owner.zig','src/card/pin_entry.zig','src/platform/native/card_auto.zig','src/platform/native/main.zig','src/graphics/card_read_result.zig')]
    if automatic:
        paths += [ROOT/p for p in ('src/card/license_session.zig','src/card/license_record.zig','src/card/license_crypto.zig','src/card/license_trust.zig','src/card/license_trust.bin','src/card/license_trust.json','src/card/fixtures/license-rsa.bin','probes/card_crypto/link.zig','probes/card_crypto/stack.S')]
    for p in paths:
        if p.is_file():manifest['sources'][str(p.relative_to(ROOT))]=sha(p)
    manifest['allowed_functions'] += ['photo_runtime.prepare'] + ([] if probe else ['photo_runtime.decode']) + ['photo_runtime.close']
    if automatic and not probe:
        crypto={p.name:{'sha256':sha(p),'functions':C.functions(p)} for p in (build/'card_crypto.o',build/'card_crypto_stack.o')}
        manifest['license_crypto']={'profile':'npa-raw-sha256-v1_5','bits':2048,'exponents':[3,65537],'stack_bytes':65536,'external_stack':True,'objects':crypto,'allowed_functions':sorted(set().union(*(set(obj['functions']) for obj in crypto.values())))}
    manifest['codec']={'name':'OpenJPEG','version':'2.5.4','archive_sha256':'a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a',
        'decode_only':True,'threads':False,'io':False,'htj2k':False,'objects':objects,
        'allowed_functions':sorted(set().union(*(set(obj['functions']) for obj in objects.values()))),
        'workspace_bytes':4*1024*1024-128,'stack_low':'0x4ff68000','stack_high':'0x4ff6b000',
        'fixture_sha256':sha(ROOT/'src/graphics/photo_fixture.jp2')}
    (build/'photo-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
if __name__=='__main__':main()
