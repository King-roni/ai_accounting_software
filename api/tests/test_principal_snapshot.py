"""Block 02 Phase 09 — role-change propagation invariants.

The scenarios mirror the phase DoD:
  - Bookkeeper demoted to Reviewer mid-run can still finalize that run
    (the run authorizes against its snapshot).
  - The same user starting a NEW run after the demotion is limited to
    Reviewer permissions (the new run authorizes against live).
  - Role change on Business B does not affect the snapshot held by an
    active run on Business A.
  - Snapshots are immutable.
  - Audit emissions distinguish snapshot from live with `decision_basis`.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError

from cyprus_bookkeeping_api.access import (
    Decision,
    LookupResult,
    PermissionSurface,
    PrincipalContext,
    PrincipalContextSnapshot,
    Role,
    can_perform,
    register_audit_emitter,
    resolve_live_principal,
    snapshot_principal,
)

AuditEntry = tuple[str, dict[str, object]]


@pytest.fixture
def audit_sink() -> list[AuditEntry]:
    captured: list[AuditEntry] = []
    register_audit_emitter(lambda event_type, payload: captured.append((event_type, payload)))
    try:
        yield captured
    finally:
        register_audit_emitter(None)


class _MutableRoleLookup:
    """Test double: a mutable in-memory role table the test can mutate to
    simulate Owner/Admin changing roles mid-flight."""

    def __init__(self) -> None:
        self._roles: dict[tuple[UUID, UUID], LookupResult] = {}

    def set_role(
        self,
        *,
        auth_user_id: UUID,
        user_id: UUID,
        organization_id: UUID,
        business_id: UUID,
        role: Role,
        mfa_recent_at: datetime | None = None,
    ) -> None:
        self._roles[(auth_user_id, business_id)] = LookupResult(
            user_id=user_id,
            organization_id=organization_id,
            role=role,
            mfa_recent_at=mfa_recent_at,
        )

    def remove(self, *, auth_user_id: UUID, business_id: UUID) -> None:
        self._roles.pop((auth_user_id, business_id), None)

    def lookup(
        self,
        auth_user_id: UUID,
        business_id: UUID,
        step_up_surface: PermissionSurface | None = None,  # noqa: ARG002
    ) -> LookupResult | None:
        return self._roles.get((auth_user_id, business_id))


# ---------------- snapshot vs live divergence ---------------------------------


def test_snapshot_preserves_role_after_demotion() -> None:
    """Mid-flight demotion: snapshot keeps the original role even after
    the live role mutates. This is the canonical Phase 09 invariant.

    Audit-basis tagging is verified separately in `test_audit_basis_tag_*`;
    here we focus on the functional ALLOW/DENY divergence.
    """
    auth = uuid4()
    user_internal = uuid4()
    org = uuid4()
    business = uuid4()
    lookup = _MutableRoleLookup()
    lookup.set_role(
        auth_user_id=auth, user_id=user_internal, organization_id=org,
        business_id=business, role=Role.BOOKKEEPER,
    )

    # Run starts: snapshot the live principal.
    live_at_start = resolve_live_principal(lookup, auth_user_id=auth, business_id=business)
    assert live_at_start is not None
    run_snapshot = snapshot_principal(live_at_start)

    # Admin demotes the user mid-run.
    lookup.set_role(
        auth_user_id=auth, user_id=user_internal, organization_id=org,
        business_id=business, role=Role.REVIEWER,
    )

    # The snapshot still authorizes Bookkeeper actions
    assert (
        can_perform(run_snapshot, PermissionSurface.REVIEW_QUEUE_RESOLVE)
        is Decision.ALLOW
    )
    # …while the live role no longer can.
    live_now = resolve_live_principal(lookup, auth_user_id=auth, business_id=business)
    assert live_now is not None
    assert (
        can_perform(live_now, PermissionSurface.REVIEW_QUEUE_RESOLVE) is Decision.DENY
    )


def test_new_run_after_demotion_uses_live_role() -> None:
    """The same user starting a NEW run after the demotion authorizes
    against live — they can't trigger workflows as a Reviewer."""
    auth = uuid4()
    user_internal = uuid4()
    org = uuid4()
    business = uuid4()
    lookup = _MutableRoleLookup()
    lookup.set_role(
        auth_user_id=auth, user_id=user_internal, organization_id=org,
        business_id=business, role=Role.REVIEWER,
    )

    live = resolve_live_principal(lookup, auth_user_id=auth, business_id=business)
    assert live is not None
    # WORKFLOW_TRIGGER: BOOKKEEPER allowed, REVIEWER denied
    assert (
        can_perform(live, PermissionSurface.WORKFLOW_TRIGGER) is Decision.DENY
    )


