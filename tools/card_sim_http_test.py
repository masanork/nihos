"""Exercise the browser API with real shared libraries and no browser dependency."""
import hashlib
import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from card_sim.app import create_server
from card_sim.backend import Simulator


class CardSimulatorHttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sim = Simulator()
        cls.server = create_server(cls.sim, 0)
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        cls.url = f'http://127.0.0.1:{cls.server.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join()

    def get(self, path):
        with urlopen(self.url + path, timeout=10) as response:
            return response.read()

    def post(self, path, data, origin=None):
        request = Request(self.url + path, json.dumps(data).encode(),
                          {'Content-Type': 'application/json', 'Origin': origin or self.url})
        with urlopen(request, timeout=10) as response:
            return json.load(response)

    def test_frame_and_semantic_replay(self):
        self.assertIn(b'<canvas', self.get('/'))
        state = self.post('/action', {'name': 'reset'})
        data = self.get('/frame?sha=' + state['pixel_sha256'])
        self.assertEqual(len(data), 720 * 1280 * 2)
        self.assertEqual(hashlib.sha256(data).hexdigest(), state['pixel_sha256'])
        self.post('/action', {'name': 'ready'})
        self.post('/action', {'name': 'insert_classic'})
        self.post('/key', {'name': 'digit'})
        trace = json.loads(self.get('/trace'))
        state = self.post('/replay', trace)
        self.assertEqual(state['view']['count'], 1)
        self.assertEqual(state['metrics']['mismatches'], 0)
        self.assertTrue(all(set(event) <= {'action', 'automatic', 'profile', 'value'} for event in trace))

    def test_stale_frame_rejected(self):
        state = self.post('/action', {'name': 'reset'})
        self.post('/action', {'name': 'ready'})
        with self.assertRaises(HTTPError) as caught:
            self.get('/frame?sha=' + state['pixel_sha256'])
        self.assertEqual(caught.exception.code, 409)

    def test_foreign_origin_and_coordinate_trace_rejected(self):
        with self.assertRaises(HTTPError) as caught:
            self.post('/action', {'name': 'reset'}, origin='http://example.invalid')
        self.assertEqual(caught.exception.code, 403)
        with self.assertRaises(HTTPError) as caught:
            self.post('/replay', [{'action': 'digit', 'x': 100}])
        self.assertEqual(caught.exception.code, 400)

    def test_normal_ui_rotation_trace_and_domain_separation(self):
        state = self.post('/normal/action', {'name': 'reset'})
        self.assertEqual(state['application'], 'normal')
        self.post('/normal/touch', {'contacts': 1, 'x': 48, 'y': 79})
        state = self.post('/normal/touch', {'contacts': 0, 'x': 0, 'y': 0})
        self.assertEqual(state['displayed_phase'], 'logs')
        self.assertEqual((state['view']['last_x'], state['view']['last_y']), (1200, 48))
        trace = json.loads(self.get('/normal/trace'))
        self.assertEqual(trace[0]['application'], 'normal')
        self.assertIn('x', trace[1])
        self.assertEqual(self.post('/normal/replay', trace), state)
        before = self.get('/state')
        with self.assertRaises(HTTPError) as caught:
            self.post('/replay', trace)
        self.assertEqual(caught.exception.code, 400)
        self.assertEqual(before, self.get('/state'))
        data = self.get('/normal/frame?sha=' + state['pixel_sha256'])
        self.assertEqual(hashlib.sha256(data).hexdigest(), state['pixel_sha256'])

    def test_normal_trace_over_legacy_request_limit_can_replay(self):
        trace = [{'action': 'reset', 'application': 'normal', 'palette': 4}]
        trace += [{'action': 'pointer', 'contacts': 0, 'x': 0, 'y': 0, 'dt_us': 1} for _ in range(2000)]
        self.assertGreater(len(json.dumps(trace).encode()), 131072)
        state = self.post('/normal/replay', trace)
        self.assertEqual(state['time_us'], 2000)
        self.assertEqual(state['metrics']['mismatches'], 0)

    def test_controller_fault_latch_and_replay(self):
        self.post('/normal/action', {'name': 'reset', 'controller': 'st7123', 'slots': 10})
        self.post('/normal/touch', {'contacts': 1, 'x': 48, 'y': 79, 'sparse': True})
        self.post('/normal/action', {'name': 'controller_fault', 'value': 3})
        state = self.post('/normal/touch', {'contacts': 0, 'x': 0, 'y': 0})
        self.assertEqual(state['controller']['status'], 2)
        self.assertEqual(state['controller']['fresh'], 1)
        self.assertEqual(state['view']['accepted'], 0)
        self.assertEqual(state['view']['cancel'], 1)
        self.assertEqual(state['controller']['max_read'], 63)
        trace = json.loads(self.get('/normal/trace'))
        self.assertEqual(self.post('/normal/replay', trace), state)
        self.assertEqual(state['metrics']['mismatches'], 0)

    def test_invalid_controller_configuration_preserves_state(self):
        before = self.post('/normal/action', {'name': 'reset', 'controller': 'gt911'})
        for data in ({'name': 'reset', 'controller': 'gt911', 'slots': 10},
                     {'name': 'reset', 'controller': 'unknown'}):
            with self.assertRaises(HTTPError) as caught:
                self.post('/normal/action', data)
            self.assertEqual(caught.exception.code, 400)
            self.assertEqual(json.loads(self.get('/normal/state')), before)
        with self.assertRaises(HTTPError):
            self.post('/normal/touch', {'contacts': 1, 'x': 48, 'y': 79, 'sparse': True})
        self.assertEqual(json.loads(self.get('/normal/state')), before)
