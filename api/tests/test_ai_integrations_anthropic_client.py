"""B06·P05 — Anthropic Tier 3 client tests.

Mocks ``httpx.AsyncClient`` via ``httpx.MockTransport`` so no real network
calls happen. Mocks ``secrets.get_secret`` via the ``SecretsReader`` protocol
stub. Audit emission is captured by a stub ``AuditEmitter`` so the test can
assert which TIER_3_* events fire and in what order.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest

from cyprus_bookkeeping_api.ai_integrations import (
    AnthropicEUClient,
    BypassAttemptBlockedError,
    CallContext,
    ModelError,
    SecretMissingError,
)


# ---------- Stubs ----------------------------------------------------------------

class StubSecrets:
    """In-memory replacement for secrets.get_secret. Records every call."""

    def __init__(self, key: str | None = "sk-test-fake-anthropic-key") -> None:
        self.key = key
        self.calls: list[tuple[str, UUID | None]] = []

    def get_secret(self, name: str, actor_user_id: UUID | None = None) -> str | None:
        self.calls.append((name, actor_user_id))
        if name == "anthropic_api_key":
            return self.key
        return None


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

    def record_tier3_event(
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


def _gateway_ctx(actor_user_id: UUID | None = None) -> CallContext:
    return CallContext(
        via_gateway=True,
        invocation_id=uuid4(),
        business_id=uuid4(),
        actor_user_id=actor_user_id,
    )


def _bypass_ctx() -> CallContext:
    return CallContext(
        via_gateway=False,
        invocation_id=uuid4(),
        business_id=uuid4(),
        actor_user_id=None,
    )


def _success_body(text: str = '{"n":"Acme Ltd"}', model_id: str = "claude-sonnet-4-6") -> dict:
    return {
        "id": "msg_test_001",
        "model": model_id,
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": text}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 42, "output_tokens": 13},
    }


def _mock_client_returning(handler: Any) -> httpx.AsyncClient:
    transport = httpx.MockTransport(handler)
    return httpx.AsyncClient(transport=transport, timeout=5.0)


# ---------- Construction-time checks ---------------------------------------------

def test_eu_endpoint_verified_at_construction() -> None:
    secrets = StubSecrets()
    audit = StubAudit()
    with pytest.raises(ValueError, match="Anthropic-owned host"):
        AnthropicEUClient(
            secrets=secrets, audit=audit,
            base_url="https://api.attacker.example/v1")


# ---------- Bypass guard ---------------------------------------------------------

@pytest.mark.asyncio
async def test_bypass_guard_refuses_non_gateway_context() -> None:
    secrets = StubSecrets()
    audit = StubAudit()
    http = _mock_client_returning(lambda req: httpx.Response(200, json=_success_body()))
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        with pytest.raises(BypassAttemptBlockedError):
            await client.complete(
                ctx=_bypass_ctx(), model_id="claude-sonnet-4-6",
                system_prompt="sys", user_message="hi")
    # Audit must record the bypass attempt.
    assert "TIER_3_BYPASS_ATTEMPT_BLOCKED" in audit.actions()
    # Bypass guard must run BEFORE secrets resolution — no key fetched.
    assert secrets.calls == []


# ---------- Error mapping --------------------------------------------------------

@pytest.mark.asyncio
async def test_429_maps_to_transient_model_error() -> None:
    secrets = StubSecrets()
    audit = StubAudit()
    http = _mock_client_returning(lambda req: httpx.Response(429, text="rate limited"))
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        with pytest.raises(ModelError) as exc:
            await client.complete(
                ctx=_gateway_ctx(), model_id="claude-sonnet-4-6",
                system_prompt="sys", user_message="hi")
    assert exc.value.transient is True
    assert exc.value.code == "RATE_LIMIT"
    assert exc.value.http_status == 429
    assert "TIER_3_FAILED" in audit.actions()


@pytest.mark.asyncio
async def test_500_maps_to_transient_model_error() -> None:
    secrets = StubSecrets()
    audit = StubAudit()
    http = _mock_client_returning(lambda req: httpx.Response(503, text="upstream down"))
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        with pytest.raises(ModelError) as exc:
            await client.complete(
                ctx=_gateway_ctx(), model_id="claude-sonnet-4-6",
                system_prompt="sys", user_message="hi")
    assert exc.value.transient is True
    assert exc.value.code == "SERVER_ERROR_503"


@pytest.mark.asyncio
async def test_400_maps_to_non_transient_model_error() -> None:
    secrets = StubSecrets()
    audit = StubAudit()
    http = _mock_client_returning(lambda req: httpx.Response(400, text="bad request"))
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        with pytest.raises(ModelError) as exc:
            await client.complete(
                ctx=_gateway_ctx(), model_id="claude-sonnet-4-6",
                system_prompt="sys", user_message="hi")
    assert exc.value.transient is False
    assert exc.value.code == "CLIENT_ERROR_400"


@pytest.mark.asyncio
async def test_timeout_maps_to_transient_model_error() -> None:
    secrets = StubSecrets()
    audit = StubAudit()

    def raise_timeout(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("simulated timeout")

    http = _mock_client_returning(raise_timeout)
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        with pytest.raises(ModelError) as exc:
            await client.complete(
                ctx=_gateway_ctx(), model_id="claude-sonnet-4-6",
                system_prompt="sys", user_message="hi")
    assert exc.value.transient is True
    assert exc.value.code == "TIMEOUT"


# ---------- Success path ---------------------------------------------------------

@pytest.mark.asyncio
async def test_successful_call_captures_token_counts_and_parses_json() -> None:
    secrets = StubSecrets()
    audit = StubAudit()
    http = _mock_client_returning(lambda req: httpx.Response(200, json=_success_body()))
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        result = await client.complete(
            ctx=_gateway_ctx(), model_id="claude-sonnet-4-6",
            system_prompt="normalize", user_message="ACME LTD.")
    assert result.input_tokens == 42
    assert result.output_tokens == 13
    assert result.model_id == "claude-sonnet-4-6"
    assert result.parsed_json == {"n": "Acme Ltd"}
    assert audit.actions() == ["TIER_3_INVOKED", "TIER_3_RESPONSE_RECEIVED"]


# ---------- Headers ------------------------------------------------------------

@pytest.mark.asyncio
async def test_request_includes_required_headers() -> None:
    secrets = StubSecrets(key="sk-test-AAA")
    audit = StubAudit()
    seen: dict[str, httpx.Headers] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen["headers"] = req.headers
        return httpx.Response(200, json=_success_body())

    http = _mock_client_returning(handler)
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        await client.complete(
            ctx=_gateway_ctx(), model_id="claude-sonnet-4-6",
            system_prompt="sys", user_message="hi")
    h = seen["headers"]
    assert h.get("anthropic-version") == "2023-06-01"
    assert h.get("anthropic-beta") == "zero-retention-2024"
    assert h.get("anthropic-region") == "eu"
    assert h.get("x-api-key") == "sk-test-AAA"


# ---------- Secret resolution path ----------------------------------------------

@pytest.mark.asyncio
async def test_request_uses_key_from_get_secret_not_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """If somebody sneaks an env var into the deployment, it must not leak.

    The test sets ANTHROPIC_API_KEY in env and a different value via secrets.
    The request must carry the secrets-provisioned value.
    """
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-env-LEAKED")
    secrets = StubSecrets(key="sk-from-vault-OK")
    audit = StubAudit()
    seen: dict[str, str | None] = {}

    def handler(req: httpx.Request) -> httpx.Response:
        seen["key"] = req.headers.get("x-api-key")
        return httpx.Response(200, json=_success_body())

    http = _mock_client_returning(handler)
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        await client.complete(
            ctx=_gateway_ctx(), model_id="claude-sonnet-4-6",
            system_prompt="sys", user_message="hi")
    assert seen["key"] == "sk-from-vault-OK"
    assert secrets.calls == [("anthropic_api_key", None)]
    # Make sure clean-up still happens if the assertion fails above.
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)


@pytest.mark.asyncio
async def test_secret_missing_raises_secret_missing_error() -> None:
    secrets = StubSecrets(key=None)  # vault has no row
    audit = StubAudit()
    http = _mock_client_returning(lambda req: httpx.Response(200, json=_success_body()))
    async with AnthropicEUClient(
        secrets=secrets, audit=audit, http_client=http
    ) as client:
        with pytest.raises(SecretMissingError):
            await client.complete(
                ctx=_gateway_ctx(), model_id="claude-sonnet-4-6",
                system_prompt="sys", user_message="hi")
