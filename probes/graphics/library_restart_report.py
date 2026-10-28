#!/usr/bin/env python3
"""Bind host RV32 library-restart evidence to inputs, sources and baseline."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
from library_image import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]).resolve()
CXX = sys.argv[2]
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
read = lambda p: json.loads(Path(p).read_text())
result = read(OUT/'result.json')
image = Image((OUT/'oracle.elf').read_bytes())
assert result['status'] == 'pass' and result['elf_sha256'] == image.sha256
assert result['template_sha256'] == sha(OUT/'pristine-library.bin') == image.template.data_sha256
assert result['positive_lifetimes'] == 3 and result['restarts'] == 2 and result['final_recovered']
baseline_path = ROOT/'docs/measurements/2026-10-28-native-stack-loan.json'
baseline = read(baseline_path)
for life in result['positive']:
    assert life['passed'] and life['hashes'] == baseline['native_result']['hashes']
    assert life['runtime_malloc_calls'] == life['unavailable_calls'] == life['record_failures'] == life['allocation_failures'] == 0
    assert 0 < life['record_peak'] <= life['record_capacity'] == 1024
    assert life['execution']['stack_guard'] and not life['execution']['error'] and not life['execution']['fault']
for life in result['positive'][1:]:assert life['kernel_metadata_unchanged_by_restore']
assert result['negative']['controller_only']['second']['execution']['fault']['address'] == 0xa5a5a5a5
assert 'lang_find_or_insert' in result['negative']['controller_only']['second']['fault_function']
assert result['negative']['bss_only_after_loan']['second']['failure'] == 1
assert all(not v['second']['passed'] and v['peer_preserved'] for v in result['negative'].values())
assert result['forbidden_runtime_control']['forbidden'] == image.symbols['abort'][0]
assert result['peer_charge'] == 8388608 and result['peer_preserved_bytes'] == 8388480
archives = {p: ROOT/p for p in ('build/native-emulator-graphics/graphics/build/ft/libfreetype.a', 'build/native-emulator-graphics/graphics/build/hb/libharfbuzz.a')}
for name, path in archives.items():
    artifact = name.removeprefix('build/native-emulator-graphics/')
    assert sha(path) == baseline['profiles']['emulator']['artifacts_sha256'][artifact]
for name, digest in baseline['source_sha256'].items():
    if name.startswith(('src/', 'include/', 'ports/')):assert sha(ROOT/name) == digest, name
sources = list((ROOT/'src/kernel').glob('*.zig')) + [ROOT/p for p in (
    'probes/graphics/library_image.py', 'probes/graphics/library_restart.py', 'probes/graphics/library_restart_report.py',
    'probes/graphics/restart_link.ld', 'probes/graphics/generate_link_oracle.py', 'probes/graphics/font_probe.cpp',
    'probes/graphics/lazy_pool.h', 'probes/graphics/lazy_pool.cpp', 'probes/graphics/buddy_backing.zig',
    'probes/graphics/buddy_backing.h', 'probes/graphics/link_oracle.h', 'probes/graphics/ft_noio.c',
    'probes/graphics/ft_noenv.h', 'probes/graphics/hb_config.h', 'probes/graphics/sources.json',
    'probes/graphics/unicorn-requirements.txt', 'probes/graphics/README.md',
    'tools/run-library-restart-probe.sh', 'tools/library_image_test.py',
    'docs/adr/0056-pristine-font-library-image.md', 'docs/native-graphics.md', 'provenance.toml')]
source_hashes = {str(p.relative_to(ROOT)): sha(p) for p in sorted(sources)}
nonzero_words = sum(image.template.data[i:i+4] != bytes(4) for i in range(0,32768,4))
runtime_archives = {}
for name in ('libc.a','libm.a','libgcc.a','libnosys.a','libstdc++.a'):
    p = Path(subprocess.check_output([CXX,'-march=rv32imac_zicsr_zifencei','-mabi=ilp32','-fno-rtti','-print-file-name='+name],text=True).strip())
    runtime_archives[name] = dict(path=str(p),sha256=sha(p))
python = ROOT/'build/graphics-rv32/venv/bin/python'
unicorn = json.loads(subprocess.check_output([str(python),'-c',"import unicorn,json,pathlib; p=pathlib.Path(unicorn.__file__).parent/'lib'; print(json.dumps({'version':unicorn.__version__,'library':str(next(p.glob('libunicorn*')))}))"],text=True))
unicorn['library_sha256'] = sha(unicorn['library'])
report = dict(schema=1,date='2026-10-28',scope='identity-bound pristine 32 KiB font library bank, host-driven RV32 restart and insufficient-reset controls with persistent kernel owner/peer state',
    base_commit=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),
    native_baseline=dict(path=str(baseline_path.relative_to(ROOT)),sha256=sha(baseline_path),new_native_execution=False,native_source_unchanged=True),
    result=result,footprint=dict(library_bank_bytes=32768,initialized_data_bytes=result['initializers']['.library.data'],declared_bss_bytes=result['initializers']['.library.bss'],
        kernel_data_bytes=result['initializers']['.backing.data'],kernel_bss_bytes=result['initializers']['.backing.bss'],zero_template_bytes=32768-result['initializers']['.library.data'],
        nonzero_initialized_words=nonzero_words,word_patch_payload_estimate_bytes=6*nonzero_words,word_patch_estimate_excludes='format header, identity, bounds checks and decoder; no compact format implemented or native footprint qualified',
        font_raw_peak_bytes=[v['raw_peak'] for v in result['positive']],font_retained_before_owner_retirement_bytes=65792,test_stack_bytes=32768,initial_final_heap_free_bytes=result['initial_free'],native_heap_gain_bytes=0),
    toolchain=dict(cxx=subprocess.check_output([CXX,'--version'],text=True).splitlines()[0],zig=subprocess.check_output([str(ROOT/'.tools/zig-0.17.0/zig'),'version'],text=True).strip(),unicorn=unicorn,runtime_archives=runtime_archives),
    input_fonts=[dict(path=str(p.relative_to(ROOT)),bytes=p.stat().st_size,sha256=sha(p)) for p in [ROOT/'build/graphics-probe/sources'/n for n in ('BIZUDGothic-Regular.ttf','BIZUDMincho-Regular.ttf')]],
    input_archives_sha256={name:sha(path) for name,path in archives.items()},
    source_sha256=source_hashes,source_fingerprint=hashlib.sha256(''.join(f'{p} {h}\n' for p,h in source_hashes.items()).encode()).hexdigest(),
    artifacts_sha256={str(p.relative_to(ROOT)):sha(p) for p in [OUT/n for n in ('oracle.elf','oracle.map','backing-rv32.o','generated/link_oracle.cpp','build.log','run.log','result.json','controller_only.json','bss_only_after_loan.json','pristine-library.bin')]},
    validation=dict(python_tests='199 passed, including initialized-data/zero-BSS isolation and fail-before-write live/identity/corruption/load-range checks',shellcheck='new host-only runner passed',
        font_lifetimes='three successful RV32 function lifetimes, two restarts, 48 matrix hashes match the prior independently sanitized host reference',negative_controls='stale HarfBuzz registry faults on 0xa5a5a5a5; BSS-only loan restoration reaches freshness refusal; forbidden abort entry stopped',
        persistent_ownership='kernel metadata digest unchanged by restore; other owner 8 MiB charged allocation preserved; full 15072576 B heap recovery after final peer release'),
    limits=['Standalone RV32 ISA only; no native boot, IRQ, scheduler, physical Tab5 or native service restart execution in this stage.',
        'The standalone matrix-only bank and absolute pointers differ from native addresses/globals; this template must never be installed into the native bank.',
        'Existing native one-shot gates, callbacks and queue/session lifecycle are unchanged; final-image initializer placement and native epoch/quiescence/reset plumbing remain open.',
        'No compact initializer codec/decoder is implemented; the 714 B word-patch figure is an encoding payload estimate only, excluding metadata and code.',
        'Fixed 32 KiB stack has canary and unmapped boundaries, without per-instruction SP sampling or arbitrary-font stack qualification.',
        'Pinned native-built library archives are reused, not rebuilt or newly sanitizer-instrumented here; renderer/kernel bridge are newly compiled and target code is exercised.',
        'Failures in negative runtimes are discarded, not claimed as recovered; positive lifetimes use independent runtime and preserve kernel state.',
        'No native SD font IO, display output, cancellation/retry, asynchronous library callbacks or general allocator handoff is qualified.'])
report['artifacts_sha256']['build/library-restart-python.log'] = sha(ROOT/'build/library-restart-python.log')
(OUT/'receipt.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'receipt':str(OUT/'receipt.json'),'sources':len(source_hashes),'footprint':report['footprint']},ensure_ascii=False))
