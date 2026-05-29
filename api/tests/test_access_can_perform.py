"""Block 02 Phase 04 — `can_perform` behavior + cross-tenant invariants.

Covers DoD bullets:
  - Bookkeeper on Business A blocked on Business B (cross-tenant DENY).
  - READ_ONLY denied any write surface and produces an audit event.
  - canPerform is the only allow/deny path (no inline role checks tested).
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID, uuid4

import pytest

from cyprus_bookkeeping_api.access import (
    Decision,
    PermissionSurface,
    PrincipalContext,
    Role,
    can_perform,
    register_audit_emitter,
)
from cyprus_bookkeeping_api.access.enums import DenyReason

AuditEntry = tuple[str, dict[str, object]]


@pytest.fixture
def audit_sink() -> list[AuditEntry]:
    """Replace the audit emitter with a list-collecting stub, then reset."""
    captured: list[AuditEntry] = []

    def collector(event_type: str, payload: dict[str, object]) -> None:
        captured.append((event_type, payload))

    register_audit_emitter(collector)
    try:
        yield captured
    finally:
        register_audit_emitter(None)


def _principal(
    role: Role,
    *,
    business_id: UUID | None = None,
    mfa_recent_at: datetime | None = None,
) -> PrincipalContext:
    return PrincipalContext(
        user_id=uuid4(),
        organization_id=uuid4(),
        business_id=business_id or uuid4(),
        role=role,
        mfa_recent_at=mfa_recent_at,
    )


# ---------- DoD invariants ----------------------------------------------------


def test_bookkeeper_on_business_a_blocked_from_business_b(
    audit_sink: list[AuditEntry],
) -> None:
    """A user with role BOOKKEEPER on Business A cannot run workflows on Business B."""
    business_a = uuid4()
    business_b = uuid4()
    principal = _principal(Role.BOOKKEEPER, business_id=business_a)

    decision = can_perform(
        principal,
        PermissionSurface.WORKFLOW_TRIGGER,
        target_business_id=business_b,
    )

    assert decision is Decision.DENY
    # Single audit event with the cross-tenant reason + HIGH severity hint.
    assert len(audit_sink) == 1
    event_type, payload = audit_sink[0]
    assert event_type == "AUTH_PERMISSION_DENIED"
    assert payload["reason"] == DenyReason.CROSS_TENANT_ACCESS_ATTEMPT.value
    assert payload["target_business_id"] == str(business_b)
    assert payload["principal_business_id"] == str(business_a)
    assert payload["severity_hint"] == "HIGH"


def test_bookkeeper_on_business_a_allowed_on_business_a() -> None:
    """Same role on the matching business proceeds normally."""
    business_a = uuid4()
    principal = _principal(Role.BOOKKEEPER, business_id=business_a)
    decision = can_perform(
        principal,
        PermissionSurface.WORKFLOW_TRIGGER,
        target_business_id=business_a,
    )
    assert decision is Decision.ALLOW


@pytest.mark.parametrize(
    "write_surface",
    [
        PermissionSurface.USER_INVITE,
        PermissionSurface.BUSINESS_SETTINGS_EDIT,
        PermissionSurface.EXTERNAL_INTEGRATION,
        PermissionSurface.WORKFLOW_TRIGGER,
        PermissionSurface.WORKFLOW_APPROVE,
        PermissionSurface.FINALIZATION,
        PermissionSurface.REVIEW_QUEUE_RESOLVE,
        PermissionSurface.REVIEW_ASSIGN,
        PermissionSurface.REVIEW_REGENERATE,
        PermissionSurface.REPORT_EXPORT_BASIC,
        PermissionSurface.REPORT_EXPORT_FULL,
    ],
)
def test_read_only_denied_on_every_write_surface(
    write_surface: PermissionSurface, audit_sink: list[AuditEntry]
) -> None:
    """READ_ONLY is denied on every action-bearing surface AND audit event fires."""
    principal = _principal(Role.READ_ONLY)
    decision = can_perform(principal, write_surface)
    assert decision is Decision.DENY
    # Exactly one AUTH_PERMISSION_DENIED with ROLE_LACKS_SURFACE
    assert any(
        event_type == "AUTH_PERMISSION_DENIED"
        and payload["reason"] == DenyReason.ROLE_LACKS_SURFACE.value
        and payload["surface"] == write_surface.value
        for event_type, payload in audit_sink
    ), audit_sink


def test_read_only_can_view_dashboard_and_queue() -> None:
    """READ_ONLY retains the read-only surfaces."""
    principal = _principal(Role.READ_ONLY)
    assert can_perform(principal, PermissionSurface.DASHBOARD_VIEW) is Decision.ALLOW
    assert can_perform(principal, PermissionSurface.REVIEW_QUEUE_VIEW) is Decision.ALLOW


# ---------- Step-up handling --------------------------------------------------


def test_finalization_requires_step_up_when_mfa_stale() -> None:
    principal = _principal(Role.OWNER, mfa_recent_at=None)
    assert (
        can_perform(principal, PermissionSurface.FINALIZATION)
        is Decision.REQUIRE_STEP_UP
    )


def test_finalization_allows_when_mfa_fresh(audit_sink: list[AuditEntry]) -> None:
    fresh = datetime.now(timezone.utc) - timedelta(minutes=2)
    principal = _principal(Role.OWNER, mfa_recent_at=fresh)
    assert can_perform(principal, PermissionSurface.FINALIZATION) is Decision.ALLOW
    # FINALIZATION is sensitive — an AUTH_PERMISSION_GRANTED must fire.
    assert any(
        e == "AUTH_PERMISSION_GRANTED"
        and p["surface"] == PermissionSurface.FINALIZATION.value
        and p["step_up_satisfied"] is True
        for e, p in audit_sink
    ), audit_sink


def test_finalization_step_up_emits_no_event() -> None:
    """REQUIRE_STEP_UP is not a denial — no event."""
    audit_calls: list[Any] = []
    register_audit_emitter(lambda et, p: audit_calls.append((et, p)))
    try:
        principal = _principal(Role.OWNER)
        decision = can_perform(principal, PermissionSurface.FINALIZATION)
        assert decision is Decision.REQUIRE_STEP_UP
        assert audit_calls == []
    finally:
        register_audit_emitter(None)


def test_step_up_for_denied_role_returns_deny_not_step_up() -> None:
    """REQUIRE_STEP_UP applies only where the matrix grants it. A
    Bookkeeper hitting FINALIZATION (matrix says DENY) gets DENY, not
    REQUIRE_STEP_UP."""
    principal = _principal(
        Role.BOOKKEEPER, mfa_recent_at=datetime.now(timezone.utc)
    )
    assert (
        can_perform(principal, PermissionSurface.FINALIZATION) is Decision.DENY
    )


# ---------- Audit emission shape ---------------------------------------------


def test_sensitive_allow_emits_grant_event(audit_sink: list[AuditEntry]) -> None:
    """USER_INVITE is sensitive — plain ALLOW must still emit an AUTH_PERMISSION_GRANTED."""
    principal = _principal(Role.OWNER)
    decision = can_perform(principal, PermissionSurface.USER_INVITE)
    assert decision is Decision.ALLOW
    assert any(
        e == "AUTH_PERMISSION_GRANTED"
        and p["surface"] == PermissionSurface.USER_INVITE.value
        for e, p in audit_sink
    ), audit_sink


def test_non_sensitive_allow_emits_no_event(audit_sink: list[AuditEntry]) -> None:
    """DASHBOARD_VIEW is operational — ALLOW must NOT emit (would be noise)."""
    principal = _principal(Role.READ_ONLY)
    decision = can_perform(principal, PermissionSurface.DASHBOARD_VIEW)
    assert decision is Decision.ALLOW
    assert audit_sink == []


# ---------- Misuse detection --------------------------------------------------


def test_cross_tenant_takes_precedence_over_role_check(
    audit_sink: list[AuditEntry],
) -> None:
    """An OWNER attempting to act on another business is still DENY (not ALLOW)."""
    business_a = uuid4()
    business_b = uuid4()
    principal = _principal(Role.OWNER, business_id=business_a)
    decision = can_perform(
        principal,
        PermissionSurface.DASHBOARD_VIEW,
        target_business_id=business_b,
    )
    assert decision is Decision.DENY
    # Cross-tenant audit fires; no role-based audit.
    assert len(audit_sink) == 1
    assert audit_sink[0][1]["reason"] == DenyReason.CROSS_TENANT_ACCESS_ATTEMPT.value


def test_jwt_role_claim_parsing() -> None:
    assert Role.from_jwt_claim("org:owner") is Role.OWNER
    assert Role.from_jwt_claim("org:viewer") is Role.REVIEWER
    assert Role.from_jwt_claim("org:readonly") is Role.READ_ONLY
    with pytest.raises(ValueError):
        Role.from_jwt_claim("org:rootkit")
