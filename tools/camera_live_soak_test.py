import copy
import json
from pathlib import Path
import tempfile
import unittest

from camera_live_soak import replay


def trace():
    events, now, sequence, frame = [], 0.0, 1, 1

    def emit(line='', delay=.1):
        nonlocal now
        now += delay
        events.append(dict(t=now, line=line))

    def record(tag, **fields):
        emit(tag + ' ' + ' '.join(f'{k}={v:08x}' for k, v in fields.items()))

    def request(kind, accepted=1):
        record('NIHOS_DEVICE_REQUEST', kind=kind, accepted=accepted)

    def shot():
        nonlocal sequence, frame
        record('NIHOS_NATIVE_CAMERA_SNAPSHOT', sequence=sequence, state=1, sample_hash=frame, mismatches=0, frames=frame)
        sequence += 1
        frame += 1

    def repaint():
        record('NIHOS_NATIVE_CAMERA_UI_REPAINT', kind=1, view=1, line_bytes=0)

    def memory(used=2101248):
        emit(f'PSRAM reusable heap capacity=15072576 free={15072576-used} used={used}')

    emit('ESP-ROM:esp32p4')
    emit('NIHOS_NATIVE_SESSION_READY ready=00000001')
    request(27, 0)
    request(29, 0)
    record('NIHOS_NATIVE_SESSION_VIEW', **{'from': 0, 'to': 1})
    memory(0)
    for cycle in range(3):
        request(30)
        for _ in range(12 if cycle == 0 else 0 if cycle == 1 else 5):
            shot()
        record('NIHOS_NATIVE_CAMERA_STREAM', completed=20 if cycle != 1 else 0, dropped=0, fault=0)
        record('NIHOS_NATIVE_CAMERA_LIVE_DRAIN', sequence=sequence)
        sequence += 1
        if cycle != 1:
            repaint()
        memory()
    request(26)
    shot()
    repaint()
    memory()
    now += 1.1
    events.append(dict(t=now))
    request(26)
    shot()
    repaint()
    memory()
    events.append(dict(t=now + 1.1))
    return events


class CameraSoakTest(unittest.TestCase):
    def run_trace(self, events):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.jsonl'
            path.write_text(''.join(json.dumps(event) + '\n' for event in events))
            return replay(path, seconds=1, restarts=2)

    def test_complete_soak_cancel_restart_and_idle_manual(self):
        result = self.run_trace(trace())
        self.assertEqual([cycle['frames'] for cycle in result['cycles']], [12, 0, 5])
        self.assertEqual(result['snapshots'], 19)
        self.assertEqual(result['repaints'], 4)
        self.assertEqual(len(result['memory']), 6)
        self.assertEqual(result['memory'][0]['used'], 0)
        self.assertTrue(all(sample['used'] == 2101248 for sample in result['memory'][1:]))

    def test_rejects_corrupted_physical_evidence(self):
        mutations = [
            ('NIHOS_NATIVE_CAMERA_SNAPSHOT', 'mismatches=00000000', 'mismatches=00000001'),
            ('NIHOS_NATIVE_CAMERA_SNAPSHOT', 'sequence=00000001', 'sequence=00000002'),
            ('NIHOS_NATIVE_CAMERA_STREAM', 'fault=00000000', 'fault=00000001'),
            ('PSRAM reusable heap capacity=15072576 free=12971328 used=2101248', 'free=12971328 used=2101248', 'free=12967232 used=2105344'),
            ('NIHOS_DEVICE_REQUEST kind=0000001b', 'accepted=00000000', 'accepted=00000001'),
        ]
        for tag, old, new in mutations:
            with self.subTest(tag=tag, new=new):
                events = trace()
                event = next(event for event in events if tag in event.get('line', ''))
                event['line'] = event['line'].replace(old, new)
                with self.assertRaises(ValueError):
                    self.run_trace(events)

    def test_rejects_post_drain_frame_loading_frame_reset_and_clock_reversal(self):
        original = trace()
        shot = next(event for event in original if 'CAMERA_SNAPSHOT' in event.get('line', ''))
        drain = next(i for i, event in enumerate(original) if 'CAMERA_LIVE_DRAIN' in event.get('line', ''))
        loading = next(i for i, event in enumerate(original) if i > drain and 'NIHOS_DEVICE_REQUEST kind=0000001e' in event.get('line', ''))
        for index, line, error in [(drain + 1, shot['line'], 'outside active capture'),
                                   (loading + 1, shot['line'], 'outside active capture'),
                                   (drain + 1, 'ESP-ROM:esp32p4', 'unexpected reset')]:
            events = copy.deepcopy(original)
            events.insert(index, dict(t=events[index - 1]['t'], line=line))
            with self.assertRaisesRegex(ValueError, error):
                self.run_trace(events)
        events = copy.deepcopy(original)
        events[10]['t'] = -1
        with self.assertRaises(ValueError):
            self.run_trace(events)

    def test_rejects_truncation_and_stalled_producer(self):
        with self.assertRaises(ValueError):
            self.run_trace(trace()[:-1])
        events = trace()
        first = next(i for i, event in enumerate(events) if 'CAMERA_SNAPSHOT' in event.get('line', ''))
        events.insert(first + 1, dict(t=events[first]['t'] + 2.1))
        with self.assertRaises(ValueError):
            self.run_trace(events)


if __name__ == '__main__':
    unittest.main()
