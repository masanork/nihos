#!/usr/bin/env python3
"""Compile UART1 shim and ensure a UART0 alias cannot pass its SDK guard."""
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
    output = ROOT / 'build/rs485-shim-check'
    output.mkdir(parents=True, exist_ok=True)
    args = [str(zig), 'cc', '-c', '-target', 'riscv32-freestanding-none',
            '-mcpu=generic_rv32+m+a+c+zicsr+zifencei', '-mabi=ilp32', '-Os', '-std=gnu17',
            '-ffreestanding', '-fno-builtin', '-fno-pic',
            '-I', str(ROOT / 'build/native-device-network-rs485/loader/config')]
    for name in ('riscv32-linux-musl', 'generic-musl', 'riscv-linux-any'):
        args += ['-isystem', str(headers / name)]
    for name in ('hal/include', 'hal/platform_port/include', 'hal/esp32p4/include', 'soc/include',
                 'soc/esp32p4/include', 'soc/esp32p4/register/hw_ver1', 'esp_common/include', 'esp_hw_support/include'):
        args += ['-I', str(sdk / 'components' / name)]
    source = ROOT / 'probes/rs485_native/uart.c'
    good = subprocess.run(args + [str(source), '-o', str(output / 'correct.o')], capture_output=True, text=True)
    (output / 'correct.log').write_text(good.stdout + good.stderr)
    if good.returncode:
        raise SystemExit('Correct RS485 shim failed; see build/rs485-shim-check/correct.log')
    wrong = subprocess.run(args + ['-DNIH_RS485_UART_BASE=0x500ca000', str(source), '-o', str(output / 'wrong.o')],
                           capture_output=True, text=True)
    (output / 'wrong.log').write_text(wrong.stdout + wrong.stderr)
    if wrong.returncode == 0 or 'RS485 must use UART1' not in wrong.stderr:
        raise SystemExit('Wrong UART0 alias did not fail the intended static assertion')
    (output / 'result.json').write_text(json.dumps({'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'correct_returncode': good.returncode, 'wrong_returncode': wrong.returncode,
        'negative_base': '0x500ca000', 'intended_assertion_failed': True}, indent=2) + '\n')
    print('UART1 shim compiles; wrong UART0 base rejected by static assertion')


if __name__ == '__main__':
    main()
