#!/usr/bin/env python3
"""Read-only candidate geometry from a captured MBR sector; never opens a disk.

A free MBR interval is not proof that its sectors are unused. This tool does not
write partition tables, format media, migrate data, or authorize a cutover.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct

SECTOR_BYTES = 512
LEGACY_START = 2048
LEGACY_COUNT = 8192
ALIGNMENT = 2048
CANDIDATE_SECTORS = 32 * 1024 * 1024 // SECTOR_BYTES
MAX_LBA_EXCLUSIVE = 1 << 32
EXTENDED_OR_GPT = {0x05, 0x0F, 0x85, 0xEE}


class PlanError(ValueError):
    pass


def plan(sector: bytes, card_sectors: int) -> dict:
    if len(sector) != SECTOR_BYTES:
        raise PlanError('sector capture must contain exactly 512 bytes')
    if not 0 < card_sectors <= MAX_LBA_EXCLUSIVE:
        raise PlanError('card size is outside the supported MBR range')
    if sector[510:512] != b'\x55\xaa':
        raise PlanError('missing MBR signature')
    if sector[400:408] != b'NIHSQLD1':
        raise PlanError('legacy store marker not recognized')
    entries = []
    unused = []
    active_count = 0
    for slot in range(4):
        raw = sector[446 + slot * 16:462 + slot * 16]
        boot, kind = raw[0], raw[4]
        start, count = struct.unpack_from('<II', raw, 8)
        if raw == bytes(16):
            unused.append(slot)
            continue
        if boot not in (0, 0x80) or kind == 0 or count == 0 or start == 0:
            raise PlanError(f'partition {slot + 1} has an invalid or ambiguous entry')
        if kind in EXTENDED_OR_GPT:
            raise PlanError('extended or GPT-protective layouts are unsupported')
        active_count += int(boot == 0x80)
        if active_count > 1:
            raise PlanError('multiple active primary partitions are ambiguous')
        end = start + count
        if end > card_sectors or end > MAX_LBA_EXCLUSIVE:
            raise PlanError(f'partition {slot + 1} exceeds the supplied card size')
        entries.append({'slot': slot + 1, 'type': kind, 'start': start, 'count': count, 'end_exclusive': end})
    if not entries or entries[0]['slot'] != 1 or entries[0]['type'] != 0xDA or entries[0]['start'] != LEGACY_START or entries[0]['count'] != LEGACY_COUNT:
        raise PlanError('first partition does not match the existing 4 MiB store')
    ordered = sorted(entries, key=lambda p: p['start'])
    for previous, current in zip(ordered, ordered[1:]):
        if previous['end_exclusive'] > current['start']:
            raise PlanError('partition ranges overlap')
    if not unused:
        raise PlanError('no fully empty primary partition slot')
    last_end = max(p['end_exclusive'] for p in entries)
    start = (last_end + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
    end = start + CANDIDATE_SECTORS
    if end > card_sectors or end > MAX_LBA_EXCLUSIVE:
        raise PlanError('no 32 MiB aligned candidate after the last partition')
    return {
        'sector0_sha256': hashlib.sha256(sector).hexdigest(),
        'card_sectors_supplied': card_sectors,
        'sector_bytes': SECTOR_BYTES,
        'legacy': entries[0],
        'partitions': entries,
        'candidate': {'slot': unused[0] + 1, 'start': start, 'count': CANDIDATE_SECTORS, 'end_exclusive': end},
        'status': 'unallocated_by_mbr_only',
        'limitations': ['unallocated MBR space may still contain data', 'capture and card size require independent verification', 'not a provisioning or cutover authorization'],
        'writes_performed': False,
    }


def read_capture(path: Path) -> bytes:
    # O_NOFOLLOW plus fstat denies symlinks, raw disks, devices and directories.
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    if not hasattr(os, 'O_NOFOLLOW'):
        raise PlanError('platform cannot safely reject symbolic links')
    try:
        fd = os.open(path, flags)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_size != SECTOR_BYTES:
                raise PlanError('capture must be a regular file of exactly 512 bytes')
            result = os.read(fd, SECTOR_BYTES + 1)
            if len(result) != SECTOR_BYTES:
                raise PlanError('sector capture changed or was read incompletely')
            return result
        finally:
            os.close(fd)
    except OSError as exc:
        raise PlanError(f'cannot read regular sector capture: {exc.strerror}') from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sector0_capture', type=Path, help='existing 512-byte regular-file capture, never a raw device')
    parser.add_argument('--card-sectors', type=int, required=True, help='independently measured 512-byte sector count')
    args = parser.parse_args()
    try:
        result = plan(read_capture(args.sector0_capture), args.card_sectors)
    except PlanError as exc:
        parser.exit(2, f'cannot plan: {exc}\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
