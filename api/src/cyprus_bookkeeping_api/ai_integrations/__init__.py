"""AI provider integrations.

This package is the **only** place in the codebase allowed to import Anthropic
/ OpenAI / local-LLM SDKs directly. The bypass-detection lint at
``scripts/lint_no_direct_ai_imports.py`` allow-lists exactly this directory
(plus ``web/src/lib/ai_integrations``).

Every external dispatch goes through ``ai_gateway_invoke_begin`` →
provider client → ``ai_gateway_invoke_finalize`` so the gateway pipeline
(B06·P02) is the only path that reaches a model.

Tier 3 (Anthropic Claude EU/zero-retention) lives in ``anthropic_client``;
Tier 2 (local LLM) ships in B06·P06.
"""

from cyprus_bookkeeping_api.ai_integrations.anthropic_client import (
    AnthropicEUClient,
    CompletionResult,
)
from cyprus_bookkeeping_api.ai_integrations.call_context import CallContext
from cyprus_bookkeeping_api.ai_integrations.circuit_breaker import (
    BreakerState,
    CircuitBreaker,
)
from cyprus_bookkeeping_api.ai_integrations.errors import (
    BypassAttemptBlockedError,
    ModelError,
    SecretMissingError,
)
from cyprus_bookkeeping_api.ai_integrations.local_llm_client import (
    LocalCompletionResult,
    LocalLlmClient,
)

__all__ = [
    "AnthropicEUClient",
    "BreakerState",
    "BypassAttemptBlockedError",
    "CallContext",
    "CircuitBreaker",
    "CompletionResult",
    "LocalCompletionResult",
    "LocalLlmClient",
    "ModelError",
    "SecretMissingError",
]
