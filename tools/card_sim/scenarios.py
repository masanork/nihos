"""Executable contracts for the host register model; never accesses hardware."""
import copy
import json
from pathlib import Path
if __package__:
    from .artifacts import png
else:
    from artifacts import png


def four(sim):
    for _ in range(4):
        sim.key('digit')


def classic(sim):
    sim.action('ready')
    sim.action('insert_classic')
    four(sim)
    sim.key('confirm')
    four(sim)
    return sim.key('confirm')


def normal(sim):
    def healthy(state):
        assert state['status'] == 0, state
        assert state['metrics']['mismatches'] == 0, state
        assert state['metrics']['backlight_offs'] == 0, state
        assert state['view']['missing'] == state['view']['truncated'] == 0, state
    healthy(sim.reset('base'))
    healthy(classic(sim))
    assert sim.view()['confirms'] == 2
    assert sim.state()['displayed_phase'] == 'overview'
    healthy(sim.action('details'))
    healthy(sim.action('overview'))
    healthy(sim.action('close'))
    job = sim.view()['job']
    assert sim.action('insert_classic')['status'] == -2  # held card cannot restart
    assert sim.view()['job'] == job
    healthy(sim.action('remove'))
    healthy(sim.action('insert_mynumber'))
    four(sim)
    healthy(sim.key('confirm'))
    assert sim.view()['job'] == job + 1
    assert sim.state()['displayed_phase'] == 'overview'


def atomic(sim):
    sim.reset('base')
    before = sim.state()
    candidate = sim.action('ready', automatic=False)
    assert candidate['metrics']['pending'] == 1
    assert candidate['pixel_sha256'] == before['pixel_sha256']
    assert candidate['sram_sha256'] == before['sram_sha256']
    assert candidate['displayed_phase'] == 'boot'
    assert sim.action('insert_classic')['status'] == -2  # cannot overtake EOF
    after = sim.action('eof')
    assert after['displayed_phase'] == 'ready'
    assert after['pixel_sha256'] != before['pixel_sha256']
    sim.action('insert_classic')
    before = sim.state()
    candidate = sim.key('digit', automatic=False)
    assert candidate['metrics']['pending'] == 2
    assert candidate['pixel_sha256'] == before['pixel_sha256']
    after = sim.action('eof')
    assert after['pixel_sha256'] != before['pixel_sha256']
    assert after['metrics']['mismatches'] == after['metrics']['backlight_offs'] == 0


def gestures(sim):
    sim.reset('base'); sim.action('ready'); sim.action('insert_classic')
    for _ in range(8):
        sim.touch(1, 100, 550)
    assert sim.view()['count'] == 0
    sim.touch(1, 400, 550); sim.touch(0, 0, 0)  # drag to another key
    assert sim.view()['count'] == 0
    sim.touch(2, 100, 550); sim.touch(1, 100, 550); sim.touch(0, 0, 0)
    assert sim.view()['count'] == 0
    sim.key('confirm')  # incomplete PIN ignored
    assert sim.view()['confirms'] == 0
    four(sim); sim.key('digit')
    assert sim.view()['count'] == 4
    sim.key('erase'); assert sim.view()['count'] == 3
    sim.key('cancel'); assert sim.state()['displayed_phase'] == 'ready'
    # Rejected action and incomplete/dragged contacts are absent from saved input.
    assert set(e['action'] for e in sim.trace) <= {'reset', 'ready', 'insert_classic', 'digit', 'erase', 'cancel'}


def capacity(sim):
    sim.reset('base'); sim.action('ready')
    before = sim.state()
    sim.action('fault', value=5)
    after = sim.action('insert_classic')
    assert after['status'] == -3 and after['metrics']['rejections'] == 1
    assert after['pixel_sha256'] == before['pixel_sha256']
    assert after['sram_sha256'] == before['sram_sha256']
    assert after['metrics']['dma_owned'] == 1
    assert sim.key('digit')['view']['count'] == 0  # rejected candidate cannot accept input
    sim.action('fault', value=0)
    assert sim.action('retry_frame')['status'] == 0
    assert sim.state()['displayed_phase'] == 'pin1'
    return {'before': before, 'rejected': after}


def retirement_fault(sim, value):
    sim.reset('base')
    before = sim.state()
    sim.action('fault', value=value)
    after = sim.action('ready')
    assert after['status'] == -4
    assert after['metrics']['fault'] == 8
    assert after['metrics']['dma_owned'] == 1
    assert after['metrics']['backlight'] == 0
    assert after['sram_sha256'] == before['sram_sha256']
    # DMA timeout denies release; FIFO/lane failure can use explicit dark stop.
    if value == 1:
        denied = sim.action('shutdown')
        assert denied['status'] == -2 and denied['metrics']['low_bytes'] > 0
        assert denied['sram_sha256'] == before['sram_sha256']
    sim.action('fault', value=0)
    stopped = sim.action('shutdown')
    assert stopped['status'] == 0
    assert stopped['metrics']['low_bytes'] == stopped['metrics']['high_bytes'] == 0
    return {'before': before, 'retirement_failure': after, 'shutdown': stopped}


