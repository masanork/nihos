#!/usr/bin/env python3
"""Calculate the proposed Tab5 storage envelope; this does not qualify firmware."""
import argparse
import json
from pathlib import Path

KIB = 1024
MIB = KIB * KIB
GIB = MIB * KIB


def assess():
    sram = {
        'resident_code_and_base_state': 112 * KIB,
        'task_and_irq_stacks': 128 * KIB,
        'fixed_dma_and_io': 32 * KIB,
        'reusable_internal_heap': 256 * KIB,
        'software_guard_reserve': 16 * KIB,
    }
    psram = {
        'boot_allocator_metadata_and_guards': 2 * MIB,
        'single_framebuffer_and_display': 2 * MIB,
        'editor_project_buffers': MIB,
        'vm_4mib_payload_with_current_buddy_charge': 8 * MIB,
        'sqlite': 2 * MIB,
        'vfs_rpc_and_io_ceiling': MIB // 2,
        'experimental_store_ceiling': 2 * MIB,
        'network_tls_ai': 2 * MIB,
        'sensor_logs': MIB // 2,
        'unassigned_headroom': 12 * MIB,
    }
    store = {name: kib * KIB for name, kib in {
        'persistent_map_cache': 512,
        'resident_transaction_window': 64,
        'append_buffer': 64,
        'gc_buffer': 64,
        'recovery_buffer': 128,
        'checkpoint_buffer': 64,
        'summary_cache': 128,
        'metadata_and_handles': 128,
        'unassigned_headroom': 896,
    }.items()}
    assert sum(sram.values()) == (160 + 384) * KIB
    assert sum(psram.values()) == 32 * MIB
    assert sum(store.values()) == psram['experimental_store_ceiling']
    assert 2 * 8 + 2 * 8 + 16 + 24 + 10 * 4 + 2 * 8 == 128
    entry_bytes, chunk_bytes = 16, 4096
    maps = []
    for live_bytes in [64 * MIB, 128 * MIB, GIB, 4 * GIB, 16 * GIB, 32 * GIB]:
        entries = (live_bytes + chunk_bytes - 1) // chunk_bytes
        maps.append({'logical_bytes': live_bytes, 'entries': entries,
                     'flat_map_bytes': entries * entry_bytes,
                     'fits_512kib_cache_without_other_overhead': entries * entry_bytes <= 512 * KIB})
    reserve_need = MIB + MIB + 64 * KIB + 2 * MIB
    result = {
        'schema': 1,
        'status': 'proposal arithmetic; not implemented capacity or performance evidence',
        'standard_limits': {'tasks_global_including_bootstrap': 16, 'tasks_per_cpu': 8,
                            'storage_clients': 8, 'global_open_objects': 32,
                            'logical_fds_per_app': 8, 'global_file_handles': 16,
                            'mounts': 8, 'path_buffer_bytes': 512,
                            'io_chunk_bytes': 4096, 'stack_budget_bytes': 128 * KIB,
                            'vm_stack_initial_bytes': 16 * KIB, 'network_tls_stack_initial_bytes': 24 * KIB},
        'sram_budget_bytes': sram, 'sram_total_bytes': sum(sram.values()),
        'high_sram_additional_bytes': 328 * KIB,
        'high_sram_qualification': {'source_commit': '8a66e2689714bc48bac3edcb2df5101094d3f7d1',
                                    'physical_usb_rts_runs': 3, 'tested_bytes': 328 * KIB,
                                    'page_pool_bytes': 208 * KIB,
                                    'general_heap_and_stack_admission_integrated': False},
        'psram_peak_envelope_bytes': psram, 'psram_total_bytes': sum(psram.values()),
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
        'geometry_candidates_not_format_decisions': {'logical_chunk_bytes': 4096,
                                                   'sd_segment_bytes': MIB,
                                                   'clean_reserve_segments': 8,
                                                   'gc_step_bytes': 16 * KIB,
                                                   'recovery_tail_bytes_target': 4 * MIB},
        'clean_reserve_example': {'max_unpublished_bytes': MIB, 'gc_live_copy_bytes': MIB,
                                 'checkpoint_bytes': 64 * KIB, 'transition_slack_bytes': 2 * MIB,
                                 'required_bytes': reserve_need, 'candidate_bytes': 8 * MIB,
                                 'fits_this_assumption_only': reserve_need <= 8 * MIB},
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
