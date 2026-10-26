#!/usr/bin/env python3
"""Compare one shared upstream FS reader over independent native/IDF block IO."""
import importlib.util
import json
import re
from pathlib import Path
import sys

SPEC = importlib.util.spec_from_file_location('native', Path(__file__).with_name('check-native-log.py'))
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)


def compare(log, native):
    if native.get('evidence') != 'physical-device' or native.get('storage') is None or native.get('sdmmc') is None:
        raise ValueError('requires a validated physical native storage report')
    if (len(re.findall(r'NIHOS_SDMMC_IDF_ORACLE_PASS reads=(?:8|1032) writes=0', log)) != 1 or
            log.count('NIHOS_SDMMC_IDF_ORACLE_PASS') != 1 or any(word in log for word in ('abort()', 'panic', 'Guru Meditation'))):
        raise ValueError('incomplete IDF reference')
    sectors = native['sdmmc']['sectors_low'] + (native['sdmmc']['sectors_high'] << 32)
    if re.findall(r'NIHOS_SDMMC_IDF_ORACLE_CARD sectors=(\d+)', log) != [str(sectors)]:
        raise ValueError('IDF/native card capacity differs')
    reference = NATIVE.check_storage(NATIVE.fixed_record(log.replace('\r', ''), 'NIHOS_STORAGE_IDF', NATIVE.STORAGE_FIELDS), sectors)
    actual = NATIVE.check_storage(native['storage'], sectors)
    for key in NATIVE.STORAGE_FIELDS:
        if key != 'reads' and reference[key] != actual[key]:
            raise ValueError('native/IDF storage differs: ' + key)
    return {'passed': True, 'upstream_fs_shared': True, 'independent_block_io': True,
            'native_elf_sha256': native['image_elf_sha256'], 'native': actual, 'idf': reference}


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit('usage: check-storage-oracle.py IDF.log NATIVE.json COMPARISON.json')
    try:
        result = compare(Path(sys.argv[1]).read_text(), json.loads(Path(sys.argv[2]).read_text()))
    except ValueError as error:
        raise SystemExit('Storage comparison failed: ' + str(error)) from error
    Path(sys.argv[3]).write_text(json.dumps(result, indent=2) + '\n')
    print('Read-only littlefs native/IDF directory and file results match')
