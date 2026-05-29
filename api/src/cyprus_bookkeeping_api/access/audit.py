"""Audit emission shim for the access module.

Block 05 Phase 02 owns the real hash-chained emitter (`emitAudit` per
`Docs/sub/tools/tool_can_perform_helper.md`). Until then this module
provides a registerable emitter so call sites are stable; the default
stub logs via stdlib `logging` without any persistence.
"""
from __future__ import annotations

import logging
from typing import Protocol
from uuid import UUID

from cyprus_bookkeeping_api.access.enums import DenyReason, PermissionSurface
from cyprus_bookkeeping_api.access.principal import PrincipalLike

_logger = logging.getLogger("cyprus_bookkeeping_api.access.audit")


class AuditEmitter(Protocol):
    """Stable contract Block 05 will implement."""

    def __call__(self, event_type: str, payload: dict[str, object]) -> None: ...


_emitter: AuditEmitter | None = None


def register_audit_emitter(emitter: AuditEmitter | None) -> None:
    """Register the real Block-05 emitter at app startup. Pass `None` to reset
    to the stub (test convenience).
    """
    global _emitter
    _emitter = emitter


def _emit(event_type: str, payload: dict[str, object]) -> None:
    if _emitter is not None:
        _emitter(event_type, payload)
        return
    _logger.info("audit.stub event=%s payload=%s", event_type, payload)


def emit_cross_tenant_attempt(
    principal: PrincipalLike,
    surface: PermissionSurface,
    target_business_id: UUID,
    *,
    basis: str = "live",
) -> None:
    """High-severity event — fires whenever a principal references a
    business_id that does not match the one bound to their context.

    The explicit `cross_tenant: true` boolean is required by the B02·P10
    alerting layer (it lets the threshold rule match without parsing the
    reason string). Routed to the cross-tenant alerting runbook via Block
    05 in production.
    """
    _emit(
        "AUTH_PERMISSION_DENIED",
        {
            "user_id": str(principal.user_id),
            "principal_business_id": str(principal.business_id),
            "target_business_id": str(target_business_id),
            "surface": surface.value,
            "role_at_check": principal.role.value,
            "reason": DenyReason.CROSS_TENANT_ACCESS_ATTEMPT.value,
            "severity_hint": "HIGH",
            "cross_tenant": True,
            "decision_basis": basis,
        },
    )


def emit_access_denied(
    principal: PrincipalLike,
    surface: PermissionSurface,
    *,
    reason: DenyReason,
    basis: str = "live",
) -> None:
    _emit(
        "AUTH_PERMISSION_DENIED",
        {
            "user_id": str(principal.user_id),
            "business_id": str(principal.business_id),
            "surface": surface.value,
            "role_at_check": principal.role.value,
            "reason": reason.value,
            "cross_tenant": False,
            "decision_basis": basis,
        },
    )


def emit_access_granted(
    principal: PrincipalLike,
    surface: PermissionSurface,
    *,
    step_up: bool,
    basis: str = "live",
) -> None:
    """Only emitted for sensitive surfaces (see SENSITIVE_SURFACES_FOR_AUDIT)."""
    _emit(
        "AUTH_PERMISSION_GRANTED",
        {
            "user_id": str(principal.user_id),
            "business_id": str(principal.business_id),
            "surface": surface.value,
            "role_at_check": principal.role.value,
            "step_up_satisfied": step_up,
            "decision_basis": basis,
        },
    )
