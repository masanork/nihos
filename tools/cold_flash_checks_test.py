"""Reject unsafe or unreviewed native qualification placement changes."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest

import native_image_test

IMAGE = native_image_test.MODULE
POLICY_PATH = Path(__file__).with_name('native-cold-policy.json')
POLICY = json.loads(POLICY_PATH.read_text())


def fixture():
    names = sorted(POLICY['functions'])
    functions = [(name, 0x400a0000 + index * 32, 0x400a0020 + index * 32)
                 for index, name in enumerate(names)]
    symbols = {'__flash_cold_start': functions[0][1], '__flash_cold_end': functions[-1][2]}
    symbols.update({name: 0x4ff01000 + index * 32 for index, name in enumerate(POLICY['resident'])})
    manifest = {key: POLICY[key] for key in ('version', 'baseline_bytes', 'resident_limit', 'resident')}
    manifest.update(functions=names, sources={path: 'a' * 64 for path in set(POLICY['functions'].values())},
                    policy_sha256=hashlib.sha256(POLICY_PATH.read_bytes()).hexdigest())
    return manifest, symbols, functions


def audit(manifest, symbols, functions, *, heap=0x4ff19000, span=(0x40020000, 0x400c0000),
          profile='device', broker=None):
    return IMAGE.audit_cold_flash(manifest, symbols, functions, 0x4ff00000, 0x4ff28000,
                                  heap, span, profile, {'version': 2} if broker is None else broker)


class ColdFlashImageChecks(unittest.TestCase):
    def test_exact_normal_functions_move_and_critical_callbacks_stay_resident(self):
        manifest, symbols, functions = fixture()
        result = audit(manifest, symbols, functions)
        self.assertEqual(set(result['functions']), set(POLICY['functions']))
        self.assertEqual(result['recovered_bytes'], 12 * 1024)
        self.assertFalse(result['irq_call_graph_proven'])

    def test_old_images_and_empty_opt_out_extent_still_pass(self):
        self.assertIsNone(audit(None, {}, []))
        self.assertIsNone(audit(None, {'__flash_cold_start': 0x400a0000,
                                      '__flash_cold_end': 0x400a0000}, []))

    def test_manifest_and_nonempty_extent_are_required_together(self):
        manifest, symbols, functions = fixture()
        with self.assertRaises(ValueError): audit(None, symbols, functions)
        with self.assertRaises(ValueError): audit(manifest, {}, functions)
        with self.assertRaises(ValueError): audit([], symbols, functions)
        for key in ('__flash_cold_start', '__flash_cold_end'):
            changed = dict(symbols); del changed[key]
            with self.assertRaises(ValueError): audit(manifest, changed, functions)

    def test_missing_duplicate_and_foreign_functions_cannot_enter_the_extent(self):
        manifest, symbols, functions = fixture()
        for rows in (functions[1:], functions + [functions[0]],
                     [('kernel_irq', *functions[0][1:])] + functions[1:]):
            with self.assertRaises(ValueError): audit(manifest, symbols, rows)

    def test_overlap_gap_and_out_of_span_code_are_rejected(self):
        manifest, symbols, functions = fixture()
        for stop in (functions[0][2] + 1, functions[0][2] - 5):
            rows = [(functions[0][0], functions[0][1], stop)] + functions[1:]
            with self.assertRaises(ValueError): audit(manifest, symbols, rows)
        with self.assertRaises(ValueError): audit(manifest, symbols, functions, span=None)
        with self.assertRaises(ValueError): audit(manifest, symbols, functions, span=(0x40020000, 0x400a0000))

    def test_every_critical_callback_must_remain_in_internal_sram(self):
        manifest, symbols, functions = fixture()
        for name in POLICY['resident']:
            for address in (0, 0x400a0000, 0x48200000, 0x4ff20000, 0x4ff28000):
                with self.subTest(name=name, address=address), self.assertRaises(ValueError):
                    audit(manifest, {**symbols, name: address}, functions)

    def test_spare_resident_budget_must_be_at_least_eight_kib(self):
        manifest, symbols, functions = fixture()
        audit(manifest, symbols, functions, heap=0x4ff1a000)
        for heap in (0x4ff1a001, 0x4ff1c000, 0x4ff00000):
            with self.assertRaises(ValueError): audit(manifest, symbols, functions, heap=heap)

    def test_only_device_broker_two_qualifies(self):
        manifest, symbols, functions = fixture()
        with self.assertRaises(ValueError): audit(manifest, symbols, functions, profile='emulator')
        for broker in ({}, {'version': 1}, {'version': 3}):
            with self.assertRaises(ValueError): audit(manifest, symbols, functions, broker=broker)

    def test_changed_policy_or_missing_source_provenance_is_rejected(self):
        manifest, symbols, functions = fixture()
        for key in manifest:
            changed = copy.deepcopy(manifest); changed[key] = None
            with self.subTest(key=key), self.assertRaises(ValueError): audit(changed, symbols, functions)
        changed = copy.deepcopy(manifest); changed['sources'][next(iter(changed['sources']))] = 'not-a-hash'
        with self.assertRaises(ValueError): audit(changed, symbols, functions)


class ColdFlashBuildFlagChecks(unittest.TestCase):
    def test_invalid_or_unbound_flags_reject_before_building(self):
        root = Path(__file__).resolve().parents[1]
        for flag, broker, expected in [('2', '0', 'must be 0 or 1'), ('1', '0', 'requires MEMORY_BROKER=1')]:
            env = {key: value for key, value in os.environ.items() if not key.startswith('NIHOS_NATIVE_')}
            env.update(NIHOS_NATIVE_COLD_FLASH=flag, NIHOS_NATIVE_MEMORY_BROKER=broker)
            result = subprocess.run(['sh', 'tools/build-native-elf.sh', 'device'], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)
