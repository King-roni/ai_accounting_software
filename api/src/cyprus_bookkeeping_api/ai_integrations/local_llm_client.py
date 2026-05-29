"""LocalLlmClient — Tier 2 (local LLM) dispatch.

Talks to an Ollama-compatible endpoint on the operator's hardware over a
private channel (Tailscale / WireGuard / mTLS — final choice in the network-
architecture sub-doc). The request/response shape matches Ollama's
``POST /api/chat`` and ``GET /api/tags`` (health). Switching to vLLM /
llama.cpp would be a small adapter change inside this module.

Pairs with :class:`CircuitBreaker` — every HTTP / transport failure trips the
counter; HALF_OPEN probes are allowed after the cool-down. The
``TIER_2_CIRCUIT_BREAKER_OPENED`` audit fires exactly once per CLOSED→OPEN
transition so the audit log shows the outage onset, not every short-circuited
call during the OPEN window.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import urlparse
from uuid import UUID

import httpx

from cyprus_bookkeeping_api.ai_integrations.call_context import CallContext
from cyprus_bookkeeping_api.ai_integrations.circuit_breaker import (
    AttemptDecision,
    BreakerState,
    CircuitBreaker,
)
from cyprus_bookkeeping_api.ai_integrations.errors import (
    BypassAttemptBlockedError,
    ModelError,
)

DEFAULT_TIMEOUT_S = 60.0  # local LLM is slower than Anthropic for the same task


class Tier2AuditEmitter(Protocol):
    def record_tier2_event(
        self,
        *,
        action: str,
        business_id: UUID,
        invocation_id: UUID | None,
        actor_user_id: UUID | None,
        payload: dict,
    ) -> None: ...


@dataclass(frozen=True, slots=True)
class LocalCompletionResult:
    raw_response: dict
    extracted_text: str
    parsed_json: dict | None
    model_id: str
    latency_ms: int
    eval_count: int
    """Number of output tokens reported by Ollama."""
    eval_duration_ms: int
    """Time the model spent generating, in milliseconds (Ollama 'eval_duration')."""


class LocalLlmClient:
    """Async HTTP client for an Ollama-compatible local LLM."""

    def __init__(
        self,
        *,
        base_url: str,
        audit: Tier2AuditEmitter,
        breaker: CircuitBreaker | None = None,
        timeout_s: float = DEFAULT_TIMEOUT_S,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        parsed = urlparse(base_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ValueError(
                f"LocalLlmClient: base_url must be a syntactically-valid http(s) URL; "
                f"refusing {base_url!r}."
            )
        self._base_url = base_url.rstrip("/")
        self._audit = audit
        self._breaker = breaker or CircuitBreaker()
        self._timeout_s = timeout_s
        self._http_client = http_client
        self._owns_client = http_client is None

    async def __aenter__(self) -> LocalLlmClient:
        if self._http_client is None:
            self._http_client = httpx.AsyncClient(timeout=self._timeout_s)
        return self

    async def __aexit__(self, *_: Any) -> None:
        if self._owns_client and self._http_client is not None:
            await self._http_client.aclose()
            self._http_client = None

    @property
    def breaker(self) -> CircuitBreaker:
        return self._breaker

    async def health_check(self, *, business_id: UUID, actor_user_id: UUID | None = None) -> bool:
        """Probe ``GET /api/tags``. Records a breaker failure on error and
        emits ``TIER_2_HEALTH_CHECK_FAILED``. Does *not* emit on success
        (probing successfully is the steady state)."""
        assert self._http_client is not None, (
            "LocalLlmClient.health_check called outside async-with"
        )
        try:
            resp = await self._http_client.get(f"{self._base_url}/api/tags")
        except (httpx.TimeoutException, httpx.NetworkError) as exc:
            self._emit_health_failure(business_id, actor_user_id,
                                      reason=type(exc).__name__, message=str(exc))
            self._on_breaker_failure(business_id, actor_user_id,
                                     reason=f"health_check_{type(exc).__name__}")
            return False
        if resp.status_code != 200:
            self._emit_health_failure(business_id, actor_user_id,
                                      reason=f"http_{resp.status_code}", message=resp.text[:200])
            self._on_breaker_failure(business_id, actor_user_id,
                                     reason=f"health_check_http_{resp.status_code}")
            return False
        self._breaker.on_success()
        return True

    async def complete(
        self,
        *,
        ctx: CallContext,
        model_id: str,
        system_prompt: str,
        user_message: str,
        max_tokens: int = 1024,
        temperature: float = 0.0,
    ) -> LocalCompletionResult:
        """Dispatch one prompt to the local LLM.

        Raises:
            BypassAttemptBlockedError: ``ctx.via_gateway`` is False.
            ModelError: breaker OPEN, HTTP failure, or transport failure
                (always carries ``transient=True`` because the local LLM
                being unreachable is by nature a transient operator-side
                condition).
        """
        if not ctx.via_gateway:
            self._audit.record_tier2_event(
                action="TIER_2_BYPASS_ATTEMPT_BLOCKED",
                business_id=ctx.business_id,
                invocation_id=ctx.invocation_id,
                actor_user_id=ctx.actor_user_id,
                payload={
                    "model_id": model_id,
                    "reason": "CallContext.via_gateway is False",
                },
            )
            raise BypassAttemptBlockedError(
                "Direct Tier 2 dispatch is forbidden — call must originate from "
                "the gateway."
            )

        decision: AttemptDecision = self._breaker.should_attempt()
        if not decision.allow:
            # Breaker OPEN within recovery window → short-circuit. The
            # TIER_2_CIRCUIT_BREAKER_OPENED audit was emitted at the
            # CLOSED→OPEN transition; we emit TIER_2_FAILED here so the
            # invocation row still gets a per-call audit.
            err = ModelError(
                transient=True, code="CIRCUIT_OPEN", http_status=None,
                message=f"local LLM circuit breaker is {decision.state.value} "
                        f"({decision.reason})",
            )
            self._emit_failure(ctx, model_id, err, latency_ms=0,
                               breaker=self._breaker.snapshot())
            raise err

        assert self._http_client is not None, (
            "LocalLlmClient.complete called outside async-with"
        )

        payload = {
            "model": model_id,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_message},
            ],
            "stream": False,
            "options": {"temperature": temperature, "num_predict": max_tokens},
        }

        self._audit.record_tier2_event(
            action="TIER_2_INVOKED",
            business_id=ctx.business_id,
            invocation_id=ctx.invocation_id,
            actor_user_id=ctx.actor_user_id,
            payload={
                "model_id": model_id,
                "max_tokens": max_tokens,
                "temperature": temperature,
                "breaker_state_before": decision.state.value,
            },
        )

        start = time.monotonic()
        try:
            resp = await self._http_client.post(
                f"{self._base_url}/api/chat",
                json=payload,
            )
        except httpx.TimeoutException as exc:
            latency_ms = int((time.monotonic() - start) * 1000)
            err = ModelError(transient=True, code="TIMEOUT", http_status=None,
                             message=str(exc))
            self._on_breaker_failure(ctx.business_id, ctx.actor_user_id,
                                     reason="dispatch_timeout")
            self._emit_failure(ctx, model_id, err, latency_ms,
                               breaker=self._breaker.snapshot())
            raise err from exc
        except httpx.NetworkError as exc:
            latency_ms = int((time.monotonic() - start) * 1000)
            err = ModelError(transient=True, code="NETWORK_ERROR", http_status=None,
                             message=str(exc))
            self._on_breaker_failure(ctx.business_id, ctx.actor_user_id,
                                     reason="dispatch_network_error")
            self._emit_failure(ctx, model_id, err, latency_ms,
                               breaker=self._breaker.snapshot())
            raise err from exc

        latency_ms = int((time.monotonic() - start) * 1000)

        if resp.status_code != 200:
            status = resp.status_code
            transient = status == 429 or 500 <= status < 600
            err = ModelError(
                transient=transient,
                code=("RATE_LIMIT" if status == 429
                      else f"SERVER_ERROR_{status}" if 500 <= status < 600
                      else f"CLIENT_ERROR_{status}"),
                http_status=status,
                message=resp.text[:500],
            )
            self._on_breaker_failure(ctx.business_id, ctx.actor_user_id,
                                     reason=f"dispatch_http_{status}")
            self._emit_failure(ctx, model_id, err, latency_ms,
                               breaker=self._breaker.snapshot())
            raise err

        # Success
        self._breaker.on_success()
        body = resp.json()
        result = self._parse_success(body, model_id, latency_ms)
        self._audit.record_tier2_event(
            action="TIER_2_RESPONSE_RECEIVED",
            business_id=ctx.business_id,
            invocation_id=ctx.invocation_id,
            actor_user_id=ctx.actor_user_id,
            payload={
                "model_id": result.model_id,
                "latency_ms": result.latency_ms,
                "eval_count": result.eval_count,
                "eval_duration_ms": result.eval_duration_ms,
                "parsed_json": result.parsed_json is not None,
            },
        )
        return result

    # -------- helpers --------------------------------------------------------

    @staticmethod
    def _parse_success(body: dict, fallback_model_id: str, latency_ms: int) -> LocalCompletionResult:
        message = body.get("message") or {}
        content = message.get("content") or ""
        parsed: dict | None = None
        if content.strip().startswith("{"):
            try:
                candidate = json.loads(content)
                if isinstance(candidate, dict):
                    parsed = candidate
            except json.JSONDecodeError:
                parsed = None
        # Ollama timing fields are in nanoseconds.
        eval_duration_ns = int(body.get("eval_duration") or 0)
        return LocalCompletionResult(
            raw_response=body,
            extracted_text=content,
            parsed_json=parsed,
            model_id=body.get("model") or fallback_model_id,
            latency_ms=latency_ms,
            eval_count=int(body.get("eval_count") or 0),
            eval_duration_ms=eval_duration_ns // 1_000_000,
        )

    def _on_breaker_failure(self, business_id: UUID, actor_user_id: UUID | None,
                            *, reason: str) -> None:
        """Tick the breaker; if it just opened, emit the OPENED audit once."""
        just_opened = self._breaker.on_failure()
        if just_opened:
            self._audit.record_tier2_event(
                action="TIER_2_CIRCUIT_BREAKER_OPENED",
                business_id=business_id,
                invocation_id=None,
                actor_user_id=actor_user_id,
                payload={
                    "trigger_reason": reason,
                    **self._breaker.snapshot(),
                    "previous_state": BreakerState.CLOSED.value,
                },
            )

    def _emit_health_failure(self, business_id: UUID, actor_user_id: UUID | None,
                             *, reason: str, message: str) -> None:
        self._audit.record_tier2_event(
            action="TIER_2_HEALTH_CHECK_FAILED",
            business_id=business_id,
            invocation_id=None,
            actor_user_id=actor_user_id,
            payload={
                "endpoint": f"{self._base_url}/api/tags",
                "reason": reason,
                "message": message[:500],
            },
        )

    def _emit_failure(
        self,
        ctx: CallContext,
        model_id: str,
        err: ModelError,
        latency_ms: int,
        *,
        breaker: dict,
    ) -> None:
        self._audit.record_tier2_event(
            action="TIER_2_FAILED",
            business_id=ctx.business_id,
            invocation_id=ctx.invocation_id,
            actor_user_id=ctx.actor_user_id,
            payload={
                "model_id": model_id,
                "code": err.code,
                "transient": err.transient,
                "http_status": err.http_status,
                "latency_ms": latency_ms,
                "breaker": breaker,
            },
        )
