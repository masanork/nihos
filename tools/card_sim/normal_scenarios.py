"""Normal UI acceptance contracts using production input/rendering components."""
import copy
import json
from pathlib import Path
if __package__:
    from .artifacts import png
else:
    from artifacts import png


def sample(sim, x=1200, y=48, contacts=1, **kwargs):
    return sim.touch(contacts, y, 1279 - x, **kwargs)


def tap(sim, **kwargs):
    sample(sim, **kwargs)
    return sim.touch(0, 0, 0, **kwargs)


def roundtrip(sim):
    before = sim.reset()
    sample(sim)
    assert sim.state()['pixel_sha256'] == before['pixel_sha256']
    assert sim.view()['last_x'] == 1200 and sim.view()['last_y'] == 48
    after = sim.touch(0, 0, 0)
    assert after['displayed_phase'] == 'logs' and after['view']['accepted'] == 1
    assert after['pixel_sha256'] != before['pixel_sha256']
    after = tap(sim)
    assert after['displayed_phase'] == 'splash' and after['view']['accepted'] == 2
    assert after['pixel_sha256'] == before['pixel_sha256']


def rejected_gestures(sim):
    sim.reset()
    for x, y in ((100, 100), (100, 600), (900, 600), (900, 100)):
        sample(sim, x, y); sim.touch(0, 0, 0)
    sample(sim); sample(sim, 1000, 48); sample(sim); sim.touch(0, 0, 0)
    sample(sim); sample(sim, contacts=2); sample(sim); sim.touch(0, 0, 0)
    sample(sim); sim.touch(0, 0, 0, dt_us=1500001)
    assert sim.view()['accepted'] == 0 and sim.view()['cancel'] > 0
    assert tap(sim)['displayed_phase'] == 'logs'


def stale(sim):
    sim.reset(); sample(sim)
    sim.action('tick')
    sample(sim); sim.touch(0, 0, 0)
    assert sim.view()['accepted'] == 0 and sim.view()['cancel'] == 1
    assert tap(sim)['displayed_phase'] == 'logs'


def queue_overflow(sim):
    sim.reset(); sample(sim, dispatch=False)
    for x in range(1201, 1210):
        sample(sim, x, 48, dispatch=False)
    assert sim.view()['overflow'] == 1
    sim.action('drain')
    assert sim.view()['accepted'] == 0
    sim.touch(0, 0, 0)
    assert tap(sim)['view']['accepted'] == 1


def eof_atomicity(sim):
    before = sim.reset()
    pending = tap(sim, automatic=False)
    assert pending['metrics']['pending'] == 1
    assert pending['displayed_phase'] == 'splash' and pending['view']['phase'] == 'logs'
    assert pending['pixel_sha256'] == before['pixel_sha256']
    committed = sim.action('eof')
    assert committed['displayed_phase'] == 'logs' and committed['pixel_sha256'] != before['pixel_sha256']


def scroll_and_palettes(sim):
    for palette in range(5):
        sim.reset(palette)
        # Raw portrait (16,159) maps to landscape control border (1120,16).
        assert sim.pixels()[159 * 1440 + 32:159 * 1440 + 34] == b'\x86\x31'
        tap(sim)
        sim.action('append_log', count=60)
        for _ in range(3):
            state = sim.action('append_log', count=1)
            assert state['status'] == state['metrics']['mismatches'] == 0
        assert sim.pixels()[159 * 1440 + 32:159 * 1440 + 34] == b'\x86\x31'


def replay(sim):
    sim.reset(); rejected_gestures(sim); sim.action('append_log', count=60)
    tap(sim, automatic=False); sim.action('eof')
    before, trace = sim.state(), copy.deepcopy(sim.trace)
    assert sim.replay(trace) == before


def negative_control(sim):
    sim.reset(); tap(sim)
    before = sim.state()
    after = sim.action('corrupt')
    assert after['metrics']['mismatches'] > 0 and after['status'] == -5
    assert after['pixel_sha256'] == before['pixel_sha256']  # rejected candidate
    repaired = sim.action('retry_frame')
    assert repaired['status'] == repaired['metrics']['mismatches'] == 0
    assert repaired['pixel_sha256'] == before['pixel_sha256']


def failure(sim):
    sim.reset(); tap(sim)
    assert sim.action('fail')['view']['failed'] == 1
    assert tap(sim)['displayed_phase'] == 'logs'
    assert sim.view()['accepted'] == 1
    assert sim.state()['metrics']['mismatches'] == 0


def bounded_trace(sim):
    sim.reset()
    event = {'action': 'pointer', 'contacts': 0, 'x': 0, 'y': 0, 'dt_us': 1}
    trace = copy.deepcopy(sim.trace) + [event.copy() for _ in range(4095)]
    state = sim.replay(trace)
    assert state['trace_full'] and len(sim.trace) == 4096
    before = copy.deepcopy(state)
    assert sim.touch(1, 48, 79) == before
    assert sim.action('append_log', count=1) == before
    assert sim.replay(copy.deepcopy(sim.trace)) == before
    assert not sim.reset()['trace_full']


CASES = {'normal-roundtrip': roundtrip, 'normal-rejected-gestures': rejected_gestures,
         'normal-stale': stale, 'normal-queue-overflow': queue_overflow,
         'normal-eof-atomicity': eof_atomicity, 'normal-scroll-palettes': scroll_and_palettes,
         'normal-replay': replay, 'normal-negative-control': negative_control, 'normal-failure': failure,
         'normal-bounded-trace': bounded_trace}


def run(sim, output):
    output = Path(output); output.mkdir(parents=True, exist_ok=True)
    for name in ('report.json', 'splash.png', 'logs.png', 'trace.json', 'source-witness.json'):
        (output / name).unlink(missing_ok=True)
    report = {'schema': 1, 'source_identity': sim.identity, 'scope': sim.state()['scope'], 'cases': {}}
    try:
        for name, case in CASES.items():
            report['cases'][name] = {'passed': False}
            case(sim)
            report['cases'][name] = {'passed': True, 'state': sim.state()}
        sim.reset()
        (output / 'splash.png').write_bytes(png(sim.pixels(), landscape=True))
        tap(sim); sim.action('append_log', count=60)
        (output / 'logs.png').write_bytes(png(sim.pixels(), landscape=True))
        (output / 'trace.json').write_text(json.dumps(sim.trace, indent=2) + '\n')
        (output / 'source-witness.json').write_text(json.dumps(sim.witness, indent=2) + '\n')
    finally:
        report['summary'] = {'application': 'normal', 'passed': sum(c['passed'] for c in report['cases'].values()),
                             'total': len(CASES), 'evidence': str(output)}
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return report
