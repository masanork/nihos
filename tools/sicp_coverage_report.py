#!/usr/bin/env python3
"""Produce an evidence-limited 356-exercise index; untested is never passed."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / 'docs/measurements/evidence/2026-11-02-sicp-coverage'
MAXIMA = (46, 97, 82, 79, 52)
EVIDENCE = {
    **{f'1.{i}': 'current-sicp_exercises_1_2_1_5.json' for i in range(2, 6)},
    **{f'1.{i}': 'current-sicp_roots_1_6_1_8.json' for i in range(6, 9)},
    **{f'1.{i}': 'current-sicp_recursion_1_9_1_10.json' for i in range(9, 11)},
    **{f'1.{i}': 'current-sicp_tree_1_11_1_12.json' for i in range(11, 13)},
    '1.1': 'current-sicp_official_sessions.json',
}

def report(folder):
    index = json.loads((folder / 'mit-exercise-index.json').read_text())
    rows = index['exercises']; expected = {f'{chapter}.{i}' for chapter, n in enumerate(MAXIMA, 1) for i in range(1, n+1)}
    ids = [r['id'] for r in rows]
    if len(ids) != len(expected) or set(ids) != expected: raise ValueError('invalid original exercise index')
    if any(not r['url'].startswith('https://mitp-content-server.mit.edu/') or not r['section'] for r in rows): raise ValueError('invalid source reference')
    evidence = dict(EVIDENCE)
    list_proof = 'current-sicp_lists_2_17_2_21.json'
    if (folder / list_proof).exists():
        evidence.update({key: list_proof for key in ('2.17', '2.18', '2.21')})
    rational_proof = 'current-sicp_rational_2_1.json'
    if (folder / rational_proof).exists():
        evidence['2.1'] = rational_proof
    symbol_proof = 'current-sicp_symbols_2_53_2_55.json'
    if (folder / symbol_proof).exists():
        evidence.update({key: symbol_proof for key in ('2.53', '2.54', '2.55')})
    batches = {
        'current-sicp_symbolic_deriv_2_57.json': {'2.57'},
        'current-sicp_set_trees_2_63_2_64.json': {'2.63', '2.64'},
        'current-sicp_huffman_2_67.json': {'2.67'},
        'current-sicp_huffman_2_68.json': {'2.68'},
        'current-sicp_huffman_2_69_2_70.json': {'2.69', '2.70'},
        'current-sicp_recursive_bindings_4_8_4_20.json': {'4.8', '4.20'},
        'current-sicp_abstraction_2_2_2_14.json': {'2.2', '2.3', '2.4', '2.5', '2.6', '2.7', '2.8', '2.9', '2.11', '2.12', '2.14'},
        'current-sicp_fast_processes_1_16_1_28.json': {'1.16', '1.17', '1.18', '1.19', '1.21', '1.23', '1.27', '1.28'},
        'current-sicp_state_3_1_3_7.json': {'3.1', '3.2', '3.3', '3.4', '3.6', '3.7'},
        'current-sicp_metacircular_4_1_4_7.json': {'4.1', '4.2', '4.4', '4.6', '4.7'},
        'current-sicp_register_5_1_5_2.json': {'5.1', '5.2'},
        'current-sicp_trees_2_19_2_32.json': {'2.19', '2.20', '2.22', '2.23', '2.24', '2.25', '2.26', '2.27', '2.28', '2.29', '2.30', '2.31', '2.32'},
        'current-sicp_sequences_2_33_2_42.json': {'2.33', '2.34', '2.35', '2.36', '2.37', '2.38', '2.39', '2.40', '2.41', '2.42', '2.43'},
        'current-sicp_higher_order_1_29_1_46.json': {'1.29', '1.30', '1.31', '1.32', '1.33', '1.35', '1.37', '1.38', '1.39', '1.40', '1.41', '1.42', '1.43', '1.44', '1.45', '1.46'},
        'current-sicp_remaining_1_13_1_36.json': {'1.13', '1.14', '1.15', '1.20', '1.22', '1.24', '1.25', '1.26', '1.34', '1.36'},
        'current-sicp_mutation_3_12_3_20.json': {'3.12', '3.13', '3.14', '3.15', '3.16', '3.17', '3.18', '3.19', '3.20'},
        'current-sicp_queues_3_21_3_23.json': {'3.21', '3.22', '3.23'},
        'current-sicp_tables_3_24_3_27.json': {'3.24', '3.25', '3.26', '3.27'},
        'current-sicp_circuits_3_28_3_31.json': {'3.28', '3.29', '3.30', '3.31', '3.32'},
    }
    for filename, ids in batches.items():
        if (folder / filename).exists(): evidence.update({key: filename for key in ids})
    proofs = {}
    for name in sorted(set(evidence.values())):
        path = folder / name
        data = json.loads(path.read_text())
        if data.get('reference_revision') != 'a27d06c749cdea7ca051e69e7629e3af78c01ac4': raise ValueError('unexpected reference')
        proofs[name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'data': data}
    session = proofs[EVIDENCE['1.1']]['data']['sessions']
    sessions = [s for s in session if s['name'] == 'exercise-1.1']
    if len(sessions) != 1 or len(sessions[0]['forms']) != 13 or any(f['status'] not in ('executed', 'matched') for f in sessions[0]['forms']): raise ValueError('incomplete exercise 1.1 evidence')
    finite = proofs[EVIDENCE['1.2']]['data']['finite_checks']
    if any(not any(x['exercise'] == f'1.{i}' and x['status'] == 'matched' for x in finite) for i in range(2, 6)): raise ValueError('missing 1.2-1.5 checks')
    for key in ('1.6', '1.9', '1.11'):
        if 'All ' not in proofs[EVIDENCE[key]]['data']['test_log'] or 'tests passed.' not in proofs[EVIDENCE[key]]['data']['test_log']: raise ValueError('missing host test success')
    tree = proofs[EVIDENCE['1.11']]['data']
    if not all(any(x['group'].startswith('exercise-'+i) and x['status'] == 'match' for x in tree['cases']) for i in ('1.11','1.12')): raise ValueError('missing tree exercise checks')
    if list_proof in proofs:
        cases = proofs[list_proof]['data']['cases']
        if not all(any(x['exercise'] == key and x['status'] == 'matched' for x in cases) for key in ('2.17', '2.18', '2.21')):
            raise ValueError('missing chapter 2 checks')
    if rational_proof in proofs:
        cases = proofs[rational_proof]['data']['cases']
        if not cases or any(x['exercise'] != '2.1' or x['status'] != 'matched' for x in cases):
            raise ValueError('missing rational exercise checks')
    if symbol_proof in proofs:
        cases = proofs[symbol_proof]['data']['cases']
        if not all(any(x['exercise'] == key and x['status'] == 'matched' for x in cases) for key in ('2.53', '2.54', '2.55')):
            raise ValueError('missing symbol exercise checks')
    for filename, ids in batches.items():
        if filename not in proofs: continue
        cases = proofs[filename]['data']['cases']
        if {row['exercise'] for row in cases} != ids or any(row['status'] not in ('matched', 'mismatch', 'error') for row in cases):
            raise ValueError('invalid batch exercise evidence')
    result=[]
    for row in rows:
        item = dict(row)
        item['coverage'] = 'all_original_expression_steps' if row['id'] == '1.1' else ('sampled' if row['id'] in evidence else 'not_tested')
        item['evidence'] = evidence.get(row['id'])
        if item['evidence'] in batches:
            item['observations'] = dict(Counter(case['status'] for case in proofs[item['evidence']]['data']['cases'] if case['exercise'] == row['id']))
        result.append(item)
    return {'scope': 'Host runtime tests, not exercise-solution completion or R7RS conformance',
            'index_sha256': hashlib.sha256((folder/'mit-exercise-index.json').read_bytes()).hexdigest(),
            'evidence_sha256': {k:v['sha256'] for k,v in proofs.items()},
            'totals': dict(Counter(x['coverage'] for x in result)),
            'by_chapter': {str(c):dict(Counter(x['coverage'] for x in result if x['id'].startswith(str(c)+'.'))) for c in range(1,6)},
            'exercises':result}

if __name__ == '__main__':
    ap=argparse.ArgumentParser(); ap.add_argument('--evidence', type=Path, default=DEFAULT); a=ap.parse_args()
    print(json.dumps(report(a.evidence), indent=2))
