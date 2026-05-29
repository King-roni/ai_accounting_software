"""AnthropicEUClient — Tier 3 model dispatch.

Uses the EU-residency / zero-retention endpoint via Anthropic's documented
opt-in headers (``anthropic-region: eu`` and ``anthropic-beta:
zero-retention-2024``). The base URL is verified at construction time —
overriding to a non-Anthropic host raises rather than silently dispatching to
an attacker-controlled URL.

The Anthropic API key is fetched from ``secrets.managed_secrets`` via
``secrets.get_secret('anthropic_api_key', NULL)`` over the Supabase
service-role RPC channel. ``os.environ['ANTHROPIC_API_KEY']`` is never read
in long-lived processes — the lint at
``scripts/lint_no_direct_ai_imports.py`` allow-lists this directory for the
Anthropic SDK, but reading env vars is still forbidden by code review (and
covered by the test ``test_request_uses_key_from_get_secret_not_env``).
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Protocol
from uuid import UUID

import httpx

from cyprus_bookkeeping_api.ai_integrations.call_context import CallContext
from cyprus_bookkeeping_api.ai_integrations.errors import (
    BypassAttemptBlockedError,
    ModelError,
    SecretMissingError,
)

ANTHROPIC_EU_BASE_URL = "https://api.anthropic.com"
ANTHROPIC_API_VERSION = "2023-06-01"
ANTHROPIC_BETA_ZERO_RETENTION = "zero-retention-2024"
ANTHROPIC_REGION_HEADER = "eu"
DEFAULT_TIMEOUT_S = 30.0


class SecretsReader(Protocol):
    """Indirection so tests can stub out the Supabase RPC call."""

    def get_secret(self, name: str, actor_user_id: UUID | None = None) -> str | None: ...


class AuditEmitter(Protocol):
    """Indirection so tests can stub out the record_ai_tier3_event RPC."""

    def record_tier3_event(
        self,
        *,
        action: str,
        business_id: UUID,
        invocation_id: UUID | None,
        actor_user_id: UUID | None,
        payload: dict,
    ) -> None: ...


@dataclass(frozen=True, slots=True)
class CompletionResult:
    """Successful Tier 3 completion."""

    raw_response: dict
    """The provider's parsed JSON response body."""

    extracted_text: str
    """First text content block, concatenated."""

    parsed_json: dict | None
    """Strict ``json.loads`` of ``extracted_text`` if it parses; otherwise None.
    No best-effort recovery — strict-validation principle (B06·P02 spec)."""

    input_tokens: int
    output_tokens: int
    model_id: str
    latency_ms: int


