"""Debounced beam events tied to the player-authoritative round. GPIO is optional."""
from collections import deque
import threading
import time
import uuid

SWIFT_EPOCH = 978307200


class BeamScorer:
    def __init__(self, *, pin=24, cooldown=0.3, clock=time.monotonic, wall=time.time):
        self.pin, self.cooldown, self.clock, self.wall = pin, cooldown, clock, wall
        self.lock = threading.RLock()
        self.available = False
        self.message = 'Beam scoring disabled in pi/server.py'
        self.blocked = None
        self.clear_since = None
        self.last_break = float('-inf')
        self.break_count = 0
        self.game = None
        self.events = deque(maxlen=256)
        self.input = None

    def update_round(self, data):
        # Robot mirrors and old game shot uploads cannot fabricate beam events.
        if data.get('role') != 'user' or not isinstance(data.get('game'), dict):
            return
        game = data['game']
        with self.lock:
            if self.game is None or self.game['id'] != game['id']:
                self.game = dict(id=game['id'], target=game['targetMeters'],
                                 start=game.get('startedAt'), end=game.get('endsAt'),
                                 finished=game['finished'])
            else:
                # Only the initial transition from ready to started can set the deadline.
                if self.game['start'] is None and game.get('startedAt') is not None:
                    self.game['start'], self.game['end'] = game['startedAt'], game.get('endsAt')
                self.game['finished'] = self.game['finished'] or game['finished']

    def edge(self, blocked):
        with self.lock:
            now = self.clock()
            if blocked == self.blocked:
                return
            previous = self.blocked
            self.blocked = blocked
            if not blocked:
                self.clear_since = now
                return
            # First observation or a short clear glitch never creates a basket.
            if previous is not False or self.clear_since is None or now - self.clear_since < 0.05:
                return
            if now - self.last_break < self.cooldown:
                return
            self.last_break = now
            self.break_count += 1
            game, stamp = self.game, self.wall()
            if not game or game['finished'] or game['start'] is None or game['end'] is None:
                return
            if not game['start'] + SWIFT_EPOCH <= stamp < game['end'] + SWIFT_EPOCH:
                return
            self.events.append(dict(id=str(uuid.uuid4()), roundID=game['id'],
                                    timestamp=stamp, points=1))

    def snapshot(self):
        with self.lock:
            round_id = self.game['id'] if self.game else None
            return dict(available=self.available, pin=self.pin, blocked=self.blocked,
                        message=self.message, breakCount=self.break_count,
                        events=[event.copy() for event in self.events if event['roundID'] == round_id])

    def attach(self, *, active_high=False, input_factory=None):
        if input_factory is None:
            from gpiozero import DigitalInputDevice
            input_factory = DigitalInputDevice
        sensor = input_factory(self.pin, pull_up=True, bounce_time=0.005)
        self.input = sensor
        # With a pull-up, gpiozero is_active is true for LOW. Default: LOW means blocked.
        def read():
            self.edge(not sensor.is_active if active_high else sensor.is_active)
        read()
        sensor.when_activated = read
        sensor.when_deactivated = read
        with self.lock:
            self.available = True
            self.message = 'Beam scoring on GPIO ' + str(self.pin)

    def close(self):
        if self.input:
            self.input.when_activated = None
            self.input.when_deactivated = None
            self.input.close()
        with self.lock:
            self.available = False
