import unittest
from scoring import BeamScorer, SWIFT_EPOCH


class Clock:
    def __init__(self): self.t = SWIFT_EPOCH + 1000
    def __call__(self): return self.t
    def advance(self, n): self.t += n


class BeamTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.beam = BeamScorer(clock=self.clock, wall=self.clock)
        self.beam.available = True
        self.game = dict(id='round-1', targetMeters=3, durationSeconds=30,
                         startedAt=1000, endsAt=1030, finished=False, shots=[])
        self.beam.update_round(dict(role='user', game=self.game))
        self.beam.edge(False)
        self.clock.advance(.1)
    def break_beam(self): self.beam.edge(True)
    def test_one_basket_per_block(self):
        self.break_beam(); self.break_beam(); self.clock.advance(1); self.break_beam()
        status = self.beam.snapshot()
        self.assertEqual(status['breakCount'], 1)
        self.assertEqual(len(status['events']), 1)
        self.assertEqual(status['events'][0]['points'], 1)
    def test_bounce_and_rearm(self):
        self.break_beam()
        self.beam.edge(False); self.clock.advance(.01); self.break_beam()
        self.assertEqual(len(self.beam.snapshot()['events']), 1)
        self.beam.edge(False); self.clock.advance(.4); self.break_beam()
        self.assertEqual(len(self.beam.snapshot()['events']), 2)
    def test_booting_blocked_does_not_score(self):
        b = BeamScorer(clock=self.clock, wall=self.clock)
        b.update_round(dict(role='user', game=self.game)); b.edge(True)
        self.assertEqual(b.snapshot()['events'], [])
    def test_round_expiry_without_phone_update(self):
        self.clock.advance(30); self.break_beam()
        self.assertEqual(self.beam.snapshot()['events'], [])
    def test_finished_round_does_not_score(self):
        self.beam.update_round(dict(role='user', game={**self.game, 'finished':True}))
        self.break_beam(); self.assertEqual(self.beam.snapshot()['events'], [])
    def test_ready_round_does_not_score(self):
        self.beam.update_round(dict(role='user', game={**self.game, 'id':'ready', 'startedAt':None, 'endsAt':None}))
        self.break_beam(); self.assertEqual(self.beam.snapshot()['events'], [])
    def test_robot_cannot_select_round_or_points(self):
        self.beam.update_round(dict(role='robot', game={**self.game, 'id':'wrong', 'targetMeters':1}))
        self.break_beam(); self.assertEqual(self.beam.snapshot()['events'][0]['roundID'], 'round-1')
        self.assertEqual(self.beam.snapshot()['events'][0]['points'], 1)
    def test_next_round_has_no_old_events(self):
        self.break_beam()
        self.beam.update_round(dict(role='user',game={**self.game,'id':'round-2'}))
        self.assertEqual(self.beam.snapshot()['events'], [])


if __name__ == '__main__': unittest.main()
