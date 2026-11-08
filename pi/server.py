"""Authenticated telemetry and motor bridge for the teammate-maintained Drive API."""
from pathlib import Path
import sys
import hmac
import json
import math
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from controller import Controller, MotionError
from scoring import BeamScorer

controller = Controller()
scorer = BeamScorer()
control_lock = threading.RLock()
latest = {}
lock = threading.Lock()
# Startup settings: edit here if the robot's wiring or mounting changes.
TOKEN = "12345"
ENABLE_MOTORS = True
ENABLE_BEAM = True
ENABLE_SUMMON = True
BEARING_SIGN = 1
BEARING_OFFSET_DEG = 0.0
INVERT_LEFT = False
INVERT_RIGHT = False
BEAM_ACTIVE_HIGH = False


def valid_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate(data):
    if not isinstance(data, dict):
        return False
    if data.get('role') not in ('robot', 'user') or type(data.get('fresh')) is not bool:
        return False
    if not isinstance(data.get('device_id'), str) or not 1 <= len(data['device_id']) <= 100:
        return False
    if data.get('peer_connected') is not None and type(data['peer_connected']) is not bool:
        return False
    if data.get('tracking_session_id') is not None and (not isinstance(data['tracking_session_id'], str) or not 1 <= len(data['tracking_session_id']) <= 100):
        return False
    angle = data.get('horizontal_angle_rad')
    if angle is not None and (not valid_number(angle) or abs(angle) > math.pi):
        return False
    distance, direction, age = data.get('distance_m'), data.get('direction'), data.get('age_s')
    if distance is not None and (not valid_number(distance) or distance < 0):
        return False
    if age is not None and (not valid_number(age) or age < 0):
        return False
    if direction is not None:
        if not isinstance(direction, dict) or set(direction) != {'x', 'y', 'z'}:
            return False
        if not all(valid_number(v) and abs(v) <= 1.01 for v in direction.values()):
            return False
    game = data.get('game')
    if game is not None:
        if not isinstance(game, dict) or not isinstance(game.get('id'), str):
            return False
        if game.get('targetMeters') not in (1, 2, 3) or game.get('durationSeconds') not in (30, 60, 90):
            return False
        if type(game.get('finished')) is not bool or not isinstance(game.get('shots'), list) or len(game['shots']) > 256:
            return False
        for shot in game['shots']:
            if not isinstance(shot, dict) or type(shot.get('made')) is not bool or not isinstance(shot.get('id'), str):
                return False
            if type(shot.get('points')) is not int or shot['points'] != (1 if shot['made'] else 0):
                return False
        for key in ('startedAt', 'endsAt'):
            if game.get(key) is not None and not valid_number(game[key]):
                return False
    intent = data.get('intent')
    if intent is not None:
        if not isinstance(intent, dict) or not isinstance(intent.get('id'), str):
            return False
        if intent.get('action') not in ('summon', 'stop') or intent.get('targetMeters') not in (1, 2, 3):
            return False
    if data['fresh'] and (age is None or age >= 1 or (distance is None and direction is None and angle is None)):
        return False
    if not data['fresh'] and (distance is not None or direction is not None or angle is not None):
        return False
    return True


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body):
        if isinstance(body, dict) and 'drive' in body:
            body = {**body, 'beam': scorer.snapshot()}
        raw = json.dumps(body, allow_nan=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(raw)

    def authorized(self):
        return bool(TOKEN) and hmac.compare_digest(
            self.headers.get('Authorization', '').encode(), ('Bearer ' + TOKEN).encode())

    def do_GET(self):
        if self.path == '/health':
            with control_lock:
                body = {'ok': True, 'motors_enabled': controller.drive is not None}
            return self.reply(200, body)
        if self.path == '/status':
            if not self.authorized():
                return self.reply(401, {'error': 'unauthorized'})
            with control_lock:
                body = {'ok': True, 'drive': controller.status()}
            return self.reply(200, body)
        if self.path != '/latest':
            return self.reply(404, {'error': 'not found'})
        if not self.authorized():
            return self.reply(401, {'error': 'unauthorized'})
        with lock:
            result = {}
            for role, (data, received) in latest.items():
                elapsed = time.monotonic() - received
                sample_age = data.get('age_s')
                result[role] = {**data, 'received_age_s': round(elapsed, 3),
                    'fresh': bool(data['fresh'] and sample_age is not None and sample_age + elapsed < 1)}
                if not result[role]['fresh']:
                    result[role]['distance_m'] = None
                    result[role]['direction'] = None
                    result[role]['horizontal_angle_rad'] = None
                    result[role]['intent'] = None
        self.reply(200, result)

    def do_POST(self):
        if self.path not in ('/measurements', '/control'):
            return self.reply(404, {'error': 'not found'})
        if not self.authorized():
            return self.reply(401, {'error': 'unauthorized'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 65536:
                return self.reply(413, {'error': 'body must be 1–65536 bytes'})
            data = json.loads(self.rfile.read(length))
            if self.path == '/measurements' and not validate(data):
                return self.reply(400, {'error': 'invalid measurement'})
        except (ValueError, UnicodeError):
            return self.reply(400, {'error': 'invalid JSON or content length'})
        response_code = 200
        response_error = None
        with control_lock:
            try:
                if self.path == '/control':
                    controller.control(data)
                else:
                    controller.ingest(data)
                drive_status = controller.status()
            except MotionError as error:
                response_code, response_error = 409, str(error)
                drive_status = controller.status()
            except Exception:
                response_code, response_error = 503, 'Motor write failed; check Pi server'
                drive_status = controller.status()
        if response_error:
            return self.reply(response_code, {'error': response_error, 'drive': drive_status})
        if self.path == '/measurements':
            scorer.update_round(data)
            with lock:
                latest[data['role']] = (data, time.monotonic())
        self.reply(200, {'ok': True, 'drive': drive_status})

    def log_message(self, *_):
        pass  # Measurements are printed above; never log the API token.

    def setup(self):
        super().setup()
        self.connection.settimeout(5)


def main():
    global controller, scorer
    if len(sys.argv) > 1:
        raise SystemExit("Run python3 pi/server.py without flags; edit startup settings in that file.")
    if not math.isfinite(BEARING_OFFSET_DEG) or BEARING_SIGN not in (-1, 1):
        raise SystemExit('Check BEARING_OFFSET_DEG and BEARING_SIGN in pi/server.py')
    drive = None
    if ENABLE_MOTORS:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Firmware' / 'PI'))
        from trashketball import Drive
        drive = Drive()
    stopped = threading.Event()
    server = None
    try:
        controller = Controller(drive, calibrated=ENABLE_SUMMON,
                                bearing_sign=BEARING_SIGN,
                                bearing_offset=math.radians(BEARING_OFFSET_DEG),
                                invert_left=INVERT_LEFT, invert_right=INVERT_RIGHT)
        scorer = BeamScorer(pin=24)
        if ENABLE_BEAM:
            try:
                scorer.attach(active_high=BEAM_ACTIVE_HIGH)
            except Exception as error:
                scorer.message = 'Beam sensor unavailable: ' + str(error)
                print(scorer.message, flush=True)
        server = ThreadingHTTPServer(('0.0.0.0', 5001), Handler)
        server.daemon_threads = True
        def watchdog():
            while not stopped.wait(0.02):
                with control_lock:
                    try:
                        controller.tick()
                    except Exception as error:
                        print('Motor fault:', type(error).__name__, flush=True)
        thread = threading.Thread(target=watchdog, daemon=True)
        thread.start()
        print('Trashketball :5001 · motors ' + ('ENABLED' if drive else 'disabled'), flush=True)
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stopped.set()
        try:
            scorer.close()
        except Exception as error:
            print("Beam close failed:", type(error).__name__, flush=True)
        with control_lock:
            try:
                controller.stop('Server shutdown')
            finally:
                controller.drive = None
                if drive:
                    drive.close()
        if server:
            server.server_close()


if __name__ == '__main__':
    main()