def test_cross_business_role_change_does_not_affect_other_snapshot() -> None:
    """Role mutation on Business B leaves the active-run snapshot on
    Business A untouched. Per phase DoD bullet 3."""
    auth = uuid4()
    user_internal = uuid4()
    org = uuid4()
    biz_a = uuid4()
    biz_b = uuid4()
    lookup = _MutableRoleLookup()
    lookup.set_role(
        auth_user_id=auth, user_id=user_internal, organization_id=org,
        business_id=biz_a, role=Role.BOOKKEEPER,
    )
    lookup.set_role(
        auth_user_id=auth, user_id=user_internal, organization_id=org,
        business_id=biz_b, role=Role.BOOKKEEPER,
    )

    # Active run on Biz A snapshots Bookkeeper
    live_a = resolve_live_principal(lookup, auth_user_id=auth, business_id=biz_a)
    assert live_a is not None
    snapshot_a = snapshot_principal(live_a)

    # Admin changes the user's role on Biz B (not A)
    lookup.set_role(
        auth_user_id=auth, user_id=user_internal, organization_id=org,
        business_id=biz_b, role=Role.READ_ONLY,
    )

    # Snapshot for A still permits WORKFLOW_TRIGGER
    assert (
        can_perform(snapshot_a, PermissionSurface.WORKFLOW_TRIGGER) is Decision.ALLOW
    )
    # Live on B is now READ_ONLY: WORKFLOW_TRIGGER denied
    live_b = resolve_live_principal(lookup, auth_user_id=auth, business_id=biz_b)
    assert live_b is not None
    assert (
        can_perform(live_b, PermissionSurface.WORKFLOW_TRIGGER) is Decision.DENY
    )


# ---------------- snapshot type invariants -----------------------------------


def test_snapshot_is_frozen() -> None:
    """`PrincipalContextSnapshot` is frozen — mutations raise."""
    snap = snapshot_principal(
        PrincipalContext(
            user_id=uuid4(),
            organization_id=uuid4(),
            business_id=uuid4(),
            role=Role.OWNER,
        )
    )
    with pytest.raises(ValidationError):
        snap.role = Role.READ_ONLY  # type: ignore[misc]


def test_snapshot_carries_provenance_fields() -> None:
    """The snapshot must record `taken_at` + `source_user_id` so audit
    review can reconstruct the role-change timeline."""
    p = PrincipalContext(
        user_id=uuid4(), organization_id=uuid4(), business_id=uuid4(), role=Role.OWNER,
    )
    fixed = datetime(2026, 5, 19, 18, 0, tzinfo=timezone.utc)
    snap = snapshot_principal(p, taken_at=fixed)
    assert snap.taken_at == fixed
    assert snap.source_user_id == p.user_id
    assert snap.role is Role.OWNER


def test_snapshot_yields_identical_decisions_as_source() -> None:
    """For the same data, snapshot and live produce identical decisions
    across every surface."""
    p = PrincipalContext(
        user_id=uuid4(), organization_id=uuid4(), business_id=uuid4(),
        role=Role.ACCOUNTANT,
    )
    snap = snapshot_principal(p)
    for surface in PermissionSurface:
        assert can_perform(p, surface) == can_perform(snap, surface), surface


# ---------------- resolver behavior -------------------------------------------


