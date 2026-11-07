"""Trashketball telemetry LAN receiver. No dependencies and no GPIO/motor code."""
import hmac
import json
import math
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

latest = {}
lock = threading.Lock()
TOKEN = os.environ.get('TRASHBOT_TOKEN', '')


def valid_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate(data):
    if not isinstance(data, dict):
        return False
    if data.get('role') not in ('robot', 'user') or type(data.get('fresh')) is not bool:
        return False
    if not isinstance(data.get('device_id'), str) or not 1 <= len(data['device_id']) <= 100:
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
            if type(shot.get('points')) is not int or shot['points'] != (game['targetMeters'] if shot['made'] else 0):
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
            return self.reply(200, {'ok': True, 'motors_enabled': False})
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
        if self.path != '/measurements':
            return self.reply(404, {'error': 'not found'})
        if not self.authorized():
            return self.reply(401, {'error': 'unauthorized'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 65536:
                return self.reply(413, {'error': 'body must be 1–65536 bytes'})
            data = json.loads(self.rfile.read(length))
            if not validate(data):
                return self.reply(400, {'error': 'invalid measurement'})
        except (ValueError, UnicodeError):
            return self.reply(400, {'error': 'invalid JSON or content length'})
        with lock:
            latest[data['role']] = (data, time.monotonic())
        print(json.dumps(data, allow_nan=False), flush=True)
        self.reply(200, {'ok': True, 'motors_enabled': False})

    def log_message(self, *_):
        pass  # Measurements are printed above; never log the API token.

    def setup(self):
        super().setup()
        self.connection.settimeout(5)


if __name__ == '__main__':
    if len(TOKEN) < 16:
        raise SystemExit('Set TRASHBOT_TOKEN to a random secret of at least 16 characters.')
    print('Measurement-only receiver on :5001. Motors disabled.', flush=True)
    ThreadingHTTPServer(('0.0.0.0', 5001), Handler).serve_forever()
