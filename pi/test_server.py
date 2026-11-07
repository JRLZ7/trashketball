import importlib.util
import json
from pathlib import Path
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

spec = importlib.util.spec_from_file_location('receiver', Path(__file__).with_name('server.py'))
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)


class ReceiverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        receiver.TOKEN = 'test-only-secret-123456'
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), receiver.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = 'http://127.0.0.1:' + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def call(self, path, data=None, token=True):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + receiver.TOKEN
        request = Request(self.base + path, data=None if data is None else json.dumps(data).encode(), headers=headers)
        try:
            with urlopen(request, timeout=2) as result:
                return result.status, json.load(result)
        except HTTPError as error:
            return error.code, json.load(error)

    def sample(self):
        return dict(device_id='test-phone', role='robot', fresh=True,
                    distance_m=2.5, direction={'x': 0, 'y': 0, 'z': -1}, age_s=0.01)

    def test_health_and_auth(self):
        self.assertEqual(self.call('/health', token=False), (200, {'ok': True, 'motors_enabled': False}))
        self.assertEqual(self.call('/latest', token=False)[0], 401)
        self.assertEqual(self.call('/measurements', self.sample(), token=False)[0], 401)

    def test_roundtrip_and_staleness(self):
        sample = self.sample()
        self.assertEqual(self.call('/measurements', sample)[0], 200)
        self.assertEqual(self.call('/latest')[1]['robot']['distance_m'], 2.5)
        with receiver.lock:
            receiver.latest['robot'] = (sample, time.monotonic() - 2)
        old = self.call('/latest')[1]['robot']
        self.assertFalse(old['fresh'])
        self.assertIsNone(old['distance_m'])
        self.assertIsNone(old['direction'])

    def test_missing_direction_is_valid(self):
        self.assertEqual(self.call('/measurements', {**self.sample(), 'direction': None})[0], 200)

    def test_horizontal_angle_without_vector(self):
        sample = {**self.sample(), 'direction': None, 'horizontal_angle_rad': 0.3}
        self.assertEqual(self.call('/measurements', sample)[0], 200)
        self.assertEqual(self.call('/latest')[1]['robot']['horizontal_angle_rad'], 0.3)
        self.assertEqual(self.call('/measurements', {**sample, 'horizontal_angle_rad': float('nan')})[0], 400)
        with receiver.lock:
            receiver.latest['robot'] = (sample, time.monotonic() - 2)
        self.assertIsNone(self.call('/latest')[1]['robot']['horizontal_angle_rad'])

    def test_game_and_intent(self):
        game = dict(id='round-1', targetMeters=2, durationSeconds=30, finished=False,
                    shots=[dict(id='shot-1', made=True, points=2)])
        intent = dict(id='request-1', action='summon', targetMeters=2)
        sample = {**self.sample(), 'game': game, 'intent': intent}
        self.assertEqual(self.call('/measurements', sample)[0], 200)
        self.assertEqual(self.call('/latest')[1]['robot']['intent']['action'], 'summon')
        self.assertEqual(self.call('/measurements', {**sample, 'intent': {**intent, 'action': 'drive'}})[0], 400)
        self.assertEqual(self.call('/measurements', {**sample, 'game': {**game, 'shots': [dict(id='s', made=True, points=99)]}})[0], 400)
        with receiver.lock:
            receiver.latest['robot'] = (sample, time.monotonic() - 2)
        self.assertIsNone(self.call('/latest')[1]['robot']['intent'])

    def test_invalid_payloads(self):
        for patch in ({'distance_m': -1}, {'distance_m': float('nan')},
                      {'direction': {'x': 0}}, {'age_s': 2}, {'fresh': False}, {'role': 'motor'}):
            with self.subTest(patch=patch):
                self.assertEqual(self.call('/measurements', {**self.sample(), **patch})[0], 400)


if __name__ == '__main__':
    unittest.main()
