"""Exercise no-argument startup using mock GPIO, with no listening socket."""
import sys
import unittest
from unittest.mock import patch

try:
    from gpiozero import Device
    from gpiozero.pins.mock import MockFactory, MockPWMPin
    HAS_GPIO = True
except ImportError:
    HAS_GPIO = False


@unittest.skipUnless(HAS_GPIO, 'gpiozero needed for startup integration')
class StartupTests(unittest.TestCase):
    def test_no_flags_enables_hardware_with_preset_token(self):
        import server
        previous_factory = Device.pin_factory
        previous_controller, previous_scorer = server.controller, server.scorer
        Device.pin_factory = MockFactory(pin_class=MockPWMPin)
        test = self
        class FakeServer:
            def __init__(self, *_): pass
            def serve_forever(self):
                test.assertEqual(server.TOKEN, '12345')
                test.assertTrue(server.controller.status()['enabled'])
                test.assertTrue(server.controller.status()['summonReady'])
                test.assertTrue(server.scorer.snapshot()['available'])
                test.assertEqual(server.scorer.snapshot()['pin'], 24)
                raise KeyboardInterrupt
            def server_close(self): pass
        try:
            with patch.object(sys, 'argv', ['server.py']), patch.object(server, 'ThreadingHTTPServer', FakeServer):
                server.main()
        finally:
            Device.pin_factory.close()
            Device.pin_factory = previous_factory
            server.controller, server.scorer = previous_controller, previous_scorer
