#!/usr/bin/env python3
"""Compile the native audio shim, then reject the DMA address found on hardware."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    sdk = Path(os.environ.get('NIHOS_IDF_PATH') or os.environ.get('IDF_PATH') or Path.home() / 'esp32/esp-idf-v5.4.4')
    zig = ROOT / '.tools/zig-0.17.0/zig'
    headers = zig.parent / 'lib/libc/include'
    output = ROOT / 'build/audio-shim-check'
    output.mkdir(parents=True, exist_ok=True)
    args = [str(zig), 'cc', '-c', '-target', 'riscv32-freestanding-none',
            '-mcpu=generic_rv32+m+a+c+zicsr+zifencei', '-mabi=ilp32', '-Os', '-std=gnu17',
            '-ffreestanding', '-fno-builtin', '-fno-pic',
            '-I', str(ROOT / 'build/native-device-network-audio/loader/config')]
    for name in ('riscv32-linux-musl', 'generic-musl', 'riscv-linux-any'):
        args += ['-isystem', str(headers / name)]
    for name in ('hal/include', 'hal/platform_port/include', 'hal/esp32p4/include', 'soc/include',
                 'soc/esp32p4/include', 'soc/esp32p4/register/hw_ver1', 'esp_common/include', 'esp_hw_support/include'):
        args += ['-I', str(sdk / 'components' / name)]
    source = ROOT / 'probes/audio_native/tx.c'
    good = subprocess.run(args + [str(source), '-o', str(output / 'correct.o')], capture_output=True, text=True)
    (output / 'correct.log').write_text(good.stdout + good.stderr)
    if good.returncode:
        raise SystemExit('Correct audio shim failed compilation; see build/audio-shim-check/correct.log')
    bad = subprocess.run(args + ['-DNIH_AUDIO_AHB_DMA_BASE=0x50081000', str(source),
                                '-o', str(output / 'wrong.o')], capture_output=True, text=True)
    (output / 'wrong.log').write_text(bad.stdout + bad.stderr)
    if bad.returncode == 0 or 'AHB DMA is distinct' not in bad.stderr:
        raise SystemExit('Wrong DMA base did not fail the intended static assertion')
    (output / 'result.json').write_text(json.dumps({
        'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'correct_returncode': good.returncode, 'negative_returncode': bad.returncode,
        'negative_base': '0x50081000', 'intended_assertion_failed': True,
    }, indent=2) + '\n')
    print('Audio shim compiles; reproduced wrong DMA base is rejected at compile time')


if __name__ == '__main__':
    main()
