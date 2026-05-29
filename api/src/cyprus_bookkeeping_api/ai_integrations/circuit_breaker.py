"""Circuit breaker for Tier 2 (local LLM) integration.

The local LLM lives on the operator's hardware over a private channel; outages
are routine (machine reboots, model loading, network drops). The breaker
short-circuits during the outage window so we don't waste time hitting a
dead endpoint, and re-probes once after the cool-down.

State machine:

    CLOSED  --N consecutive failures--> OPEN
    OPEN    --recovery_timeout_s elapsed--> HALF_OPEN (one probe allowed)
    HALF_OPEN --success--> CLOSED  (counter reset)
    HALF_OPEN --failure--> OPEN    (timer reset)

The TIER_2_CIRCUIT_BREAKER_OPENED audit event fires exactly once per
CLOSED→OPEN transition (so the audit log shows the outage onset, not every
short-circuited call during the OPEN window).

State is per-process. Multi-worker deployments needing shared breaker state
would push this to Redis/DB; one-worker pilot is fine.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from enum import Enum
from typing import Callable


class BreakerState(str, Enum):
    CLOSED = "CLOSED"
    OPEN = "OPEN"
    HALF_OPEN = "HALF_OPEN"


@dataclass
class AttemptDecision:
    """Returned by :meth:`CircuitBreaker.should_attempt`."""

    allow: bool
    state: BreakerState
    reason: str


class CircuitBreaker:
    """Failure-counting breaker with a recovery probe window.

    Args:
        failure_threshold: Consecutive failures that flip CLOSED→OPEN.
        recovery_timeout_s: Seconds to stay OPEN before allowing one
            HALF_OPEN probe.
        time_source: Pluggable clock for tests. Defaults to ``time.monotonic``.
    """

    def __init__(
        self,
        *,
        failure_threshold: int = 3,
        recovery_timeout_s: float = 30.0,
        time_source: Callable[[], float] = time.monotonic,
    ) -> None:
        if failure_threshold < 1:
            raise ValueError("failure_threshold must be ≥1")
        if recovery_timeout_s <= 0:
            raise ValueError("recovery_timeout_s must be >0")
        self._failure_threshold = failure_threshold
        self._recovery_timeout_s = recovery_timeout_s
        self._time = time_source
        self._state = BreakerState.CLOSED
        self._failure_count = 0
        self._opened_at: float | None = None

    @property
    def state(self) -> BreakerState:
        return self._state

    @property
    def failure_count(self) -> int:
        return self._failure_count

    def should_attempt(self) -> AttemptDecision:
        """Inspect-and-transition: returns whether to attempt the call now.

        If the breaker is OPEN and the recovery window has elapsed, this
        transitions the state to HALF_OPEN and returns ``allow=True``. The
        caller must then call ``on_success`` or ``on_failure`` once based on
        the probe outcome.
        """
        if self._state is BreakerState.CLOSED:
            return AttemptDecision(True, self._state, "closed")
        if self._state is BreakerState.OPEN:
            opened_at = self._opened_at or 0.0
            if self._time() - opened_at >= self._recovery_timeout_s:
                self._state = BreakerState.HALF_OPEN
                return AttemptDecision(True, self._state, "half_open_probe")
            return AttemptDecision(False, self._state, "open_short_circuit")
        # HALF_OPEN: only one probe is allowed at a time. Production guards
        # against concurrent HALF_OPEN probes with a lock; out of scope for
        # the single-worker pilot.
        return AttemptDecision(True, self._state, "half_open_in_flight")

    def on_failure(self) -> bool:
        """Record a failure. Returns True iff this call transitioned CLOSED→OPEN.

        The True-return is the signal to emit ``TIER_2_CIRCUIT_BREAKER_OPENED``.
        """
        if self._state is BreakerState.HALF_OPEN:
            self._state = BreakerState.OPEN
            self._opened_at = self._time()
            return False  # already-open audit not re-emitted
        self._failure_count += 1
        if self._state is BreakerState.CLOSED and self._failure_count >= self._failure_threshold:
            self._state = BreakerState.OPEN
            self._opened_at = self._time()
            return True
        return False

    def on_success(self) -> None:
        """Record a success: closes the breaker, resets the failure counter."""
        self._state = BreakerState.CLOSED
        self._failure_count = 0
        self._opened_at = None

    def snapshot(self) -> dict:
        """Diagnostic snapshot for audit payloads."""
        return {
            "state": self._state.value,
            "failure_count": self._failure_count,
            "failure_threshold": self._failure_threshold,
            "recovery_timeout_s": self._recovery_timeout_s,
            "opened_at_monotonic": self._opened_at,
        }
