import unittest
from controller import Controller, MotionError


class Clock:
    def __init__(self): self.t = 1000.0
    def __call__(self): return self.t
    def advance(self, value): self.t += value


class Drive:
    def __init__(self): self.outputs = []
    def set_motor_control(self, lf=True, ls=0, rf=True, rs=0):
        self.outputs.append((ls if lf else -ls, rs if rf else -rs))


class MotionTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.drive = Drive()
        self.controller = Controller(self.drive, clock=self.clock, wall=self.clock, calibrated=True)
        self.seq = 0
    def cmd(self, action='forward', id='one', **kwargs):
        self.seq += 1
        return dict(client_id='player', id=id, sequence=self.seq, sent_at=self.clock(),
                    action=action, speed=25, targetMeters=2, **kwargs)
    def pose(self, **kwargs):
        sample = dict(device_id='robot-phone', tracking_session_id='session', role='robot',
                      peer_connected=True, fresh=True, age_s=0, distance_m=4,
                      horizontal_angle_rad=0, direction=None)
        sample.update(kwargs)
        self.controller.ingest(sample)
    def test_manual_release_and_replay(self):
        self.controller.control(self.cmd())
        self.assertEqual(self.drive.outputs[-1], (25,25))
        self.controller.control(self.cmd('stop', id='stop'))
        self.assertEqual(self.drive.outputs[-1], (0,0))
        with self.assertRaises(MotionError): self.controller.control(self.cmd())
    def test_watchdog_requires_new_command(self):
        self.controller.control(self.cmd('reverse'))
        self.clock.advance(.301); self.controller.tick()
        self.assertEqual(self.drive.outputs[-1], (0,0))
        self.assertEqual(self.controller.state, 'timed_out')
        with self.assertRaises(MotionError): self.controller.control(self.cmd('reverse'))
        self.controller.control(self.cmd('reverse', id='two'))
        self.assertEqual(self.drive.outputs[-1], (-25,-25))
    def test_lease_renewal_and_order(self):
        command = self.cmd(); self.controller.control(command)
        self.clock.advance(.2); self.controller.control(self.cmd())
        self.clock.advance(.2); self.controller.tick()
        self.assertEqual(self.controller.state, 'manual')
        with self.assertRaises(MotionError): self.controller.control(command)
    def test_summon_turn_approach_arrive(self):
        self.pose(horizontal_angle_rad=.8)
        self.controller.control(self.cmd('summon'))
        self.assertEqual(self.drive.outputs[-1], (25,-25))
        self.pose(); self.controller.tick()
        self.assertEqual(self.drive.outputs[-1], (25,25))
        self.pose(distance_m=2.1); self.controller.tick()
        self.assertEqual(self.controller.state, 'arrived')
        self.assertEqual(self.drive.outputs[-1], (0,0))
        with self.assertRaises(MotionError): self.controller.control(self.cmd('summon'))
    def test_user_pose_does_not_steer(self):
        self.pose(role='user')
        with self.assertRaises(MotionError): self.controller.control(self.cmd('summon'))
    def test_tracking_loss_requires_new_summon(self):
        self.pose(); self.controller.control(self.cmd('summon'))
        self.pose(horizontal_angle_rad=None)
        self.assertEqual(self.drive.outputs[-1], (0,0))
        self.pose()
        with self.assertRaises(MotionError): self.controller.control(self.cmd('summon'))
    def test_pose_age_and_session(self):
        self.pose(age_s=.26)
        with self.assertRaises(MotionError): self.controller.control(self.cmd('summon'))
        self.pose(); self.controller.control(self.cmd('summon'))
        self.pose(tracking_session_id='new')
        self.assertEqual(self.controller.state, 'tracking_lost')
    def test_moving_command_needs_recent_pose(self):
        self.pose(); self.controller.control(self.cmd('summon'))
        self.clock.advance(.26); self.controller.tick()
        self.assertEqual(self.controller.state, 'tracking_lost')
        self.assertEqual(self.drive.outputs[-1], (0,0))
    def test_calibration_gate_and_disabled(self):
        self.pose(); self.controller.calibrated=False
        with self.assertRaises(MotionError): self.controller.control(self.cmd('summon'))
        with self.assertRaises(MotionError): Controller().control(self.cmd())
    def test_expired_packet_and_speed_cap(self):
        command=self.cmd(); self.clock.advance(.31)
        with self.assertRaises(MotionError): self.controller.control(command)
        command=self.cmd(); command['speed']=101
        with self.assertRaises(MotionError): self.controller.control(command)
    def test_polarity_and_bearing_sign(self):
        self.controller.invert_left=True
        self.controller.control(self.cmd())
        self.assertEqual(self.drive.outputs[-1], (-25,25))
    def test_old_stop_still_stops(self):
        command = self.cmd()
        self.controller.control(command)
        self.controller.control({**command, 'action': 'stop', 'id': 'late-stop', 'sequence': 0, 'sent_at': 0})
        self.assertEqual(self.drive.outputs[-1], (0,0))
        with self.assertRaises(MotionError): self.controller.control(self.cmd())

    def test_full_command_range(self):
        command = self.cmd(); command['speed'] = 100
        self.controller.control(command)
        self.assertEqual(self.drive.outputs[-1], (100,100))

    def test_summon_uses_full_requested_command_on_both_channels(self):
        self.pose(horizontal_angle_rad=0.6)
        turn = self.cmd('summon'); turn['speed'] = 100
        self.controller.control(turn)
        self.assertEqual(self.drive.outputs[-1],(100,-100))
        self.pose(horizontal_angle_rad=0.1,distance_m=2.4)
        self.controller.tick()
        self.assertEqual(self.drive.outputs[-1],(100,100))
        self.pose(distance_m=2.1)
        self.controller.tick()
        self.assertEqual(self.drive.outputs[-1],(0,0))

    def test_inspection_hold_stops_and_blocks_all_motion(self):
        self.controller.control(self.cmd())
        self.controller.set_inspection(True)
        self.assertEqual(self.drive.outputs[-1], (0,0))
        with self.assertRaises(MotionError): self.controller.control(self.cmd(id='new'))
        self.controller.control(self.cmd('stop', id='stop'))
        with self.assertRaises(MotionError): self.controller.control(self.cmd(id='new2'))
        self.controller.set_inspection(False)
        with self.assertRaises(MotionError): self.controller.control(self.cmd())
        self.controller.control(self.cmd(id='after-lab'))
        self.assertEqual(self.drive.outputs[-1], (25,25))

    def test_fault_attempts_stop(self):
        def fail(*args): raise OSError('GPIO fault')
        self.drive.set_motor_control=fail
        with self.assertRaises(OSError): self.controller.control(self.cmd())
        self.assertEqual(self.controller.state,'fault')
        self.assertIsNone(self.controller.command)

    def test_differential_heading_command_and_immutable_lease(self):
        self.controller.control(self.cmd('drive', leftPercent=100, rightPercent=85))
        self.assertEqual(self.drive.outputs[-1], (100,85))
        with self.assertRaises(MotionError):
            self.controller.control(self.cmd('drive', leftPercent=90, rightPercent=100))
        self.controller.control(self.cmd('drive', id='new-direction', leftPercent=90, rightPercent=100))
        self.assertEqual(self.drive.outputs[-1], (90,100))
        self.clock.advance(.301); self.controller.tick()
        self.assertEqual(self.drive.outputs[-1], (0,0))
        with self.assertRaises(MotionError):
            self.controller.control(self.cmd('drive', id='new-direction', leftPercent=90, rightPercent=100))

    def test_differential_rejects_invalid_outputs(self):
        for bad in (None, True, float('nan'), float('inf'), 101, -101, '50'):
            with self.subTest(bad=bad), self.assertRaises(MotionError):
                self.controller.control(self.cmd('drive', leftPercent=bad, rightPercent=100))
        self.assertEqual(self.drive.outputs[-1], (0,0))

    def test_motor_trim_reduces_faster_left_wheel_without_raising_cap(self):
        controller = Controller(self.drive, clock=self.clock, wall=self.clock, left_gain=.9)
        command = self.cmd(); command['speed'] = 100
        controller.control(command)
        self.assertEqual(self.drive.outputs[-1], (90,100))
        self.assertEqual((controller.status()['left'],controller.status()['right']), (90,100))
        controller.control(self.cmd('drive',id='trimmed',leftPercent=80,rightPercent=100))
        self.assertEqual(self.drive.outputs[-1],(72,100))
        controller.control(self.cmd('stop',id='stop-trim'))
        self.assertEqual(self.drive.outputs[-1],(0,0))
        for bad in (1.1, 0, -1, float('nan'), True):
            with self.assertRaises(ValueError): Controller(self.drive, left_gain=bad)

    def test_clock_offset_corrected_timestamp_preserves_expiry_and_watchdog(self):
        # The phone may be a day behind; synchronization stamps in the Pi domain.
        controller = Controller(self.drive, clock=self.clock, wall=lambda:self.clock()+86400)
        command = self.cmd(); command['sent_at'] += 86400
        controller.control(command)
        self.assertEqual(self.drive.outputs[-1], (25,25))
        self.clock.advance(.1)
        renewal = self.cmd(); renewal['sent_at'] += 86400
        controller.control(renewal)
        self.assertEqual(self.drive.outputs[-1], (25,25))
        self.clock.advance(.301); controller.tick()
        self.assertEqual(self.drive.outputs[-1], (0,0))
        with self.assertRaises(MotionError): controller.control(renewal)
        stale = self.cmd(id='delayed'); stale['sent_at'] += 86400-.4
        with self.assertRaisesRegex(MotionError, 'age .*ms'):
            controller.control(stale)


if __name__ == '__main__': unittest.main()
