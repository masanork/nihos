#!/usr/bin/env python3
"""Compile the native audio shim, then reject the DMA address found on hardware."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--microphone', action='store_true')
    options = parser.parse_args()
    feature = 'microphone' if options.microphone else 'audio'
    sdk = Path(os.environ.get('NIHOS_IDF_PATH') or os.environ.get('IDF_PATH') or Path.home() / 'esp32/esp-idf-v5.4.4')
    zig = ROOT / '.tools/zig-0.17.0/zig'
    headers = zig.parent / 'lib/libc/include'
    output = ROOT / ('build/' + feature + '-shim-check')
    output.mkdir(parents=True, exist_ok=True)
    args = [str(zig), 'cc', '-c', '-target', 'riscv32-freestanding-none',
            '-mcpu=generic_rv32+m+a+c+zicsr+zifencei', '-mabi=ilp32', '-Os', '-std=gnu17',
            '-ffreestanding', '-fno-builtin', '-fno-pic',
            '-I', str(ROOT / ('build/native-device-network-' + feature + '/loader/config'))]
    for name in ('riscv32-linux-musl', 'generic-musl', 'riscv-linux-any'):
        args += ['-isystem', str(headers / name)]
    for name in ('hal/include', 'hal/platform_port/include', 'hal/esp32p4/include', 'soc/include',
                 'soc/esp32p4/include', 'soc/esp32p4/register/hw_ver1', 'esp_common/include', 'esp_hw_support/include'):
        args += ['-I', str(sdk / 'components' / name)]
    source = ROOT / ('probes/microphone_native/rx.c' if options.microphone else 'probes/audio_native/tx.c')
    good = subprocess.run(args + [str(source), '-o', str(output / 'correct.o')], capture_output=True, text=True)
    (output / 'correct.log').write_text(good.stdout + good.stderr)
    if good.returncode:
        raise SystemExit('Correct ' + feature + ' shim failed compilation; see ' + str(output / 'correct.log'))
    bad = subprocess.run(args + ['-D' + ('NIH_MIC' if options.microphone else 'NIH_AUDIO') + '_AHB_DMA_BASE=0x50081000', str(source),
                                '-o', str(output / 'wrong.o')], capture_output=True, text=True)
    (output / 'wrong.log').write_text(bad.stdout + bad.stderr)
    if bad.returncode == 0 or 'AHB DMA is distinct' not in bad.stderr:
        raise SystemExit('Wrong DMA base did not fail the intended static assertion')
    (output / 'result.json').write_text(json.dumps({
        'feature': feature, 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'correct_returncode': good.returncode, 'negative_returncode': bad.returncode,
        'negative_base': '0x50081000', 'intended_assertion_failed': True,
    }, indent=2) + '\n')
    print(feature.capitalize() + ' shim compiles; reproduced wrong DMA base is rejected at compile time')


if __name__ == '__main__':
    main()
