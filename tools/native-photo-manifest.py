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
    objects={p.name:{'sha256':sha(p),'functions':C.functions(p)} for p in sorted(build.glob('photo_*.o'))}
    source=ROOT/'build/openjpeg/openjpeg-2.5.4/src/lib/openjp2'
    paths=list(source.glob('*.c'))+list(source.glob('*.h'))+list((ROOT/'probes/photo').glob('*'))
    paths += [ROOT/p for p in ('src/card/service.zig','src/card/surface.zig','src/card/wire_policy.zig','src/platform/native/photo_runtime.zig','src/graphics/photo_fixture.zig','src/graphics/photo_fixture.jp2','tools/build-photo-codec.sh','tools/bootstrap-openjpeg.sh')]
    for p in paths:
        if p.is_file():manifest['sources'][str(p.relative_to(ROOT))]=sha(p)
    manifest['allowed_functions'] += ['photo_runtime.prepare','photo_runtime.decode','photo_runtime.close']
    manifest['codec']={'name':'OpenJPEG','version':'2.5.4','archive_sha256':'a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a',
        'decode_only':True,'threads':False,'io':False,'htj2k':False,'objects':objects,
        'allowed_functions':sorted(set().union(*(set(obj['functions']) for obj in objects.values()))),
        'workspace_bytes':4*1024*1024-128,'stack_low':'0x4ff68000','stack_high':'0x4ff6b000',
        'fixture_sha256':sha(ROOT/'src/graphics/photo_fixture.jp2')}
    (build/'photo-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
if __name__=='__main__':main()
