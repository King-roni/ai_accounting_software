"""B06·P06 — Local LLM (Tier 2) integration tests.

CircuitBreaker is tested in isolation with a controllable clock.
LocalLlmClient is tested with ``httpx.MockTransport`` so no real network
calls happen.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest

from cyprus_bookkeeping_api.ai_integrations import (
    BreakerState,
    BypassAttemptBlockedError,
    CallContext,
    CircuitBreaker,
    LocalLlmClient,
    ModelError,
)


# ---------- Stubs ----------------------------------------------------------------


@dataclass
class CapturedAuditEvent:
    action: str
    business_id: UUID
    invocation_id: UUID | None
    actor_user_id: UUID | None
    payload: dict


@dataclass
class StubAudit:
    events: list[CapturedAuditEvent] = field(default_factory=list)

    def record_tier2_event(
        self,
        *,
        action: str,
        business_id: UUID,
        invocation_id: UUID | None,
        actor_user_id: UUID | None,
        payload: dict,
    ) -> None:
        self.events.append(CapturedAuditEvent(
            action=action, business_id=business_id, invocation_id=invocation_id,
            actor_user_id=actor_user_id, payload=payload))

    def actions(self) -> list[str]:
        return [e.action for e in self.events]


class FakeClock:
    """Manually-advanced monotonic clock for breaker tests."""

    def __init__(self) -> None:
        self.now: float = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def _gateway_ctx() -> CallContext:
    return CallContext(
        via_gateway=True, invocation_id=uuid4(),
        business_id=uuid4(), actor_user_id=None)


def _bypass_ctx() -> CallContext:
    return CallContext(
        via_gateway=False, invocation_id=uuid4(),
        business_id=uuid4(), actor_user_id=None)


def _ollama_success_body(content: str = '{"n":"Acme Ltd"}',
                         model: str = "llama3") -> dict:
    return {
        "model": model,
        "message": {"role": "assistant", "content": content},
        "done": True,
        "total_duration": 1_200_000_000,
        "load_duration": 200_000_000,
        "prompt_eval_count": 30,
        "prompt_eval_duration": 100_000_000,
        "eval_count": 17,
        "eval_duration": 900_000_000,
    }


def _mock_client(handler: Any) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler), timeout=5.0)


# ========== CircuitBreaker unit tests =========================================

def test_breaker_starts_closed() -> None:
    cb = CircuitBreaker(failure_threshold=3, recovery_timeout_s=10)
    assert cb.state is BreakerState.CLOSED
    assert cb.should_attempt().allow is True


def test_breaker_opens_after_threshold_failures_and_signals_transition() -> None:
    cb = CircuitBreaker(failure_threshold=3, recovery_timeout_s=10)
    transition_signals = [cb.on_failure() for _ in range(3)]
    assert transition_signals == [False, False, True], (
        "TIER_2_CIRCUIT_BREAKER_OPENED must fire on the threshold-crossing "
        "failure exactly once")
    assert cb.state is BreakerState.OPEN
    assert cb.should_attempt().allow is False


def test_breaker_half_open_probe_allowed_after_recovery_timeout() -> None:
    clock = FakeClock()
    cb = CircuitBreaker(failure_threshold=2, recovery_timeout_s=10,
                        time_source=clock)
    cb.on_failure(); cb.on_failure()
    assert cb.state is BreakerState.OPEN
    clock.advance(9.999)
    assert cb.should_attempt().allow is False
    clock.advance(0.002)  # past 10s
    decision = cb.should_attempt()
    assert decision.allow is True
    assert decision.state is BreakerState.HALF_OPEN


def test_breaker_half_open_success_resets_to_closed() -> None:
    clock = FakeClock()
    cb = CircuitBreaker(failure_threshold=2, recovery_timeout_s=10,
                        time_source=clock)
    cb.on_failure(); cb.on_failure()
    clock.advance(11)
    cb.should_attempt()  # moves CB into HALF_OPEN
    cb.on_success()
    assert cb.state is BreakerState.CLOSED
    assert cb.failure_count == 0


def test_breaker_half_open_failure_reopens_with_timer_reset() -> None:
    clock = FakeClock()
    cb = CircuitBreaker(failure_threshold=2, recovery_timeout_s=10,
                        time_source=clock)
    cb.on_failure(); cb.on_failure()
    clock.advance(11)
    cb.should_attempt()  # HALF_OPEN
    assert cb.on_failure() is False  # already-open transition does not re-emit
    assert cb.state is BreakerState.OPEN
    # the timer was reset to the HALF_OPEN failure time, so it short-circuits again now
    assert cb.should_attempt().allow is False


# ========== LocalLlmClient client tests =======================================

def test_base_url_validation_rejects_garbage() -> None:
    audit = StubAudit()
    with pytest.raises(ValueError, match="syntactically-valid"):
        LocalLlmClient(base_url="not-a-url", audit=audit)


@pytest.mark.asyncio
async def test_bypass_guard_refuses_non_gateway_context() -> None:
    audit = StubAudit()
    http = _mock_client(lambda req: httpx.Response(200, json=_ollama_success_body()))
    async with LocalLlmClient(
        base_url="http://localhost:11434", audit=audit, http_client=http
    ) as client:
        with pytest.raises(BypassAttemptBlockedError):
            await client.complete(
                ctx=_bypass_ctx(), model_id="llama3",
                system_prompt="sys", user_message="hi")
    assert "TIER_2_BYPASS_ATTEMPT_BLOCKED" in audit.actions()


@pytest.mark.asyncio
async def test_successful_call_captures_latency_and_compute_metrics() -> None:
    audit = StubAudit()
    http = _mock_client(lambda req: httpx.Response(200, json=_ollama_success_body()))
    async with LocalLlmClient(
        base_url="http://localhost:11434", audit=audit, http_client=http
    ) as client:
        result = await client.complete(
            ctx=_gateway_ctx(), model_id="llama3",
            system_prompt="normalize", user_message="ACME LTD.")
    assert result.eval_count == 17
    assert result.eval_duration_ms == 900  # 900_000_000 ns → 900 ms
    assert result.parsed_json == {"n": "Acme Ltd"}
    assert audit.actions() == ["TIER_2_INVOKED", "TIER_2_RESPONSE_RECEIVED"]


@pytest.mark.asyncio
async def test_http_500_maps_to_transient_and_ticks_breaker() -> None:
    audit = StubAudit()
    breaker = CircuitBreaker(failure_threshold=10, recovery_timeout_s=30)
    http = _mock_client(lambda req: httpx.Response(503, text="upstream down"))
    async with LocalLlmClient(
        base_url="http://localhost:11434", audit=audit,
        breaker=breaker, http_client=http,
    ) as client:
        with pytest.raises(ModelError) as exc:
            await client.complete(
                ctx=_gateway_ctx(), model_id="llama3",
                system_prompt="sys", user_message="hi")
    assert exc.value.transient is True
    assert exc.value.code == "SERVER_ERROR_503"
    assert breaker.failure_count == 1


@pytest.mark.asyncio
async def test_network_error_maps_to_transient_and_ticks_breaker() -> None:
    audit = StubAudit()
    breaker = CircuitBreaker(failure_threshold=10, recovery_timeout_s=30)

    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    http = _mock_client(handler)
    async with LocalLlmClient(
        base_url="http://localhost:11434", audit=audit,
        breaker=breaker, http_client=http,
    ) as client:
        with pytest.raises(ModelError) as exc:
            await client.complete(
                ctx=_gateway_ctx(), model_id="llama3",
                system_prompt="sys", user_message="hi")
    assert exc.value.transient is True
    assert exc.value.code == "NETWORK_ERROR"
    assert breaker.failure_count == 1


@pytest.mark.asyncio
async def test_breaker_open_short_circuits_without_http_call() -> None:
    audit = StubAudit()
    breaker = CircuitBreaker(failure_threshold=1, recovery_timeout_s=60)
    breaker.on_failure()  # OPEN
    assert breaker.state is BreakerState.OPEN

    calls = {"count": 0}

    def handler(req: httpx.Request) -> httpx.Response:
        calls["count"] += 1
        return httpx.Response(200, json=_ollama_success_body())

    http = _mock_client(handler)
    async with LocalLlmClient(
        base_url="http://localhost:11434", audit=audit,
        breaker=breaker, http_client=http,
    ) as client:
        with pytest.raises(ModelError) as exc:
            await client.complete(
                ctx=_gateway_ctx(), model_id="llama3",
                system_prompt="sys", user_message="hi")
    assert exc.value.code == "CIRCUIT_OPEN"
    assert exc.value.transient is True
    assert calls["count"] == 0, "OPEN breaker must short-circuit without HTTP"
    assert "TIER_2_INVOKED" not in audit.actions(), (
        "OPEN short-circuit should not emit TIER_2_INVOKED (no actual dispatch)")
    assert "TIER_2_FAILED" in audit.actions()


@pytest.mark.asyncio
async def test_closed_to_open_transition_emits_breaker_opened_once() -> None:
    audit = StubAudit()
    breaker = CircuitBreaker(failure_threshold=2, recovery_timeout_s=30)

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(503, text="upstream down")

    http = _mock_client(handler)
    async with LocalLlmClient(
        base_url="http://localhost:11434", audit=audit,
        breaker=breaker, http_client=http,
    ) as client:
        # Two consecutive failures → CLOSED → OPEN on the second.
        for _ in range(2):
            with pytest.raises(ModelError):
                await client.complete(
                    ctx=_gateway_ctx(), model_id="llama3",
                    system_prompt="sys", user_message="hi")
    opened_events = [e for e in audit.events if e.action == "TIER_2_CIRCUIT_BREAKER_OPENED"]
    assert len(opened_events) == 1, (
        f"expected exactly one TIER_2_CIRCUIT_BREAKER_OPENED on CLOSED→OPEN, "
        f"got {len(opened_events)}")
    assert opened_events[0].payload["previous_state"] == "CLOSED"
    assert opened_events[0].payload["failure_count"] == 2


@pytest.mark.asyncio
async def test_health_check_failure_emits_audit_and_returns_false() -> None:
    audit = StubAudit()
    breaker = CircuitBreaker(failure_threshold=10, recovery_timeout_s=30)

    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    http = _mock_client(handler)
    async with LocalLlmClient(
        base_url="http://localhost:11434", audit=audit,
        breaker=breaker, http_client=http,
    ) as client:
        result = await client.health_check(business_id=uuid4())
    assert result is False
    assert "TIER_2_HEALTH_CHECK_FAILED" in audit.actions()
    assert breaker.failure_count == 1
