"""Motor control state machine. No GPIO imports; Drive is injected at startup."""
import math
import time
from collections import deque


class MotionError(ValueError):
    pass


class Controller:
    WATCHDOG = 0.3
    MAX_SAMPLE_AGE = 0.25

    def __init__(self, drive=None, *, clock=time.monotonic, wall=time.time,
                 calibrated=False, bearing_sign=1, bearing_offset=0,
                 invert_left=False, invert_right=False):
        self.drive, self.clock, self.wall = drive, clock, wall
        self.calibrated = calibrated
        self.sign, self.offset = bearing_sign, bearing_offset
        self.invert_left, self.invert_right = invert_left, invert_right
        self.state = 'stopped' if drive else 'disabled'
        self.message = 'Ready' if drive else 'Start Pi server with --drive to enable motors'
        self.left = self.right = 0
        self.pose = None
        self.owner = None
        self.sequence = -1
        self.command = None
        self.renewed = 0
        self.closed_ids = deque(maxlen=512)
        self.last_output = None
        self._output(0, 0)

    def status(self):
        return dict(enabled=self.drive is not None, state=self.state, message=self.message,
                    summonReady=bool(self.drive and self.calibrated), left=self.left,
                    right=self.right, commandID=self.command['id'] if self.command else None)

    def _output(self, left, right):
        self.left, self.right = left, right
        if self.drive and (left, right) != self.last_output:
            try:
                l = -left if self.invert_left else left
                r = -right if self.invert_right else right
                self.drive.set_motor_control(l >= 0, abs(l), r >= 0, abs(r))
            except Exception:
                # Try a stop even if only one channel's write failed.
                try:
                    self.drive.set_motor_control()
                finally:
                    self.left = self.right = 0
                    self.state, self.message = 'fault', 'Motor write failed; restart Pi server'
                    if self.command:
                        self.closed_ids.append(self.command['id'])
                    self.command = None
                raise
            self.last_output = (left, right)

    def stop(self, message='Stopped', state='stopped'):
        if self.command:
            self.closed_ids.append(self.command['id'])
        self.command = None
        if self.state != 'fault':
            self.state, self.message = state, message
        self._output(0, 0)

    def ingest(self, data):
        if data['role'] != 'robot':
            return
        angle = data.get('horizontal_angle_rad')
        direction = data.get('direction')
        if angle is None and direction is not None:
            angle = math.atan2(direction['x'], -direction['z'])
        identity = (data['device_id'], data.get('tracking_session_id'))
        old_identity = self.pose['identity'] if self.pose else None
        self.pose = dict(identity=identity, received=self.clock(), age=data.get('age_s'),
                         fresh=data['fresh'], distance=data.get('distance_m'), angle=angle,
                         connected=data.get('peer_connected') is True)
        if self.command and self.command['action'] == 'summon':
            if identity != old_identity:
                self.stop('Tracking session changed. Summon again after calibration.', 'tracking_lost')
            elif not self._valid_pose():
                self.stop('Tracking lost. Summon again when live.', 'tracking_lost')

    def _valid_pose(self):
        p = self.pose
        if not p or not p['fresh'] or not p['connected'] or not p['identity'][1]:
            return False
        if p['age'] is None or p['distance'] is None or p['angle'] is None:
            return False
        elapsed = self.clock() - p['received']
        return elapsed < self.WATCHDOG and p['age'] + elapsed < self.MAX_SAMPLE_AGE

    def control(self, data):
        if not isinstance(data, dict):
            raise MotionError('Expected command object')
        action = data.get('action')
        if action not in ('forward', 'reverse', 'left', 'right', 'summon', 'stop'):
            raise MotionError('Unknown action')
        if not isinstance(data.get('client_id'), str) or not 1 <= len(data['client_id']) <= 100:
            raise MotionError('Missing client ID')
        if not isinstance(data.get('id'), str) or not 1 <= len(data['id']) <= 100:
            raise MotionError('Missing command ID')
        if type(data.get('sequence')) is not int or data['sequence'] < 0:
            raise MotionError('Invalid sequence')
        stamp = data.get('sent_at')
        if type(stamp) not in (int, float) or not math.isfinite(stamp):
            raise MotionError('Missing command timestamp')
        # Stops are accepted even when a clock is skewed; movement is not.
        if action != 'stop' and not -0.25 <= self.wall() - stamp <= 0.3:
            raise MotionError('Command expired or phone/Pi clocks differ')
        same_owner = self.owner == data['client_id']
        if action == 'stop':
            if same_owner:
                self.sequence = max(self.sequence, data['sequence'])
            self.closed_ids.append(data['id'])
            self.stop('Stopped from app')
            return self.status()
        if same_owner and data['sequence'] <= self.sequence:
            raise MotionError('Out-of-order command')
        if not self.drive:
            raise MotionError('Motors disabled on Pi; start server with --drive')
        if self.state == 'fault':
            raise MotionError(self.message)
        if self.command and not same_owner:
            raise MotionError('Another phone controls the robot; stop it first')
        if data['id'] in self.closed_ids:
            raise MotionError('Command ended; release and issue a new command')
        speed = data.get('speed', 25)
        if type(speed) not in (int, float) or not math.isfinite(speed) or not 0 < speed <= 100:
            raise MotionError('Speed must be greater than zero and at most 100 percent')
        target = data.get('targetMeters', 2)
        if type(target) is not int or target not in (1, 2, 3):
            raise MotionError('Target must be 1, 2 or 3 m')
        if action == 'summon':
            if not self.calibrated:
                raise MotionError('Set --bearing-calibrated after checking the mounted phone bearing')
            if not self._valid_pose():
                raise MotionError('Waiting for fresh robot-phone distance and bearing')
        if self.command and self.command['id'] == data['id']:
            # Lease renewal cannot mutate an existing command.
            if any(self.command[k] != data.get(k, default) for k, default in
                   [('action', None), ('speed', 25), ('targetMeters', 2)]):
                raise MotionError('Use a new ID to change movement')
        elif self.command:
            self.stop('New command')
        self.owner, self.sequence = data['client_id'], data['sequence']
        self.command = dict(id=data['id'], action=action, speed=speed, targetMeters=target)
        self.renewed = self.clock()
        self.tick()
        return self.status()

    def tick(self):
        if not self.command:
            return
        if self.clock() - self.renewed >= self.WATCHDOG:
            self.stop('Command connection lost. Issue a new command.', 'timed_out')
            return
        action, speed = self.command['action'], self.command['speed']
        if action == 'summon':
            if not self._valid_pose():
                self.stop('Robot tracking stale. Summon again when live.', 'tracking_lost')
                return
            p = self.pose
            if p['distance'] <= self.command['targetMeters'] + 0.15:
                self.stop('At throwing distance', 'arrived')
                return
            angle = self.sign * p['angle'] + self.offset
            angle = math.atan2(math.sin(angle), math.cos(angle))
            if abs(angle) > 0.22:
                turn = min(speed, 70)
                left, right = (turn, -turn) if angle > 0 else (-turn, turn)
                self.state, self.message = 'turning', 'Turning toward player'
            else:
                base = min(speed, 80, max(45, (p['distance'] - self.command['targetMeters']) * 18))
                correction = angle * 25
                left, right = max(0, min(80, base + correction)), max(0, min(80, base - correction))
                self.state, self.message = 'approaching', 'Approaching player'
        else:
            left, right = {'forward': (speed, speed), 'reverse': (-speed, -speed),
                           'left': (-speed, speed), 'right': (speed, -speed)}[action]
            self.state, self.message = 'manual', 'Manual: ' + action
        self._output(left, right)
