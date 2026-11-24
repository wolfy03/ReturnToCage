"""Unit tests for the IPv4-baseline / IPv6-optional loopback policy."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import loopback_policy  # noqa: E402


class LoopbackPolicyTests(unittest.TestCase):
    def test_default_baseline_is_ipv4(self) -> None:
        with mock.patch.object(loopback_policy, "ipv6_loopback_available", return_value=(True, "ok")):
            plan = loopback_policy.resolve()
        self.assertEqual(plan.primary, "127.0.0.1")
        self.assertEqual(plan.alternate, "::1")
        self.assertTrue(plan.ipv6_tested)

    def test_auto_without_ipv6_keeps_running_over_ipv4(self) -> None:
        with mock.patch.object(loopback_policy, "ipv6_loopback_available", return_value=(False, "no ::1")):
            plan = loopback_policy.resolve(ipv6_mode="auto")
        self.assertEqual(plan.alternate, "127.0.0.1")
        self.assertFalse(plan.ipv6_tested)
        self.assertIn("SKIPPED", plan.describe())

    def test_require_without_ipv6_fails(self) -> None:
        with mock.patch.object(loopback_policy, "ipv6_loopback_available", return_value=(False, "no ::1")):
            with self.assertRaises(RuntimeError):
                loopback_policy.resolve(ipv6_mode="require")

    def test_skip_never_probes_ipv6(self) -> None:
        with mock.patch.object(loopback_policy, "ipv6_loopback_available") as probe:
            plan = loopback_policy.resolve(ipv6_mode="skip")
        probe.assert_not_called()
        self.assertFalse(plan.ipv6_tested)

    def test_address_must_be_a_loopback_literal(self) -> None:
        for bad in ("localhost", "10.0.0.5", "not-an-ip"):
            with self.assertRaises(ValueError):
                loopback_policy.resolve(address=bad, ipv6_mode="skip")
        self.assertEqual(loopback_policy.resolve(address="127.0.0.2", ipv6_mode="skip").primary, "127.0.0.2")

    def test_summary_reports_both_families(self) -> None:
        with mock.patch.object(loopback_policy, "ipv6_loopback_available", return_value=(True, "ok")):
            summary = loopback_policy.resolve().to_summary()
        self.assertEqual(set(summary), {"primary_address", "alternate_address", "ipv6_mode", "ipv6_tested", "ipv6_reason"})


if __name__ == "__main__":
    unittest.main()