def test_resolver_returns_none_for_non_member() -> None:
    """A user without a role on the target business gets None — the caller
    (FastAPI handler / RPC wrapper) maps that to a 403 / DENY."""
    lookup = _MutableRoleLookup()
    assert (
        resolve_live_principal(
            lookup, auth_user_id=uuid4(), business_id=uuid4()
        )
        is None
    )


def test_resolver_populates_mfa_recent_at(audit_sink: list[AuditEntry]) -> None:
    """When a fresh step-up token exists, `mfa_recent_at` populates and
    REQUIRE_STEP_UP surfaces (FINALIZATION) promote to ALLOW."""
    auth = uuid4()
    user_internal = uuid4()
    org = uuid4()
    biz = uuid4()
    now_utc = datetime.now(timezone.utc)
    lookup = _MutableRoleLookup()
    lookup.set_role(
        auth_user_id=auth, user_id=user_internal, organization_id=org,
        business_id=biz, role=Role.OWNER, mfa_recent_at=now_utc,
    )
    p = resolve_live_principal(
        lookup, auth_user_id=auth, business_id=biz,
        step_up_surface=PermissionSurface.FINALIZATION,
    )
    assert p is not None
    assert p.mfa_recent_at == now_utc
    assert can_perform(p, PermissionSurface.FINALIZATION) is Decision.ALLOW


def test_resolver_no_step_up_means_require_step_up() -> None:
    """Without a fresh step-up token, FINALIZATION returns REQUIRE_STEP_UP."""
    auth = uuid4()
    lookup = _MutableRoleLookup()
    lookup.set_role(
        auth_user_id=auth, user_id=uuid4(), organization_id=uuid4(),
        business_id=(business := uuid4()), role=Role.OWNER,
    )
    p = resolve_live_principal(lookup, auth_user_id=auth, business_id=business)
    assert p is not None
    assert (
        can_perform(p, PermissionSurface.FINALIZATION) is Decision.REQUIRE_STEP_UP
    )


# ---------------- audit basis attribution ------------------------------------


def test_audit_basis_tag_on_deny(audit_sink: list[AuditEntry]) -> None:
    """A DENY emitted against a snapshot is tagged `decision_basis=snapshot`."""
    p = PrincipalContext(
        user_id=uuid4(), organization_id=uuid4(), business_id=uuid4(),
        role=Role.READ_ONLY,
    )
    snap = snapshot_principal(p)
    assert can_perform(snap, PermissionSurface.USER_INVITE) is Decision.DENY
    assert any(
        e == "AUTH_PERMISSION_DENIED"
        and payload.get("decision_basis") == "snapshot"
        for e, payload in audit_sink
    ), audit_sink


def test_audit_basis_tag_on_live_grant(audit_sink: list[AuditEntry]) -> None:
    p = PrincipalContext(
        user_id=uuid4(), organization_id=uuid4(), business_id=uuid4(),
        role=Role.OWNER,
    )
    can_perform(p, PermissionSurface.USER_INVITE)  # sensitive ALLOW
    assert any(
        e == "AUTH_PERMISSION_GRANTED"
        and payload.get("decision_basis") == "live"
        for e, payload in audit_sink
    ), audit_sink


# ---------------- Block 03 storage contract ----------------------------------


def test_snapshot_round_trips_through_jsonb_shape() -> None:
    """The Block 03 workflow_runs table will store the snapshot as jsonb.
    Make sure `model_dump_json` / `model_validate_json` round-trip exactly."""
    p = PrincipalContext(
        user_id=uuid4(), organization_id=uuid4(), business_id=uuid4(),
        role=Role.BOOKKEEPER,
        mfa_recent_at=datetime(2026, 5, 19, 12, 0, tzinfo=timezone.utc),
    )
    snap = snapshot_principal(p)
    raw = snap.model_dump_json()
    restored: Any = PrincipalContextSnapshot.model_validate_json(raw)
    assert restored == snap
    assert can_perform(restored, PermissionSurface.WORKFLOW_TRIGGER) is Decision.ALLOW
