"""Unit tests for the lifecycle controller's "did the simulation keep running?" check.

The first case is the failure of master ``98fd8b3`` (Actions run 46099981595, windows-demo): the two
samples the controller compared, as they were published in that run's ``steps.json``.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_session_recovery import blocked_tick_problem  # noqa: E402

ACTOR = {"actor_instance": 41, "world": "settlement", "world_revision": 1, "player_id": "player_b"}
# steps.json rows 104 and 129 of the failed run. That run's samples had no Host clock; the game time
# between them is reconstructed from the hunger they lost (0.12 per second, as between rows 93 and 104,
# where the buff itself gives the time): 3.168 / 0.12 = 26.4 s = 1584 ticks at 60 Hz.
CI_BEFORE = {"sequence": 1329, "snapshot": 1658, "hunger": 91.3194883999998, "thirst": 84.997791017143,
             "quick_paws": 20.5679406666667}
CI_AFTER = {"sequence": 1538, "snapshot": 2186, "hunger": 88.1517229599998, "thirst": 80.246142857143,
            "quick_paws": -1.0}


def old_check(neutral: dict, still_neutral: dict) -> bool:
    """The condition as it was in 98fd8b3 (True = the controller raised)."""
    return not (still_neutral["snapshot"] > neutral["snapshot"]
                and still_neutral["hunger"] < neutral["hunger"]
                and still_neutral["thirst"] < neutral["thirst"]
                and 0 < still_neutral["quick_paws"] < neutral["quick_paws"])


def sample(msec: int, snapshot: int, hunger: float, thirst: float, buff: float, **extra) -> dict:
    """A sample taken ``msec`` of *game* time after the start (60 physics ticks per second)."""
    return {**ACTOR, "physics_tick": msec * 60 // 1000, "physics_hz": 60, "ticks_msec": msec, "snapshot": snapshot,
            "hunger": hunger, "thirst": thirst, "quick_paws": buff, **extra}


class BlockedTickCheckTests(unittest.TestCase):
    def test_the_ci_failure_was_a_buff_that_ran_out_not_a_simulation_that_stopped(self) -> None:
        self.assertTrue(old_check(CI_BEFORE, CI_AFTER))                # reproduces the failure
        before = {**ACTOR, **CI_BEFORE, "physics_tick": 6000, "physics_hz": 60}
        after = {**ACTOR, **CI_AFTER, "physics_tick": 7584, "physics_hz": 60}
        self.assertEqual(blocked_tick_problem(before, after), "")

    def test_game_time_is_the_clock_not_the_wall(self) -> None:
        """Run 46112525461 (536d950): a starved Host. 22.19 s passed on the wall, 1002 physics ticks
        (16.70 s) in the game, and the buff lost 16.70 s. Nothing had stopped or slowed against the
        game's own clock."""
        before = {**ACTOR, "physics_tick": 5000, "physics_hz": 60, "ticks_msec": 100_000, "snapshot": 900,
                  "hunger": 95.3808, "thirst": 92.0, "quick_paws": 59.209}
        after = {**ACTOR, "physics_tick": 6002, "physics_hz": 60, "ticks_msec": 122_190, "snapshot": 1200,
                 "hunger": 93.3772, "thirst": 89.0, "quick_paws": 42.513}
        self.assertEqual(blocked_tick_problem(before, after), "")
        frozen = {**after, "quick_paws": 59.209}
        self.assertIn("buff ticks stopped", blocked_tick_problem(before, frozen))

    def test_physics_that_did_not_advance_fails(self) -> None:
        problem = blocked_tick_problem(sample(1000, 10, 90.0, 80.0, 60.0),
                                       {**sample(1000, 110, 89.4, 79.1, 55.0), "ticks_msec": 9000})
        self.assertIn("physics did not advance", problem)

    def test_samples_without_a_clock_cannot_excuse_a_missing_buff(self) -> None:
        problem = blocked_tick_problem({**ACTOR, **CI_BEFORE}, {**ACTOR, **CI_AFTER})
        self.assertIn("no Host clock", problem)

    def test_a_running_simulation_passes(self) -> None:
        self.assertEqual(blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), sample(5000, 110, 89.4, 79.1, 55.0)), "")

    def test_a_buff_whose_time_stopped_fails(self) -> None:
        problem = blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), sample(5000, 110, 89.4, 79.1, 60.0))
        self.assertIn("buff ticks stopped", problem)

    def test_a_buff_that_vanished_before_its_time_fails(self) -> None:
        problem = blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), sample(5000, 110, 89.4, 79.1, -1.0))
        self.assertIn("disappeared with 60.00 s left after only 5.00 s of game time", problem)

    def test_a_buff_that_ran_out_passes_only_when_enough_time_passed(self) -> None:
        self.assertEqual(blocked_tick_problem(sample(0, 10, 90.0, 80.0, 4.0), sample(5000, 110, 89.4, 79.1, -1.0)), "")
        self.assertEqual(blocked_tick_problem(sample(0, 10, 90.0, 80.0, 5.4), sample(5000, 110, 89.4, 79.1, -1.0)), "")
        self.assertNotEqual(blocked_tick_problem(sample(0, 10, 90.0, 80.0, 6.0), sample(5000, 110, 89.4, 79.1, -1.0)), "")

    def test_a_buff_draining_at_the_wrong_rate_fails(self) -> None:
        slow = blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), sample(20_000, 110, 89.4, 79.1, 50.0))
        fast = blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), sample(5000, 110, 89.4, 79.1, 40.0))
        self.assertIn("lost 10.00 s while 20.00 s of game time passed", slow)
        self.assertIn("lost 20.00 s while 5.00 s of game time passed", fast)

    def test_survival_that_stopped_fails_and_a_value_at_its_minimum_is_said_to_be_unknowable(self) -> None:
        stopped = blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), sample(5000, 110, 90.0, 79.1, 55.0))
        self.assertIn("hunger did not go down", stopped)
        floor = blocked_tick_problem(sample(0, 10, 90.0, 0.0, 60.0), sample(5000, 110, 89.4, 0.0, 55.0))
        self.assertIn("thirst was already at its minimum", floor)
        self.assertNotIn("stopped", floor)

    def test_no_snapshot_fails(self) -> None:
        problem = blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), sample(5000, 10, 89.4, 79.1, 55.0))
        self.assertIn("no transform snapshot", problem)

    def test_samples_of_different_actors_or_worlds_are_not_compared(self) -> None:
        other = sample(5000, 110, 89.4, 79.1, 55.0, actor_instance=99)
        self.assertIn("not of the same actor", blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), other))
        moved = sample(5000, 110, 89.4, 79.1, 55.0, world_revision=2)
        self.assertIn("world_revision", blocked_tick_problem(sample(0, 10, 90.0, 80.0, 60.0), moved))

    def test_a_buff_that_was_never_there_is_a_fixture_problem(self) -> None:
        problem = blocked_tick_problem(sample(0, 10, 90.0, 80.0, -1.0), sample(5000, 110, 89.4, 79.1, -1.0))
        self.assertIn("was not active at the first sample", problem)


if __name__ == "__main__":
    unittest.main()
