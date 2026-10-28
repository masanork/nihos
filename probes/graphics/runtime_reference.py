#!/usr/bin/env python3
"""Independent post-edit host shaping and all four composition references."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

SURFACE = module('surface_ref', 'surface_reference.py')
KIN = module('kinsoku_ref', 'kinsoku_reference.py')
RUBY = module('ruby_ref', 'ruby_reference.py')


def render_hash(case):
    value = 2166136261
    for word in [case[k] for k in ('font','pixels','vertical','hinting')] + [len(case['body'].encode()),len(case['ruby'].encode())]:
        value = ((value ^ word) * 16777619) & 0xffffffff
    for byte in (case['body'] + case['ruby']).encode():
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def main():
    output = Path(sys.argv[1]); output.mkdir(parents=True, exist_ok=True)
    host_path = ROOT/'build/runtime-text-host/result.json'
    host = json.loads(host_path.read_text()); assert host['rc'] == 0
    cases_path = ROOT/'probes/graphics/runtime_text_cases.json'
    annotations_path = ROOT/'probes/graphics/runtime_ruby_cases.json'
    cases = json.loads(cases_path.read_text()); annotations = json.loads(annotations_path.read_text())
    frames, inputs = [], {}
    for text in host['texts']:
        index = text['id'] - 5; case = cases[index]
        text['source_hash'] = render_hash(case)
        if text['outcome']: continue
        mask_path = ROOT/f'build/runtime-text-host/raster-{text["id"]}.bin'
        masks = mask_path.read_bytes()
        assert len(masks) == text['pixel_bytes'] and SURFACE.fnv(masks) == text['pixel_hash']
        fixed, fixed_clip = SURFACE.compose(text,masks)
        wrapped, wrap_clip = SURFACE.compose(text,masks,True)
        _, wrap_stats = SURFACE.wrapped_positions(text)
        source = case['body'],case['ruby']
        kp, ks = KIN.plan(text,source); kimage,kclip = KIN.compose(text,masks,kp)
        _, naive_stats = KIN.plan(text,source,prohibit=False)
        vertical = text['id'] == 8
        step = 40 if vertical or text['id'] == 5 else 32
        rp,logical,rs = RUBY.plan(text,source,annotations[index],(96 if text['id'] != 9 else 80)*64,step*64,4 if vertical else 3,(32 if vertical else 48 if text['id'] == 5 else 0)*64,26*64)
        if text['id'] == 5: rp={i:(x,y+14) for i,(x,y) in rp.items()}
        rimage,rclip = KIN.compose(text,masks,rp)
        control_positions=dict(rp); px=py=0
        for i,g in enumerate(text['glyphs']):
            if g['run'] != 1:continue
            ox,oy=(178,8) if vertical else (8,18)
            control_positions[i]=(ox+(px+g['x_offset'])//64+g['left'],oy-(py+g['y_offset'])//64-g['top'])
            px+=g['x_advance'];py+=g['y_advance']
        control,_=KIN.compose(text,masks,control_positions)
        frames.append(dict(id=text['id'],surface_hash=SURFACE.fnv(fixed),wrap_hash=SURFACE.fnv(wrapped),policy_hash=SURFACE.fnv(kimage),ruby_hash=SURFACE.fnv(rimage),
                           control_hash=SURFACE.fnv(control), groups=rs["groups"], moved=rs["moved"], naive_forbidden_starts=naive_stats["forbidden_starts"], forbidden_starts=ks["forbidden_starts"],forbidden_ends=ks["forbidden_ends"], surface_clipped=fixed_clip,wrap_clipped=wrap_clip,policy_clipped=kclip,ruby_clipped=rclip,wrap_stats=wrap_stats,policy_stats=ks,ruby_stats=rs,
                           logical=[dict(index=i,inline_offset=p[0],block_offset=p[1]) for i,p in sorted(logical.items())]))
        for name,data in [('surface',fixed),('wrap',wrapped),('kinsoku',kimage),('ruby',rimage)]:
            (output/f'{name}-{text["id"]}.rgb565').write_bytes(data)
            (output/f'{name}-{text["id"]}.png').write_bytes(SURFACE.png(data))
        inputs[str(mask_path.relative_to(ROOT))] = hashlib.sha256(masks).hexdigest()
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    result=dict(schema=1,status='pass',evidence='sanitized host shaping and independent batch/per-source-pixel composition, not native display',texts=host['texts'],frames=frames,matrix_hashes=host['matrix_hashes'],
                cases_sha256=sha(cases_path),annotations_sha256=sha(annotations_path),input_cases_sha256=sha(ROOT/'probes/graphics/text_cases.json'),input_annotations_sha256=sha(ROOT/'probes/graphics/ruby_cases.json'),
                sources_sha256={str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__).resolve(),Path(SURFACE.__file__),Path(KIN.__file__),Path(RUBY.__file__)]},
                host_result_sha256=sha(host_path),input_rasters_sha256=inputs,
                text_edit='first source body changed at runtime from 日本語の描画 to 新日本語; ruby parent 0..9 -> 3..12')
    (output/'reference.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    print([{k:v for k,v in frame.items() if k not in ('logical','wrap_stats','policy_stats','ruby_stats')} for frame in frames])

if __name__ == '__main__':main()
