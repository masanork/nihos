"""Budget regressions that reject overcommit and impossible simultaneous layouts."""
import copy
import json
import unittest

import storage_budget as budget
import generate_memory_profile


class DevelopmentBudgetTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads(budget.PROFILE.read_text())

    def reject(self, profile, message):
        with self.assertRaisesRegex(ValueError, message):
            budget.validate_profile(profile)

    def test_combined_profile_and_generated_artifact_agree(self):
        result = budget.assess()
        saved = json.loads((budget.PROFILE.parent / 'tab5-storage-budget.json').read_text())
        self.assertEqual(result, saved)
        self.assertEqual(result['psram_peak_envelope_bytes']['unassigned_headroom'], 17 * budget.MIB // 2)
        self.assertEqual(result['wal_candidates']['soft_logical_bytes'], 4218912)
        self.assertEqual(result['wal_candidates']['quota_logical_bytes'], 16875552)

    def test_compiled_broker_policy_cannot_drift_from_the_json_budget(self):
        self.assertEqual(generate_memory_profile.render(), generate_memory_profile.OUTPUT.read_text())

    def test_positive_headroom_does_not_hide_parent_overcommit(self):
        for key in ('sram_budget_bytes', 'psram_peak_envelope_bytes'):
            changed = copy.deepcopy(self.profile)
            first = next(iter(changed[key]))
            changed[key][first] += 1
            self.reject(changed, 'overcommitted')
        changed = copy.deepcopy(self.profile)
        changed['psram_peak_envelope_bytes']['unassigned_headroom'] = -1
        self.reject(changed, 'invalid byte')

    def test_child_memory_cannot_be_double_charged_outside_its_parent(self):
        for key in ('internal_heap_subdivision_bytes', 'dma_candidate_subdivision_bytes',
                    'network_3MiB_subdivision_bytes', 'ime_2MiB_subdivision_bytes',
                    'store_2MiB_subdivision_bytes'):
            changed = copy.deepcopy(self.profile)
            first = next(iter(changed[key]))
            changed[key][first] += budget.KIB
            self.reject(changed, key)

    def test_balanced_reallocation_cannot_spend_the_internal_free_floor(self):
        changed = copy.deepcopy(self.profile)
        heap = changed['internal_heap_subdivision_bytes']
        heap['minimum_free_reserve'] -= budget.KIB
        heap['network_control_excluding_dma_and_stacks'] += budget.KIB
        self.reject(changed, 'free reserve')

    def test_ime_task_must_fit_inside_total_stack_admission(self):
        changed = copy.deepcopy(self.profile)
        changed['tasks'].append({'role': 'second_ime', 'count': 1, 'each': 4096})
        self.reject(changed, 'task/IRQ count')
        changed = copy.deepcopy(self.profile)
        changed['tasks'][0]['each'] += 4096
        self.reject(changed, 'stack budget')

    def test_heavy_stack_cannot_shrink_while_total_stays_constant(self):
        changed = copy.deepcopy(self.profile)
        vm = next(row for row in changed['tasks'] if row['role'] == 'vm')
        tls = next(row for row in changed['tasks'] if row['role'] == 'tls_http')
        vm['each'] -= 4096
        tls['each'] += 4096
        self.reject(changed, 'heavy task')

    def test_regions_cannot_enter_excluded_loader_or_cache_memory(self):
        for address in (0x4ff28000, 0x4ffa0000):
            changed = copy.deepcopy(self.profile)
            region = changed['candidate_sram_address_ranges'][0]
            region['start'] = hex(address)
            region['end'] = hex(address + region['bytes'])
            self.reject(changed, 'loader/ROM/cache')

    def test_overlap_and_mislabeled_ranges_fail_even_when_byte_sum_fits(self):
        changed = copy.deepcopy(self.profile)
        first, second = changed['candidate_sram_address_ranges'][:2]
        second['start'] = first['start']
        second['end'] = hex(int(first['start'], 16) + second['bytes'])
        self.reject(changed, 'overlapping')
        changed = copy.deepcopy(self.profile)
        changed['candidate_sram_address_ranges'][0]['budget'] = 'reusable_internal_heap'
        self.reject(changed, 'differ from budget')

    def test_larger_psram_batch_is_allowed_but_dma_cannot_exceed_staging(self):
        self.assertGreater(self.profile['storage_geometry']['sd_io_batch_bytes'],
                           self.profile['dma_candidate_subdivision_bytes']['sd_staging'])
        changed = copy.deepcopy(self.profile)
        changed['storage_geometry']['sd_dma_transfer_ceiling_bytes'] = 32768
        self.reject(changed, 'DMA transfer')

    def test_wal_growth_must_charge_another_index_block(self):
        changed = copy.deepcopy(self.profile)
        changed['wal_candidate']['frame_quota_candidate'] = 8192
        self.reject(changed, 'WAL index')
        changed['wal_candidate']['index_budget_bytes'] = 3 * 32768
        budget.validate_profile(changed)

    def test_checkpoint_and_retained_size_hints_cannot_claim_hard_caps(self):
        for field in ('journal_size_limit_is_growth_cap', 'passive_checkpoint_is_work_bound'):
            changed = copy.deepcopy(self.profile)
            changed['wal_candidate'][field] = True
            self.reject(changed, 'checkpoint or WAL quota')

    def test_shared_ime_budget_cannot_silently_become_per_app(self):
        changed = copy.deepcopy(self.profile)
        changed['initial_admission_limits']['ime_services'] = 8
        self.reject(changed, 'IME sharing')

    def test_sqlite_budget_cannot_silently_become_one_cache_per_connection(self):
        changed = copy.deepcopy(self.profile)
        changed['initial_admission_limits']['sqlite_connections'] = 8
        changed['wal_candidate']['connection_count'] = 8
        self.reject(changed, 'SQLite memory budget')


if __name__ == '__main__':
    unittest.main()
