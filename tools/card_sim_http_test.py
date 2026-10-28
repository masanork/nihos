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
