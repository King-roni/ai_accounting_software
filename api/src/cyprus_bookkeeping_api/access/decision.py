"""The single decision function — `can_perform`.

Every protected operation in the codebase routes through this function.
No inline role checks in handlers. The phase DoD makes this an invariant.
"""
from __future__ import annotations

from uuid import UUID

from cyprus_bookkeeping_api.access import audit
from cyprus_bookkeeping_api.access.enums import (
    Decision,
    DenyReason,
    PermissionSurface,
)
from cyprus_bookkeeping_api.access.matrix import PERMISSION_MATRIX
from cyprus_bookkeeping_api.access.principal import (
    PrincipalContextSnapshot,
    PrincipalLike,
)

# Surfaces whose ALLOW outcomes must emit an audit event.
# Per the phase doc: "every ALLOW for a sensitive action (finalization,
# user management, export) emits an ACCESS_GRANTED event."
SENSITIVE_SURFACES_FOR_AUDIT: frozenset[PermissionSurface] = frozenset(
    {
        PermissionSurface.FINALIZATION,
        PermissionSurface.USER_INVITE,
        PermissionSurface.BUSINESS_SETTINGS_EDIT,
        PermissionSurface.EXTERNAL_INTEGRATION,
        PermissionSurface.REPORT_EXPORT_FULL,
    }
)


def _decision_basis(principal: PrincipalLike) -> str:
    """Tag included in audit payloads so reviewers can distinguish a decision
    made against a live role from one resolved against a frozen workflow-run
    snapshot."""
    return "snapshot" if isinstance(principal, PrincipalContextSnapshot) else "live"


def can_perform(
    principal: PrincipalLike,
    surface: PermissionSurface,
    *,
    target_business_id: UUID | None = None,
) -> Decision:
    """Resolve `(principal, surface)` to an authorization decision.

    Accepts both a live `PrincipalContext` and a `PrincipalContextSnapshot`
    (B02·P09). The two share the field set the decision needs; the snapshot
    branch is taken implicitly when the caller passes the snapshot — this is
    the snapshot-vs-live dispatch the phase doc requires. Audit emissions
    carry `decision_basis = "live" | "snapshot"` so the role-change
    propagation timeline is reconstructible.

    Cross-tenant short-circuit
    --------------------------
    When `target_business_id` is provided and differs from the principal's
    bound business_id, the call is a cross-tenant attempt: returns DENY and
    emits a HIGH-severity audit event regardless of role.

    Matrix lookup
    -------------
    Looks up `(role, surface)` in `PERMISSION_MATRIX`. A missing cell is a
    programming error (the matrix is asserted complete at boot); the
    function raises `ValueError` rather than silently denying.

    Step-up handling
    ----------------
    If the matrix returns REQUIRE_STEP_UP and the principal's MFA freshness
    satisfies the step-up window, the decision is promoted to ALLOW
    (recorded as a step-up-satisfied audit event for sensitive surfaces).
    Otherwise REQUIRE_STEP_UP is returned to the caller.

    Audit emission
    --------------
    - DENY → emits AUTH_PERMISSION_DENIED with the deny reason.
    - REQUIRE_STEP_UP → no event (not a denial; the caller will challenge).
    - ALLOW for sensitive surface → emits AUTH_PERMISSION_GRANTED.
    """
    basis = _decision_basis(principal)
    if target_business_id is not None and target_business_id != principal.business_id:
        audit.emit_cross_tenant_attempt(principal, surface, target_business_id, basis=basis)
        return Decision.DENY

    try:
        matrix_decision = PERMISSION_MATRIX[(principal.role, surface)]
    except KeyError as exc:
        # The matrix MUST be exhaustive. This branch indicates a bug
        # (new surface added without a matrix entry). Fail loudly.
        raise ValueError(
            f"permission matrix has no entry for "
            f"(role={principal.role.value!r}, surface={surface.value!r})"
        ) from exc

    if matrix_decision is Decision.DENY:
        audit.emit_access_denied(
            principal, surface, reason=DenyReason.ROLE_LACKS_SURFACE, basis=basis
        )
        return Decision.DENY

    if matrix_decision is Decision.REQUIRE_STEP_UP:
        if principal.has_fresh_mfa():
            if surface in SENSITIVE_SURFACES_FOR_AUDIT:
                audit.emit_access_granted(principal, surface, step_up=True, basis=basis)
            return Decision.ALLOW
        return Decision.REQUIRE_STEP_UP

    # Plain ALLOW path
    if surface in SENSITIVE_SURFACES_FOR_AUDIT:
        audit.emit_access_granted(principal, surface, step_up=False, basis=basis)
    return Decision.ALLOW
