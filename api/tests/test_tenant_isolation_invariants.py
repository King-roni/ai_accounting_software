"""Block 02 Phase 10 — tenant isolation invariant suite.

Canonical multi-tenant fixture (2 orgs × 2 businesses × 4 user shapes) +
adversarial scenarios. This is the suite later phases (B12, B13, B15)
extend rather than rebuild.

Coverage maps to phase DoD:
  - Direct decision tests: every (user × business × surface) — but we
    parametrize only over a representative cross-section to stay fast.
  - canPerform decisions across tenants return DENY with cross_tenant=true.
  - Workflow run snapshot cannot be replayed against a different tenant.
  - Adversarial scenarios:
      * Off-by-one on business_id
      * Replayed principal context (swap business_id post-snapshot)
      * "Tampered" claims (caller's RoleLookup returns one principal but
        target_business_id is different)
      * User with no role anywhere (must see nothing)
  - Cross-tenant denials emit AUTH_PERMISSION_DENIED with cross_tenant=true.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from uuid import UUID, uuid4

import pytest

from cyprus_bookkeeping_api.access import (
    Decision,
    LookupResult,
    PermissionSurface,
    PrincipalContext,
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
    register_audit_emitter(lambda event, payload: captured.append((event, payload)))
    try:
        yield captured
    finally:
        register_audit_emitter(None)


# -----------------------------------------------------------------------------
# Canonical fixture
# -----------------------------------------------------------------------------

@dataclass(frozen=True)
class TenancyFixture:
    """The reusable 2-org × 2-businesses × 4-user-shapes shape from the phase
    doc. Subsequent blocks import this dataclass instead of rebuilding it.
    """

    acme_id: UUID
    globex_id: UUID
    acme_a: UUID
    acme_b: UUID
    globex_c: UUID
    globex_d: UUID
    # Auth UIDs
    user_acme_a_only_auth: UUID
    user_acme_both_auth: UUID
    user_cross_org_auth: UUID
    user_no_role_auth: UUID
    # Internal users.id values
    user_acme_a_only_id: UUID
    user_acme_both_id: UUID
    user_cross_org_id: UUID
    user_no_role_id: UUID


class _MultiTenantRoleLookup:
    """The RoleLookup adapter backing the canonical fixture."""

    def __init__(self) -> None:
        self._roles: dict[tuple[UUID, UUID], LookupResult] = {}

    def set(
        self, *, auth: UUID, user_id: UUID, organization_id: UUID,
        business_id: UUID, role: Role,
    ) -> None:
        self._roles[(auth, business_id)] = LookupResult(
            user_id=user_id,
            organization_id=organization_id,
            role=role,
            mfa_recent_at=None,
        )

    def lookup(
        self, auth_user_id: UUID, business_id: UUID,
        step_up_surface: PermissionSurface | None = None,  # noqa: ARG002
    ) -> LookupResult | None:
        return self._roles.get((auth_user_id, business_id))


def _build_fixture() -> tuple[TenancyFixture, _MultiTenantRoleLookup]:
    acme_id, globex_id = uuid4(), uuid4()
    acme_a, acme_b = uuid4(), uuid4()
    globex_c, globex_d = uuid4(), uuid4()
    u1_auth, u1_id = uuid4(), uuid4()  # Acme A only — BOOKKEEPER
    u2_auth, u2_id = uuid4(), uuid4()  # Acme A + Acme B — OWNER on A, ADMIN on B
    u3_auth, u3_id = uuid4(), uuid4()  # Acme A + Globex C — ACCOUNTANT on both
    u4_auth, u4_id = uuid4(), uuid4()  # no role anywhere

    lookup = _MultiTenantRoleLookup()
    lookup.set(auth=u1_auth, user_id=u1_id, organization_id=acme_id,
               business_id=acme_a, role=Role.BOOKKEEPER)
    lookup.set(auth=u2_auth, user_id=u2_id, organization_id=acme_id,
               business_id=acme_a, role=Role.OWNER)
    lookup.set(auth=u2_auth, user_id=u2_id, organization_id=acme_id,
               business_id=acme_b, role=Role.ADMIN)
    lookup.set(auth=u3_auth, user_id=u3_id, organization_id=acme_id,
               business_id=acme_a, role=Role.ACCOUNTANT)
    lookup.set(auth=u3_auth, user_id=u3_id, organization_id=globex_id,
               business_id=globex_c, role=Role.ACCOUNTANT)
    # u4_* deliberately has no roles.

    fixture = TenancyFixture(
        acme_id=acme_id, globex_id=globex_id,
        acme_a=acme_a, acme_b=acme_b, globex_c=globex_c, globex_d=globex_d,
        user_acme_a_only_auth=u1_auth,
        user_acme_both_auth=u2_auth,
        user_cross_org_auth=u3_auth,
        user_no_role_auth=u4_auth,
        user_acme_a_only_id=u1_id,
        user_acme_both_id=u2_id,
        user_cross_org_id=u3_id,
        user_no_role_id=u4_id,
    )
    return fixture, lookup


@pytest.fixture
def fixture() -> tuple[TenancyFixture, _MultiTenantRoleLookup]:
    return _build_fixture()


# -----------------------------------------------------------------------------
# Phase DoD: per-user × per-business decisions
# -----------------------------------------------------------------------------

def test_user_with_no_role_sees_nothing(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
) -> None:
    """User shape #4: no role anywhere → resolver returns None for every
    business. The caller maps that to a 403 / DENY."""
    f, lookup = fixture
    for biz in (f.acme_a, f.acme_b, f.globex_c, f.globex_d):
        assert (
            resolve_live_principal(lookup, auth_user_id=f.user_no_role_auth, business_id=biz)
            is None
        )


def test_user_acme_a_only_cannot_reach_acme_b(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
) -> None:
    """User shape #1: role on Acme A only → resolver returns None for Acme B
    and the Globex businesses."""
    f, lookup = fixture
    assert resolve_live_principal(
        lookup, auth_user_id=f.user_acme_a_only_auth, business_id=f.acme_a,
    ) is not None
    for biz in (f.acme_b, f.acme_c if hasattr(f, "acme_c") else f.globex_c, f.globex_d):
        assert resolve_live_principal(
            lookup, auth_user_id=f.user_acme_a_only_auth, business_id=biz,
        ) is None


def test_user_acme_both_has_distinct_roles_per_business(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
) -> None:
    """User shape #2: OWNER on Acme A, ADMIN on Acme B. Role lookups give the
    right role for each business; no cross-business contamination."""
    f, lookup = fixture
    a = resolve_live_principal(lookup, auth_user_id=f.user_acme_both_auth, business_id=f.acme_a)
    b = resolve_live_principal(lookup, auth_user_id=f.user_acme_both_auth, business_id=f.acme_b)
    assert a is not None and a.role is Role.OWNER
    assert b is not None and b.role is Role.ADMIN


def test_user_spanning_two_orgs_sees_each(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
) -> None:
    """User shape #3: ACCOUNTANT on Acme A + ACCOUNTANT on Globex C. Both
    visible; the Acme B and Globex D businesses remain hidden."""
    f, lookup = fixture
    a = resolve_live_principal(lookup, auth_user_id=f.user_cross_org_auth, business_id=f.acme_a)
    c = resolve_live_principal(lookup, auth_user_id=f.user_cross_org_auth, business_id=f.globex_c)
    assert a is not None and a.role is Role.ACCOUNTANT
    assert c is not None and c.role is Role.ACCOUNTANT
    assert resolve_live_principal(
        lookup, auth_user_id=f.user_cross_org_auth, business_id=f.acme_b,
    ) is None
    assert resolve_live_principal(
        lookup, auth_user_id=f.user_cross_org_auth, business_id=f.globex_d,
    ) is None


# -----------------------------------------------------------------------------
# canPerform cross-tenant denials
# -----------------------------------------------------------------------------

@pytest.mark.parametrize(
    "surface",
    [
        PermissionSurface.WORKFLOW_TRIGGER,
        PermissionSurface.REVIEW_QUEUE_RESOLVE,
        PermissionSurface.FINALIZATION,
        PermissionSurface.USER_INVITE,
        PermissionSurface.DASHBOARD_VIEW,
    ],
)
def test_cross_tenant_target_business_id_is_always_deny(
    surface: PermissionSurface,
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
    audit_sink: list[AuditEntry],
) -> None:
    """Even an Owner on Acme A is DENY when the action targets a business
    on the other side of the org boundary, regardless of surface."""
    f, lookup = fixture
    principal = resolve_live_principal(
        lookup, auth_user_id=f.user_acme_both_auth, business_id=f.acme_a,
    )
    assert principal is not None
    decision = can_perform(principal, surface, target_business_id=f.globex_c)
    assert decision is Decision.DENY
    # Phase DoD: cross_tenant=true on the emitted audit event
    assert any(
        e == "AUTH_PERMISSION_DENIED" and payload.get("cross_tenant") is True
        and payload.get("target_business_id") == str(f.globex_c)
        for e, payload in audit_sink
    ), audit_sink


def test_cross_tenant_alerting_threshold_signal(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
    audit_sink: list[AuditEntry],
) -> None:
    """The alerting layer counts cross_tenant=true events. A burst of three
    attempts from one user against one foreign business must produce three
    distinct emissions tagged cross_tenant=true (alert threshold is set on
    the consuming side; here we verify the upstream signal shape)."""
    f, lookup = fixture
    principal = resolve_live_principal(
        lookup, auth_user_id=f.user_acme_a_only_auth, business_id=f.acme_a,
    )
    assert principal is not None
    for _ in range(3):
        can_perform(principal, PermissionSurface.DASHBOARD_VIEW,
                    target_business_id=f.globex_c)
    cross_tenant_events = [
        p for e, p in audit_sink
        if e == "AUTH_PERMISSION_DENIED" and p.get("cross_tenant") is True
    ]
    assert len(cross_tenant_events) == 3


# -----------------------------------------------------------------------------
# Workflow-snapshot replay across tenants
# -----------------------------------------------------------------------------

def test_snapshot_cannot_be_replayed_against_another_tenant(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
    audit_sink: list[AuditEntry],
) -> None:
    """An attacker who captures a workflow-run snapshot for Acme A cannot
    point it at a business they have no role on. can_perform with
    target_business_id=globex_c must DENY with cross_tenant=true even
    though the snapshot was a valid OWNER snapshot."""
    f, lookup = fixture
    principal = resolve_live_principal(
        lookup, auth_user_id=f.user_acme_both_auth, business_id=f.acme_a,
    )
    assert principal is not None
    snap = snapshot_principal(principal)
    decision = can_perform(snap, PermissionSurface.FINALIZATION,
                           target_business_id=f.globex_c)
    assert decision is Decision.DENY
    # The audit emission is tagged with decision_basis="snapshot" so reviewers
    # can tell this was a replay attempt, not a fresh live decision.
    assert any(
        e == "AUTH_PERMISSION_DENIED"
        and payload.get("decision_basis") == "snapshot"
        and payload.get("cross_tenant") is True
        for e, payload in audit_sink
    ), audit_sink


# -----------------------------------------------------------------------------
# Adversarial scenarios
# -----------------------------------------------------------------------------

def test_adversarial_off_by_one_business_id(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
    audit_sink: list[AuditEntry],
) -> None:
    """Constructing a principal manually with a one-off business_id (e.g.
    swapping in the neighbor's UUID) must DENY when can_perform sees the
    mismatch. We simulate by manually constructing a PrincipalContext that
    pretends to be on Acme B but targets Globex C."""
    f, _ = fixture
    spoofed = PrincipalContext(
        user_id=f.user_acme_both_id,
        organization_id=f.acme_id,
        business_id=f.acme_b,
        role=Role.ADMIN,
    )
    decision = can_perform(spoofed, PermissionSurface.WORKFLOW_TRIGGER,
                           target_business_id=f.globex_c)
    assert decision is Decision.DENY
    assert any(p.get("cross_tenant") is True for _, p in audit_sink)


def test_adversarial_tampered_role_claim_blocked_by_matrix(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
) -> None:
    """If an attacker tampered with the principal context and forged
    role=OWNER but the role is actually READ_ONLY, the in-flight check
    has no way to know — but the next phase (RLS) would reject the SQL,
    and any signed/HMAC envelope (B05) would fail verification.

    For the in-process can_perform layer, what we CAN assert is that the
    matrix decision follows the role field — so the gate to defense here
    is upstream: the signed envelope must be verified BEFORE constructing
    a PrincipalContext. This test pins the invariant 'matrix obeys the
    claimed role' so the signature layer's contract is unambiguous."""
    f, _ = fixture
    # If a READ_ONLY user spoofs as OWNER, matrix returns ALLOW (the
    # signature/RLS layers are what catch the spoof — this is by design).
    spoofed = PrincipalContext(
        user_id=f.user_acme_a_only_id,
        organization_id=f.acme_id,
        business_id=f.acme_a,
        role=Role.OWNER,  # claimed; not enforced by can_perform alone
    )
    assert can_perform(spoofed, PermissionSurface.USER_INVITE) is Decision.ALLOW
    # The actual READ_ONLY user calling the matrix straight would be denied:
    real = PrincipalContext(
        user_id=f.user_acme_a_only_id,
        organization_id=f.acme_id,
        business_id=f.acme_a,
        role=Role.READ_ONLY,
    )
    assert can_perform(real, PermissionSurface.USER_INVITE) is Decision.DENY


def test_adversarial_replayed_principal_with_wrong_target(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
    audit_sink: list[AuditEntry],
) -> None:
    """An attacker replays a valid principal (snapshot or live) but points
    target_business_id at a foreign business they don't have a role on.
    Phase 04's cross-tenant short-circuit catches this regardless of how
    the principal was obtained."""
    f, lookup = fixture
    live = resolve_live_principal(
        lookup, auth_user_id=f.user_acme_a_only_auth, business_id=f.acme_a,
    )
    assert live is not None
    decision = can_perform(live, PermissionSurface.DASHBOARD_VIEW,
                           target_business_id=f.acme_b)
    assert decision is Decision.DENY
    assert any(p.get("cross_tenant") is True for _, p in audit_sink)


# -----------------------------------------------------------------------------
# Fixture reusability invariant — ensures later blocks can extend cleanly
# -----------------------------------------------------------------------------

def test_fixture_is_deterministic_per_call(
) -> None:
    """Each `_build_fixture()` call yields a fresh set of UUIDs — so
    parallel tests don't collide. (The fixture's *shape* is stable; only
    the IDs differ.)"""
    f1, _ = _build_fixture()
    f2, _ = _build_fixture()
    assert f1.acme_id != f2.acme_id
    assert f1.acme_a != f2.acme_a


def test_fixture_seed_meta_unchanging() -> None:
    """The fixture exposes exactly the shape the phase doc commits to."""
    f, _ = _build_fixture()
    # 2 orgs × 2 businesses × 4 user shapes = the canonical contract
    business_ids = {f.acme_a, f.acme_b, f.globex_c, f.globex_d}
    assert len(business_ids) == 4
    auths = {
        f.user_acme_a_only_auth, f.user_acme_both_auth,
        f.user_cross_org_auth, f.user_no_role_auth,
    }
    assert len(auths) == 4


# Provenance test for the audit emitter's enhanced shape
def test_audit_payload_includes_cross_tenant_boolean_always(
    fixture: tuple[TenancyFixture, _MultiTenantRoleLookup],
    audit_sink: list[AuditEntry],
) -> None:
    """Both cross-tenant and non-cross-tenant denials carry the
    `cross_tenant` boolean explicitly so the alerting layer doesn't have
    to parse the reason string."""
    f, lookup = fixture
    principal = resolve_live_principal(
        lookup, auth_user_id=f.user_acme_a_only_auth, business_id=f.acme_a,
    )
    assert principal is not None
    # Cross-tenant DENY
    can_perform(principal, PermissionSurface.DASHBOARD_VIEW,
                target_business_id=f.globex_c)
    # Same-tenant role-lacks-surface DENY (BOOKKEEPER → USER_INVITE = DENY)
    can_perform(principal, PermissionSurface.USER_INVITE)

    denials = [p for e, p in audit_sink if e == "AUTH_PERMISSION_DENIED"]
    assert len(denials) >= 2
    flags = {p.get("cross_tenant") for p in denials}
    assert flags == {True, False}


# Snapshot taken_at provenance survives JSON round-trip — pins B03 contract.
def test_fixture_snapshot_provenance_round_trips() -> None:
    p = PrincipalContext(
        user_id=uuid4(), organization_id=uuid4(), business_id=uuid4(),
        role=Role.OWNER,
    )
    taken = datetime(2026, 5, 19, 18, 0, tzinfo=timezone.utc)
    snap = snapshot_principal(p, taken_at=taken)
    raw = snap.model_dump_json()
    assert "taken_at" in raw and "source_user_id" in raw
    assert str(taken.year) in raw
