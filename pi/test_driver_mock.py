"""Optional integration test: actual teammate Drive, forced mock GPIO only."""
import sys
import time
import unittest
from pathlib import Path

try:
    from gpiozero import Device
    from gpiozero.pins.mock import MockFactory, MockPWMPin
    HAVE_GPIOZERO = True
except ImportError:
    HAVE_GPIOZERO = False


@unittest.skipUnless(HAVE_GPIOZERO, 'Install Firmware/PI/requirements.txt for mock GPIO integration')
class DriverIntegrationTests(unittest.TestCase):
    def test_bridge_to_real_driver(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Firmware' / 'PI'))
        from trashketball import Drive
        from trashketball.drive import MAX_DUTY
        from controller import Controller
        old_factory = Device.pin_factory
        Device.pin_factory = MockFactory(pin_class=MockPWMPin)
        try:
            with Drive() as drive:
                self.assertAlmostEqual(MAX_DUTY, 150 / 255)
                controller = Controller(drive)
                command = dict(id='mock-move', client_id='test', sequence=1, sent_at=time.time(),
                               action='forward', speed=100, targetMeters=2)
                controller.control(command)
                self.assertAlmostEqual(drive._left.value, MAX_DUTY)
                self.assertAlmostEqual(drive._right.value, MAX_DUTY)
                controller.control({**command, 'id': 'stop', 'action': 'stop', 'sequence': 2})
                self.assertEqual(drive._left.value, 0)
                self.assertEqual(drive._right.value, 0)
                drive.set_motor_control(True, 999, False, 999)
                self.assertAlmostEqual(drive._left.value, 150 / 255)
                self.assertAlmostEqual(drive._right.value, -150 / 255)
                drive.set_motor_control()
        finally:
            Device.pin_factory.close()
            Device.pin_factory = old_factory

    def test_beam_on_gpio24_mock(self):
        from gpiozero import DigitalInputDevice
        from scoring import BeamScorer
        old_factory = Device.pin_factory
        Device.pin_factory = MockFactory(pin_class=MockPWMPin)
        clock = [1000.0]
        beam = BeamScorer(clock=lambda: clock[0])
        try:
            beam.attach(input_factory=DigitalInputDevice)
            self.assertFalse(beam.snapshot()['blocked'])
            clock[0] += .1
            Device.pin_factory.pin(24).drive_low()
            self.assertTrue(beam.snapshot()['blocked'])
            self.assertEqual(beam.snapshot()['breakCount'], 1)
            clock[0] += .4
            Device.pin_factory.pin(24).drive_high()
            self.assertFalse(beam.snapshot()['blocked'])
        finally:
            beam.close()
            Device.pin_factory.close()
            Device.pin_factory = old_factory
