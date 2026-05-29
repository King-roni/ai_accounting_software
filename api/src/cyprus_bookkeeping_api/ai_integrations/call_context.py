"""CallContext — the runtime half of bypass detection.

Every entry point in ``ai_integrations`` requires a ``CallContext`` argument.
The integration refuses to dispatch (raising
:class:`BypassAttemptBlockedError`) when ``via_gateway`` is False. This is the
runtime complement to the static lint at
``scripts/lint_no_direct_ai_imports.py`` — between the two, direct-Anthropic
calls outside the gateway are caught at code-review (lint) and at runtime
(here).
"""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID


@dataclass(frozen=True, slots=True)
class CallContext:
    """Context passed by the gateway dispatcher to every provider call.

    Attributes:
        via_gateway: Must be True for the call to be accepted. Constructing a
            ``CallContext`` with ``via_gateway=False`` is the deliberate
            "I am bypassing the gateway" signal; the integration's bypass
            guard then emits a TIER_3_BYPASS_ATTEMPT_BLOCKED audit and refuses.
        invocation_id: The ``ai_gateway_invocations.id`` UUID returned by
            ``ai_gateway_invoke_begin``. Threaded through to the audit
            ``subject_id`` so every TIER_3_* event ties to a specific gateway
            invocation row.
        business_id: For audit attribution.
        actor_user_id: NULL means SYSTEM actor (engine-driven dispatch); UUID
            means a specific user initiated the workflow that reached this
            call.
    """

    via_gateway: bool
    invocation_id: UUID
    business_id: UUID
    actor_user_id: UUID | None = None
