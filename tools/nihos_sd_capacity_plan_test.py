import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

import nihos_sd_capacity_plan as planner


def entry(sector, slot, kind, start, count, boot=0):
    at = 446 + 16 * slot
    sector[at] = boot
    sector[at + 4] = kind
    struct.pack_into('<II', sector, at + 8, start, count)


def legacy():
    sector = bytearray(512)
    sector[400:408] = b'NIHSQLD1'
    sector[510:512] = b'\x55\xaa'
    entry(sector, 0, 0xDA, 2048, 8192)
    return sector


class CapacityPlanTest(unittest.TestCase):
    def test_appends_aligned_candidate_without_changing_sector(self):
        sector = legacy()
        before = bytes(sector)
        result = planner.plan(sector, 2_000_000)
        self.assertEqual(sector, before)
        self.assertEqual(result['legacy']['start'], 2048)
        self.assertEqual(result['legacy']['end_exclusive'], 10240)
        self.assertEqual(result['candidate'], {'slot': 2, 'start': 10240, 'count': 65536, 'end_exclusive': 75776})
        self.assertFalse(result['writes_performed'])
        self.assertEqual(result['status'], 'unallocated_by_mbr_only')

    def test_other_partitions_are_preserved_and_alignment_rounds_up(self):
        sector = legacy()
        entry(sector, 1, 0x0C, 12000, 1001)
        entry(sector, 2, 0x83, 14500, 200)
        result = planner.plan(sector, 100000)
        self.assertEqual(result['candidate']['slot'], 4)
        self.assertEqual(result['candidate']['start'], 16384)
        self.assertTrue(all(result['candidate']['start'] >= p['end_exclusive'] for p in result['partitions']))

    def test_rejects_unrecognized_truncated_and_bad_geometry(self):
        for mutate in ('marker', 'signature', 'type', 'start', 'count', 'bounds'):
            sector = legacy()
            if mutate == 'marker': sector[400] = 0
            if mutate == 'signature': sector[511] = 0
            if mutate == 'type': sector[450] = 0x0C
            if mutate == 'start': struct.pack_into('<I', sector, 454, 2049)
            if mutate == 'count': struct.pack_into('<I', sector, 458, 8191)
            if mutate == 'bounds': entry(sector, 1, 0x83, 99999, 10)
            with self.subTest(mutate=mutate), self.assertRaises(planner.PlanError):
                planner.plan(sector, 100000)
        with self.assertRaises(planner.PlanError): planner.plan(bytes(511), 100000)
        with self.assertRaises(planner.PlanError): planner.plan(legacy(), 0)
        with self.assertRaises(planner.PlanError): planner.plan(legacy(), (1 << 32) + 1)

    def test_rejects_overlap_extended_gpt_and_nonempty_unused_slot(self):
        for kind in (0x05, 0x0F, 0x85, 0xEE):
            sector = legacy()
            entry(sector, 1, kind, 12000, 1000)
            with self.subTest(kind=kind), self.assertRaises(planner.PlanError): planner.plan(sector, 100000)
        sector = legacy()
        entry(sector, 1, 0x83, 10000, 1000)
        with self.assertRaises(planner.PlanError): planner.plan(sector, 100000)
        sector = legacy()
        sector[446] = 0x80
        entry(sector, 1, 0x83, 12000, 1000, boot=0x80)
        with self.assertRaises(planner.PlanError): planner.plan(sector, 100000)
        sector = legacy()
        sector[462 + 1] = 7  # Type zero with residual CHS metadata is ambiguous.
        with self.assertRaises(planner.PlanError): planner.plan(sector, 100000)

    def test_rejects_full_table_and_insufficient_space(self):
        sector = legacy()
        for slot in range(1, 4): entry(sector, slot, 0x83, 12000 + slot * 1000, 100)
        with self.assertRaises(planner.PlanError): planner.plan(sector, 100000)
        with self.assertRaises(planner.PlanError): planner.plan(legacy(), 75775)
        self.assertEqual(planner.plan(legacy(), 75776)['candidate']['end_exclusive'], 75776)
        sector = legacy()
        entry(sector, 1, 0x83, 0xFFFFF000, 0x3000)
        with self.assertRaises(planner.PlanError): planner.plan(sector, 1 << 32)

    def test_native_recognition_constants_match_the_planner(self):
        root = Path(__file__).resolve().parents[1]
        layout = (root / 'src/platform/native/sqld_layout.zig').read_text()
        runtime = (root / 'src/platform/native/sqld_runtime.zig').read_text()
        self.assertIn(f'pub const first_sector: u32 = {planner.LEGACY_START};', layout)
        self.assertIn(f'pub const sector_count: u32 = {planner.LEGACY_COUNT};', layout)
        self.assertIn('"NIHSQLD1"', runtime)
        self.assertIn('bytes[450] == 0xda', runtime)

    def test_cli_reads_only_regular_exact_capture_and_rejects_symlinks(self):
        tool = Path(__file__).with_name('nihos_sd_capacity_plan.py')
        with tempfile.TemporaryDirectory() as tmp:
            capture = Path(tmp) / 'sector.bin'
            capture.write_bytes(legacy())
            before = capture.read_bytes()
            run = subprocess.run([sys.executable, str(tool), str(capture), '--card-sectors', '100000'], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(json.loads(run.stdout)['candidate']['start'], 10240)
            self.assertEqual(capture.read_bytes(), before)
            link = Path(tmp) / 'link'
            link.symlink_to(capture)
            with self.assertRaises(planner.PlanError): planner.read_capture(link)
            capture.write_bytes(before + b'X')
            with self.assertRaises(planner.PlanError): planner.read_capture(capture)
            with self.assertRaises(planner.PlanError): planner.read_capture(Path(tmp))
            with self.assertRaises(planner.PlanError): planner.read_capture(Path('/dev/null'))


if __name__ == '__main__':
    unittest.main()
