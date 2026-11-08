import importlib.util
import json
import os
from pathlib import Path
import threading
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
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
        receiver.TOKEN = '12345'
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
                    shots=[dict(id='shot-1', made=True, points=1)])
        intent = dict(id='request-1', action='summon', targetMeters=2)
        sample = {**self.sample(), 'game': game, 'intent': intent}
        self.assertEqual(self.call('/measurements', sample)[0], 200)
        self.assertEqual(self.call('/latest')[1]['robot']['intent']['action'], 'summon')
        self.assertEqual(self.call('/measurements', {**sample, 'intent': {**intent, 'action': 'drive'}})[0], 400)
        self.assertEqual(self.call('/measurements', {**sample, 'game': {**game, 'shots': [dict(id='s', made=True, points=99)]}})[0], 400)
        with receiver.lock:
            receiver.latest['robot'] = (sample, time.monotonic() - 2)
        self.assertIsNone(self.call('/latest')[1]['robot']['intent'])

    def test_replies_include_current_pi_clock(self):
        before = time.time()
        status, reply = self.call('/status')
        self.assertEqual(status,200)
        self.assertGreaterEqual(reply['server_time'],before)
        self.assertLessEqual(reply['server_time'],time.time())
        status, rejected = self.call('/control', dict(action='forward'))
        self.assertEqual(status,409)
        self.assertIn('server_time',rejected)

    def test_http_motor_control(self):
        from controller import Controller
        class FakeDrive:
            def __init__(self): self.last = None
            def set_motor_control(self, lf=True, ls=0, rf=True, rs=0):
                self.last = (ls if lf else -ls, rs if rf else -rs)
        drive = FakeDrive()
        receiver.controller = Controller(drive)
        command = dict(id='move', client_id='phone', sequence=1, sent_at=time.time(), action='forward', speed=25, targetMeters=2)
        try:
            self.assertEqual(self.call('/control', command, token=False)[0], 401)
            status, reply = self.call('/control', command)
            self.assertEqual(status, 200)
            self.assertEqual(drive.last, (25,25))
            self.assertEqual(reply['drive']['state'], 'manual')
            stop = {**command, 'id': 'stop', 'action': 'stop', 'sequence': 2}
            self.assertEqual(self.call('/control', stop)[0], 200)
            self.assertEqual(drive.last, (0,0))
            self.assertEqual(self.call('/control', command)[0], 409)
            self.assertEqual(self.call('/status')[1]['drive']['state'], 'stopped')
        finally:
            receiver.controller = Controller()

    def test_guidance_http_to_real_driver_at_maximum_command(self):
        try:
            from gpiozero import Device
            from gpiozero.pins.mock import MockFactory, MockPWMPin
        except ImportError:
            self.skipTest('gpiozero needed for GPIO integration')
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Firmware' / 'PI'))
        from trashketball import Drive
        from trashketball.drive import MAX_DUTY
        from controller import Controller
        fixture = os.environ.get('TRASHKETBALL_SWIFT_MOTOR_FIXTURE')
        if fixture:
            commands = json.loads(Path(fixture).read_text())
        else:
            commands = [dict(id='guidance-'+action, client_id='robot-guidance', sequence=i+1,
                             sent_at=0, action=action, speed=0 if action == 'stop' else 100, targetMeters=1)
                        for i, action in enumerate(('forward', 'left', 'right', 'stop'))]
        self.assertEqual([c['action'] for c in commands], (['drive', 'left', 'right', 'stop'] if fixture else ['forward', 'left', 'right', 'stop']))
        previous_factory, previous_controller = Device.pin_factory, receiver.controller
        Device.pin_factory = MockFactory(pin_class=MockPWMPin)
        clock = [1000.0]
        try:
            with Drive() as drive:
                receiver.controller = Controller(drive, clock=lambda: clock[0])
                expected = {'forward':(1,1), 'left':(-1,1), 'right':(1,-1), 'stop':(0,0)}
                for command in commands:
                    command['sent_at'] = time.time()
                    status, reply = self.call('/control', command)
                    self.assertEqual(status, 200)
                    if command['action'] == 'drive':
                        left, right = command['leftPercent']/100, command['rightPercent']/100
                    else:
                        l, r = expected[command['action']]
                        left, right = l*command['speed']/100, r*command['speed']/100
                    self.assertAlmostEqual(reply['drive']['left'],left*100)
                    self.assertAlmostEqual(reply['drive']['right'],right*100)
                    self.assertAlmostEqual(drive._left.value, left*MAX_DUTY)
                    self.assertAlmostEqual(drive._right.value, right*MAX_DUTY)
                    self.assertLessEqual(abs(drive._left.value),150/255)
                    self.assertLessEqual(abs(drive._right.value),150/255)
                    self.assertEqual(reply['drive']['commandID'], None if command['action'] == 'stop' else command['id'])
                receiver.controller = Controller(drive, clock=lambda: clock[0], left_gain=.9)
                move = {**commands[0], 'action':'drive', 'leftPercent':100, 'rightPercent':85,
                        'speed':100, 'id':'watchdog-max', 'sequence':5, 'sent_at':time.time()}
                self.assertEqual(self.call('/control', move)[0],200)
                self.assertAlmostEqual(drive._left.value,.9*MAX_DUTY)
                self.assertAlmostEqual(drive._right.value,.85*MAX_DUTY)
                clock[0] += 0.301
                receiver.controller.tick()
                self.assertEqual((drive._left.value,drive._right.value),(0,0))
                self.assertEqual(receiver.controller.state,'timed_out')
                self.assertEqual(self.call('/control',{**move,'sequence':6,'sent_at':time.time()})[0],409)
        finally:
            receiver.controller = previous_controller
            Device.pin_factory.close()
            Device.pin_factory = previous_factory

    def test_beam_events_in_phone_reply(self):
        from scoring import BeamScorer, SWIFT_EPOCH
        previous = receiver.scorer
        now = time.time()
        clock = [now]
        receiver.scorer = BeamScorer(clock=lambda: clock[0], wall=lambda: clock[0])
        receiver.scorer.available = True
        game = dict(id='sensor-round', targetMeters=2, durationSeconds=30, finished=False,
                    startedAt=now-SWIFT_EPOCH, endsAt=now-SWIFT_EPOCH+30, shots=[])
        try:
            sample = {**self.sample(), 'role': 'user', 'game': game}
            self.assertEqual(self.call('/measurements', sample)[0], 200)
            receiver.scorer.edge(False); clock[0] += .1; receiver.scorer.edge(True)
            reply = self.call('/measurements', sample)[1]
            self.assertTrue(reply['beam']['available'])
            self.assertEqual(reply['beam']['pin'], 24)
            self.assertEqual(reply['beam']['events'][0]['points'], 1)
            first = reply['beam']['events'][0]['id']
            self.assertEqual(self.call('/status')[1]['beam']['events'][0]['id'], first)
        finally:
            receiver.scorer = previous

    def test_authenticated_inspection_endpoint(self):
        from controller import Controller
        previous = receiver.controller
        receiver.controller = Controller()
        try:
            self.assertEqual(self.call('/inspection', {'enabled':True}, token=False)[0], 401)
            status, reply = self.call('/inspection', {'enabled':True})
            self.assertEqual(status,200)
            self.assertEqual(reply['drive']['state'],'inspection')
            self.assertTrue(receiver.controller.inspection)
            self.assertEqual(self.call('/inspection', {'enabled':'yes'})[0],409)
            self.assertTrue(receiver.controller.inspection)
            self.assertEqual(self.call('/inspection', {'enabled':False})[0],200)
            self.assertFalse(receiver.controller.inspection)
        finally:
            receiver.controller = previous

    def test_invalid_payloads(self):
        for patch in ({'distance_m': -1}, {'distance_m': float('nan')},
                      {'direction': {'x': 0}}, {'age_s': 2}, {'fresh': False}, {'role': 'motor'}):
            with self.subTest(patch=patch):
                self.assertEqual(self.call('/measurements', {**self.sample(), **patch})[0], 400)


if __name__ == '__main__':
    unittest.main()
