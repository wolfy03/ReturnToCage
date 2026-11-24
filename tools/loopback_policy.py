"""Loopback address policy for the multi-process ENet tests.

The baseline join path is IPv4 loopback (``--address``, default ``127.0.0.1``)
so the tests run on IPv4-only machines and containers. The tests also join one
Host through a *different* address, the IPv6 loopback ``::1``, which checks
IPv6 address parsing and a dual-stack Host bind. That step is controlled by
``--ipv6``:

* ``auto`` (default): run the IPv6 step when this machine can bind ``::1``;
  otherwise run that step over the baseline address and report IPv6 SKIPPED.
* ``require``: the IPv6 step must run; an unavailable ``::1`` fails the test.
  CI uses this so the existing IPv6 coverage cannot silently disappear.
* ``skip``: always run that step over the baseline address (reported).
"""

from __future__ import annotations

import ipaddress
import socket
from dataclasses import dataclass

IPV4_LOOPBACK = "127.0.0.1"
IPV6_LOOPBACK = "::1"
IPV6_MODES = ("auto", "require", "skip")


def add_arguments(parser) -> None:
    parser.add_argument("--address", default=IPV4_LOOPBACK,
                        help="Join address for the baseline Host/Join steps (default: 127.0.0.1).")
    parser.add_argument("--ipv6", choices=IPV6_MODES, default="auto",
                        help="IPv6 loopback step: auto (run if available), require (fail if unavailable), skip.")


def ipv6_loopback_available() -> tuple[bool, str]:
    if not socket.has_ipv6:
        return False, "Python reports no IPv6 support"
    try:
        probe = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    except OSError as error:
        return False, f"cannot create an IPv6 socket: {error}"
    try:
        probe.bind((IPV6_LOOPBACK, 0))
    except OSError as error:
        return False, f"cannot bind ::1: {error}"
    finally:
        probe.close()
    return True, "::1 is bindable"


@dataclass(frozen=True)
class LoopbackPlan:
    primary: str
    alternate: str
    ipv6_mode: str
    ipv6_tested: bool
    ipv6_reason: str

    def describe(self) -> str:
        state = "TESTED" if self.ipv6_tested else "SKIPPED"
        return f"IPv4 baseline {self.primary}; IPv6 {state} ({self.ipv6_mode}: {self.ipv6_reason})"

    def to_summary(self) -> dict:
        return {
            "primary_address": self.primary,
            "alternate_address": self.alternate,
            "ipv6_mode": self.ipv6_mode,
            "ipv6_tested": self.ipv6_tested,
            "ipv6_reason": self.ipv6_reason,
        }


def resolve(address: str = IPV4_LOOPBACK, ipv6_mode: str = "auto") -> LoopbackPlan:
    if ipv6_mode not in IPV6_MODES:
        raise ValueError(f"Unknown IPv6 mode: {ipv6_mode}")
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError as error:
        raise ValueError(f"--address must be a literal IP address: {address}") from error
    if not parsed.is_loopback:
        raise ValueError(f"--address must be a loopback address: {address}")
    if ipv6_mode == "skip":
        return LoopbackPlan(address, address, ipv6_mode, False, "disabled by --ipv6 skip")
    available, reason = ipv6_loopback_available()
    if not available and ipv6_mode == "require":
        raise RuntimeError(f"IPv6 loopback is required but unavailable: {reason}")
    if not available:
        return LoopbackPlan(address, address, ipv6_mode, False, reason)
    return LoopbackPlan(address, IPV6_LOOPBACK, ipv6_mode, True, reason)