def cache_fault(sim):
    sim.reset('base'); sim.action('ready'); sim.action('insert_classic')
    before = sim.state()
    sim.action('fault', value=4)
    after = sim.key('digit')
    assert after['status'] == -4
    assert after['pixel_sha256'] == before['pixel_sha256']
    assert after['metrics']['dma_owned'] == 1
    assert after['metrics']['pending'] == 0
    assert sim.key('digit')['view']['count'] == 1


def corrupt(sim):
    sim.reset('base')
    before = sim.state()
    after = sim.action('corrupt')
    assert after['status'] == 0
    assert after['metrics']['mismatches'] > 0
    assert after['pixel_sha256'] != before['pixel_sha256']
    assert sim.action('ready')['status'] == -2


def profiles(sim):
    state = sim.reset('font')
    assert state['metrics']['high_bytes'] == 124 * 1024
    assert state['status'] == state['metrics']['mismatches'] == 0
    # Same base budget must be respected, not enlarged to make scenes pass.
    for action in ('ready', 'insert_classic'):
        state = sim.action(action)
        assert state['status'] in (0, -3)
        if state['status'] == -3:
            assert state['metrics']['dma_owned'] == 1
            return
    four(sim); sim.key('confirm'); four(sim)
    before = sim.state()
    state = sim.key('confirm')
    assert state['status'] in (0, -3)
    if state['status'] == -3:
        assert state['pixel_sha256'] == before['pixel_sha256']
        assert state['sram_sha256'] == before['sram_sha256']
    else:
        assert state['metrics']['mismatches'] == 0


def deterministic(sim):
    sim.reset('base'); classic(sim); sim.action('details')
    trace, before = copy.deepcopy(sim.trace), sim.state()
    assert all(set(event) <= {'action', 'automatic', 'profile', 'value'} for event in trace)
    after = sim.replay(trace)
    assert after == before
    try:
        sim.replay([{'action': 'digit', 'x': 100, 'y': 550}])
    except ValueError:
        pass
    else:
        raise AssertionError('coordinate replay accepted')


def audited_budget(sim):
    state = sim.reset('audited')
    regions = sim.base_audit['extents']
    assert state['metrics']['low_bytes'] <= regions[0]['bytes']
    assert state['metrics']['high_bytes'] <= regions[1]['bytes']
    steps = [('action', 'ready'), ('action', 'insert_classic')]
    steps += [('key', 'digit')] * 4 + [('key', 'confirm')]
    steps += [('key', 'digit')] * 4 + [('key', 'confirm')]
    for method, name in steps:
        before = sim.state()
        after = getattr(sim, method)(name)
        assert after['status'] in (0, -3)
        if after['status'] == -3:
            assert after['sram_sha256'] == before['sram_sha256']
            assert after['pixel_sha256'] == before['pixel_sha256']
            return
        assert after['metrics']['mismatches'] == after['metrics']['backlight_offs'] == 0


CASES = {'normal': normal, 'eof-atomicity': atomic, 'touch-release': gestures,
         'capacity-rollback': capacity, 'dma-timeout': lambda s: retirement_fault(s, 1),
         'fifo-timeout': lambda s: retirement_fault(s, 2), 'lane-timeout': lambda s: retirement_fault(s, 3),
         'cache-rejection': cache_fault, 'pixel-negative-control': corrupt,
         'base-profiles': profiles, 'deterministic-replay': deterministic}


def run(sim, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    for name in ('report.json', 'overview.rgb565', 'overview.png', 'boot.png', 'trace.json', 'source-witness.json'):
        (output / name).unlink(missing_ok=True)
    report = {'schema': 1, 'source_identity': sim.identity, 'scope': sim.state()['scope'], 'cases': {}}
    cases = dict(CASES)
    if sim.base_audit:
        cases['audited-budget'] = audited_budget
    try:
        for name, case in cases.items():
            report['cases'][name] = {'passed': False}
            observations = case(sim)
            report['cases'][name] = {'passed': True, 'state': sim.state()}
            if observations:
                report['cases'][name]['observations'] = observations
        sim.reset('base')
        (output / 'boot.png').write_bytes(png(sim.pixels()))
        classic(sim)
        (output / 'overview.rgb565').write_bytes(sim.pixels())
        (output / 'overview.png').write_bytes(png(sim.pixels()))
        (output / 'trace.json').write_text(json.dumps(sim.trace, indent=2) + '\n')
        report['overview'] = sim.state()
        report['witness'] = 'source-witness.json'
        (output / 'source-witness.json').write_text(json.dumps(sim.witness, indent=2) + '\n')
    finally:
        report['summary'] = {'passed': sum(case['passed'] for case in report['cases'].values()),
                             'total': len(cases), 'evidence': str(output)}
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return report
