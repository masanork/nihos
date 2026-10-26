#!/usr/bin/env python3
"""Calculate the proposed Tab5 storage envelope; this does not qualify firmware."""
import argparse
import json
from pathlib import Path

KIB = 1024
MIB = KIB * KIB
GIB = MIB * KIB
PROFILE = Path(__file__).resolve().parents[1] / 'docs/planning/tab5-development-profile.json'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_envelope(values, total, label):
    require(all(type(value) is int and value >= 0 for value in values.values()),
            label + ' contains invalid byte counts')
    require(sum(values.values()) == total, label + ' overcommitted or incomplete')


def validate_profile(profile):
    """Reject capacity/ownership contradictions; this does not admit real tasks."""
    require(profile['schema'] == 1, 'unsupported profile schema')
    sram = profile['sram_budget_bytes']
    psram = profile['psram_peak_envelope_bytes']
    check_envelope(sram, 544 * KIB, 'SRAM')
    check_envelope(psram, 32 * MIB, 'PSRAM')
    children = [('internal_heap_subdivision_bytes', sram['reusable_internal_heap']),
                ('dma_candidate_subdivision_bytes', sram['fixed_dma_and_io']),
                ('network_3MiB_subdivision_bytes', psram['wifi_tcpip_tls_http_ai']),
                ('ime_2MiB_subdivision_bytes', psram['ime_dictionary_cache_composition_and_learning']),
                ('store_2MiB_subdivision_bytes', psram['experimental_store_including_map_and_gc'])]
    for key, total in children:
        check_envelope(profile[key], total, key)
    require(profile['internal_heap_subdivision_bytes']['minimum_free_reserve'] >= 64 * KIB,
            'internal free reserve below 64 KiB')
    tasks, irq = profile['tasks'], profile['irq_stacks']
    for row in [*tasks, irq]:
        require(type(row['count']) is int and row['count'] > 0 and
                type(row['each']) is int and row['each'] >= 4096 and row['each'] % 4096 == 0,
                'invalid stack geometry')
    limits = profile['standard_limits']
    require(sum(row['count'] for row in tasks) == limits['tasks_global_including_bootstrap'] == 16 and
            2 * limits['tasks_per_cpu'] == 16 and irq['count'] == 2, 'task/IRQ count mismatch')
    stack_bytes = sum(row['count'] * row['each'] for row in tasks) + irq['count'] * irq['each']
    require(stack_bytes == sram['task_and_irq_stacks'] == limits['stack_budget_bytes'], 'stack budget mismatch')
    require([row['each'] for row in tasks if row['role'] == 'vm'] == [limits['vm_stack_initial_bytes']] and
            [row['each'] for row in tasks if row['role'] == 'tls_http'] == [limits['network_tls_stack_initial_bytes']],
            'heavy task stack mismatch')
    categories = dict.fromkeys(sram, 0)
    spans = []
    for region in profile['candidate_sram_address_ranges']:
        low, high = int(region['start'], 16), int(region['end'], 16)
        require(low < high and low % 4096 == 0 and high % 4096 == 0 and region['bytes'] == high - low,
                'invalid candidate SRAM range')
        require((0x4ff00000 <= low < high <= 0x4ff28000) or (0x4ff40000 <= low < high <= 0x4ffa0000),
                'candidate range enters loader/ROM/cache space')
        require(region['budget'] in categories, 'unknown SRAM range ownership')
        require(all(high <= start or stop <= low for start, stop in spans), 'overlapping SRAM ranges')
        spans.append((low, high))
        categories[region['budget']] += high - low
    require(categories == sram, 'SRAM ranges differ from budget categories')
    geometry, wal = profile['storage_geometry'], profile['wal_candidate']
    require(geometry['sd_dma_transfer_ceiling_bytes'] <= profile['dma_candidate_subdivision_bytes']['sd_staging'],
            'SD DMA transfer exceeds internal staging')
    require(geometry['sd_io_batch_bytes'] >= geometry['sd_dma_transfer_ceiling_bytes'] and
            geometry['psram_append_buffer_bytes'] == profile['store_2MiB_subdivision_bytes']['append_buffer'],
            'I/O batching or append buffer mismatch')
    require(0 < geometry['logical_clean_space_target_percent'] < 100 and
            geometry['sd_segment_bytes'] % geometry['mapping_node_bytes'] == 0, 'invalid store geometry')
    page = geometry['sqlite_page_bytes']
    require(page in (4096, 8192, 16384) and wal['soft_checkpoint_frames'] > 0 and
            wal['frame_quota_candidate'] >= wal['soft_checkpoint_frames'], 'invalid WAL geometry')
    frames = wal['frame_quota_candidate']
    index_bytes = (1 + (max(0, frames - 4062) + 4095) // 4096) * 32768
    require(index_bytes <= wal['index_budget_bytes'] and wal['index_initial_bytes'] == 32768 and
            wal['sqlite_page_cache_target_bytes'] + wal['index_budget_bytes'] < psram['sqlite_including_wal_index'],
            'WAL index/page-cache exceeds SQLite envelope')
    require(wal['journal_size_limit_is_growth_cap'] is False and wal['passive_checkpoint_is_work_bound'] is False,
            'invalid checkpoint or WAL quota assumption')
    require(profile['initial_admission_limits']['ime_services'] == 1 and
            profile['initial_admission_limits']['active_ime_compositions'] == 1,
            'IME sharing budget requires one service/composition')
    require(wal['connection_count'] == profile['initial_admission_limits']['sqlite_connections'] == 1 and
            profile['initial_admission_limits']['sqlite_databases'] == 1,
            'SQLite memory budget requires one connection/database')
    return profile


def assess():
    profile = validate_profile(json.loads(PROFILE.read_text()))
    sram, psram = profile['sram_budget_bytes'], profile['psram_peak_envelope_bytes']
    store = profile['store_2MiB_subdivision_bytes']
    entry_bytes, chunk_bytes = 16, 4096
    maps = []
    for live_bytes in [64 * MIB, 128 * MIB, GIB, 4 * GIB, 16 * GIB, 32 * GIB]:
        entries = (live_bytes + chunk_bytes - 1) // chunk_bytes
        maps.append({'logical_bytes': live_bytes, 'entries': entries,
                     'flat_map_bytes': entries * entry_bytes,
                     'fits_512kib_cache_without_other_overhead': entries * entry_bytes <= 512 * KIB})
    geometry, wal = profile['storage_geometry'], profile['wal_candidate']
    segment = geometry['sd_segment_bytes']
    reserve_need = segment + segment + 64 * KIB + 2 * segment
    page = geometry['sqlite_page_bytes']
    result = {
        'schema': 2,
        'status': 'proposal arithmetic; not implemented capacity or performance evidence',
        'standard_limits': profile['standard_limits'],
        'development_profile': profile,
        'sram_budget_bytes': sram, 'sram_total_bytes': sum(sram.values()),
        'high_sram_additional_bytes': 328 * KIB,
        'high_sram_qualification': {'source_commit': '8a66e2689714bc48bac3edcb2df5101094d3f7d1',
                                    'physical_usb_rts_runs': 3, 'tested_bytes': 328 * KIB,
                                    'page_pool_bytes': 208 * KIB,
                                    'general_heap_and_stack_admission_integrated': False},
        'psram_peak_envelope_bytes': psram, 'psram_total_bytes': sum(psram.values()),
        'psram_charged_envelope_bytes': sum(psram.values()) - psram['unassigned_headroom'],
        'store_budget_bytes': store, 'store_total_bytes': sum(store.values()),
        'flat_map_assumptions': {'chunk_bytes': chunk_bytes, 'entry_bytes': entry_bytes,
                                 'excludes_hash_slack_versions_object_names_and_segment_map': True},
        'flat_maps': maps,
        'full_scan_examples': [{'volume_bytes': 16 * GIB, 'assumed_bytes_per_second': rate * MIB,
                                'seconds': 16 * GIB / (rate * MIB), 'measured_rate': False}
                               for rate in [1, 8]],
        'cleaner_data_copy_factor_examples': [
            {'victim_live_fraction': live, 'ideal_data_copy_factor': 1 / (1 - live)}
            for live in [.5, .8, .9, .95]],
        'cleaner_factor_scope': 'uniform fixed-size payloads; victim live fraction, not volume fullness; excludes journal, metadata and SD FTL',
        'geometry_candidates_not_format_decisions': geometry,
        'wal_candidates': {**wal, 'soft_logical_bytes': 32 + wal['soft_checkpoint_frames'] * (page + 24),
                           'quota_logical_bytes': 32 + wal['frame_quota_candidate'] * (page + 24)},
        'clean_reserve_example': {'max_unpublished_bytes': segment, 'gc_live_copy_bytes': segment,
                                 'checkpoint_bytes': 64 * KIB, 'transition_slack_bytes': 2 * segment,
                                 'required_bytes': reserve_need,
                                 'candidate_bytes': geometry['clean_reserve_segments'] * segment,
                                 'fits_this_assumption_only': reserve_need <= geometry['clean_reserve_segments'] * segment},
        'notes': [
            'Budgets are ceilings/envelopes, not startup reservations.',
            'Current CPU-local PSRAM heaps do not form a borrowable global pool.',
            'Header/alignment rounding must be charged for every real parent allocation.',
            'A resident transaction window is not a cap on a SQLite transaction or blob size.',
            'Checkpoint, recovery and GC must fit at peak overlap, not only steady state.',
            'High SRAM cell/SMP/page-pool tests passed on the retained device image; general broker and expanded stack admission remain gates.',
            'The previous 16 KiB internal headroom is now reserved for software guards, not free capacity.',
        ],
    }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = json.dumps(assess(), indent=2) + '\n'
    if args.output:
        args.output.write_text(output)
    else:
        print(output, end='')


if __name__ == '__main__':
    main()