class AnthropicEUClient:
    """Async HTTP client for Anthropic Claude (EU / zero-retention).

    Use ``async with`` for proper httpx client lifecycle, or pass an
    ``httpx.AsyncClient`` via ``http_client`` (useful in tests with
    ``httpx.MockTransport``).
    """

    def __init__(
        self,
        *,
        secrets: SecretsReader,
        audit: AuditEmitter,
        base_url: str = ANTHROPIC_EU_BASE_URL,
        timeout_s: float = DEFAULT_TIMEOUT_S,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        if not base_url.startswith("https://api.anthropic.com"):
            raise ValueError(
                f"AnthropicEUClient: base_url must be the Anthropic-owned host; "
                f"refusing {base_url!r} to prevent dispatch to non-Anthropic hosts."
            )
        self._secrets = secrets
        self._audit = audit
        self._base_url = base_url.rstrip("/")
        self._timeout_s = timeout_s
        self._http_client = http_client
        self._owns_client = http_client is None
        self._api_key: str | None = None

    async def __aenter__(self) -> AnthropicEUClient:
        if self._http_client is None:
            self._http_client = httpx.AsyncClient(timeout=self._timeout_s)
        return self

    async def __aexit__(self, *_: Any) -> None:
        if self._owns_client and self._http_client is not None:
            await self._http_client.aclose()
            self._http_client = None

    def _resolve_api_key(self) -> str:
        if self._api_key is None:
            value = self._secrets.get_secret("anthropic_api_key", None)
            if value is None or value == "":
                raise SecretMissingError(
                    "Anthropic API key not provisioned in secrets.managed_secrets "
                    "(secret_name='anthropic_api_key'). The SECRET_ACCESS_DENIED or "
                    "SECRET_ACCESS_FAILED audit emitted by secrets.get_secret carries "
                    "the diagnostic reason_code."
                )
            self._api_key = value
        return self._api_key

    async def complete(
        self,
        *,
        ctx: CallContext,
        model_id: str,
        system_prompt: str,
        user_message: str,
        max_tokens: int = 1024,
        temperature: float = 0.0,
    ) -> CompletionResult:
        """Dispatch one prompt to Claude and return parsed result.

        Raises:
            BypassAttemptBlockedError: ``ctx.via_gateway`` is False.
            SecretMissingError: API key not in vault.
            ModelError: HTTP / transport failure mapped per spec error table.
        """
        if not ctx.via_gateway:
            self._audit.record_tier3_event(
                action="TIER_3_BYPASS_ATTEMPT_BLOCKED",
                business_id=ctx.business_id,
                invocation_id=ctx.invocation_id,
                actor_user_id=ctx.actor_user_id,
                payload={
                    "model_id": model_id,
                    "reason": "CallContext.via_gateway is False",
                },
            )
            raise BypassAttemptBlockedError(
                "Direct Tier 3 dispatch is forbidden — call must originate from "
                "ai_gateway_invoke_begin via tier3_dispatch."
            )

        api_key = self._resolve_api_key()
        assert self._http_client is not None, (
            "AnthropicEUClient.complete called outside async-with; "
            "use 'async with AnthropicEUClient(...) as client:' or pass http_client."
        )

        payload = {
            "model": model_id,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "system": system_prompt,
            "messages": [{"role": "user", "content": user_message}],
        }
        headers = {
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_API_VERSION,
            "anthropic-beta": ANTHROPIC_BETA_ZERO_RETENTION,
            "anthropic-region": ANTHROPIC_REGION_HEADER,
            "content-type": "application/json",
        }

        self._audit.record_tier3_event(
            action="TIER_3_INVOKED",
            business_id=ctx.business_id,
            invocation_id=ctx.invocation_id,
            actor_user_id=ctx.actor_user_id,
            payload={
                "model_id": model_id,
                "max_tokens": max_tokens,
                "temperature": temperature,
            },
        )

        start = time.monotonic()
        try:
            resp = await self._http_client.post(
                f"{self._base_url}/v1/messages",
                json=payload,
                headers=headers,
            )
        except httpx.TimeoutException as exc:
            latency_ms = int((time.monotonic() - start) * 1000)
            err = ModelError(transient=True, code="TIMEOUT", http_status=None,
                             message=str(exc))
            self._emit_failure(ctx, model_id, err, latency_ms)
            raise err from exc
        except httpx.NetworkError as exc:
            latency_ms = int((time.monotonic() - start) * 1000)
            err = ModelError(transient=True, code="NETWORK_ERROR", http_status=None,
                             message=str(exc))
            self._emit_failure(ctx, model_id, err, latency_ms)
            raise err from exc

        latency_ms = int((time.monotonic() - start) * 1000)

        if resp.status_code != 200:
            err = self._map_http_error(resp)
            self._emit_failure(ctx, model_id, err, latency_ms)
            raise err

        body = resp.json()
        result = self._parse_success(body, model_id, latency_ms)
        self._audit.record_tier3_event(
            action="TIER_3_RESPONSE_RECEIVED",
            business_id=ctx.business_id,
            invocation_id=ctx.invocation_id,
            actor_user_id=ctx.actor_user_id,
            payload={
                "model_id": result.model_id,
                "input_tokens": result.input_tokens,
                "output_tokens": result.output_tokens,
                "latency_ms": result.latency_ms,
                "parsed_json": result.parsed_json is not None,
            },
        )
        return result

    @staticmethod
    def _map_http_error(resp: httpx.Response) -> ModelError:
        status = resp.status_code
        try:
            body_text = resp.text[:500]
        except Exception:  # pragma: no cover — body read shouldn't fail post-response
            body_text = ""
        if status == 429:
            return ModelError(transient=True, code="RATE_LIMIT", http_status=429,
                              message=body_text or "rate limited")
        if status == 408:
            return ModelError(transient=True, code="TIMEOUT", http_status=408,
                              message=body_text or "server timeout")
        if 500 <= status < 600:
            return ModelError(transient=True, code=f"SERVER_ERROR_{status}",
                              http_status=status, message=body_text or "server error")
        return ModelError(transient=False, code=f"CLIENT_ERROR_{status}",
                          http_status=status, message=body_text or "client error")

    @staticmethod
    def _parse_success(body: dict, fallback_model_id: str, latency_ms: int) -> CompletionResult:
        content_blocks = body.get("content") or []
        text_parts = [b.get("text", "") for b in content_blocks if b.get("type") == "text"]
        extracted = "".join(text_parts)
        parsed: dict | None = None
        if extracted.strip().startswith("{"):
            try:
                candidate = json.loads(extracted)
                if isinstance(candidate, dict):
                    parsed = candidate
            except json.JSONDecodeError:
                parsed = None
        usage = body.get("usage") or {}
        return CompletionResult(
            raw_response=body,
            extracted_text=extracted,
            parsed_json=parsed,
            input_tokens=int(usage.get("input_tokens", 0) or 0),
            output_tokens=int(usage.get("output_tokens", 0) or 0),
            model_id=body.get("model") or fallback_model_id,
            latency_ms=latency_ms,
        )

    def _emit_failure(
        self, ctx: CallContext, model_id: str, err: ModelError, latency_ms: int
    ) -> None:
        self._audit.record_tier3_event(
            action="TIER_3_FAILED",
            business_id=ctx.business_id,
            invocation_id=ctx.invocation_id,
            actor_user_id=ctx.actor_user_id,
            payload={
                "model_id": model_id,
                "code": err.code,
                "transient": err.transient,
                "http_status": err.http_status,
                "latency_ms": latency_ms,
            },
        )
