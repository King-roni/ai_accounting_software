"""PrincipalContext — the signed bundle attached to every protected request.

Phase 04 deliverable. The signing itself is performed by Supabase (JWT) plus
a future B05 envelope; this type is the deserialized in-memory shape.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from cyprus_bookkeeping_api.access.enums import Role

# Default freshness window. The canonical value lives in
# `Docs/sub/policies/step_up_validity_window_policy.md` (Phase 06 owner).
# Until Phase 06 wires the policy in, callers may override per-call.
DEFAULT_STEP_UP_WINDOW = timedelta(minutes=15)


class PrincipalContext(BaseModel):
    """Per-request bundle attached to every protected operation.

    Phase 04 requires this on every authorization decision. The
    `principal_of_run` helper (Phase 09) will snapshot this at workflow-run
    start so role changes apply only to new runs.
    """

    model_config = ConfigDict(frozen=True)

    user_id: UUID
    organization_id: UUID
    business_id: UUID
    role: Role
    permissions: tuple[str, ...] = Field(default_factory=tuple)
    mfa_recent_at: datetime | None = None

    def has_fresh_mfa(self, *, window: timedelta = DEFAULT_STEP_UP_WINDOW) -> bool:
        """True iff the principal's last step-up MFA verification is within `window`.

        Used by `can_perform` to convert REQUIRE_STEP_UP → ALLOW when the
        session already satisfies step-up freshness.
        """
        if self.mfa_recent_at is None:
            return False
        # Treat naive timestamps as UTC for safety.
        recent = self.mfa_recent_at
        if recent.tzinfo is None:
            recent = recent.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - recent) <= window


class PrincipalContextSnapshot(BaseModel):
    """Frozen point-in-time copy of a `PrincipalContext` (B02·P09).

    Attached to long-lived state (e.g., a workflow run record) at creation
    time so authorization decisions inside the run keep using the original
    role even after the user's live role changes. Distinct type from
    PrincipalContext at the type system so callers MUST decide consciously
    which one they're authorizing against.

    The snapshot's immutability is enforced at the model level
    (`frozen=True`); the Block 03 workflow-run schema will serialize this
    shape to jsonb and verify the signature when read back. Signing itself
    is layered in by Block 05 — the type only carries the data.

    Contract for Block 03: store the snapshot as the exact field set below
    (UUIDs as strings, datetimes as ISO 8601 UTC) inside the
    `workflow_runs.principal_snapshot` jsonb column. The recovery path on
    read is `PrincipalContextSnapshot.model_validate(row.principal_snapshot)`.
    """

    model_config = ConfigDict(frozen=True)

    user_id: UUID
    organization_id: UUID
    business_id: UUID
    role: Role
    permissions: tuple[str, ...] = Field(default_factory=tuple)
    mfa_recent_at: datetime | None = None

    # Snapshot-specific provenance fields.
    taken_at: datetime
    source_user_id: UUID

    def has_fresh_mfa(self, *, window: timedelta = DEFAULT_STEP_UP_WINDOW) -> bool:
        if self.mfa_recent_at is None:
            return False
        recent = self.mfa_recent_at
        if recent.tzinfo is None:
            recent = recent.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - recent) <= window


def snapshot_principal(
    principal: PrincipalContext,
    *,
    taken_at: datetime | None = None,
) -> PrincipalContextSnapshot:
    """Convert a live `PrincipalContext` into a frozen `PrincipalContextSnapshot`.

    Called at workflow-run start. `taken_at` defaults to now (UTC); callers
    SHOULD pass an explicit `taken_at` matching the surrounding transaction's
    timestamp so the snapshot lines up with the run's `created_at`.
    """
    return PrincipalContextSnapshot(
        user_id=principal.user_id,
        organization_id=principal.organization_id,
        business_id=principal.business_id,
        role=principal.role,
        permissions=principal.permissions,
        mfa_recent_at=principal.mfa_recent_at,
        taken_at=taken_at or datetime.now(timezone.utc),
        source_user_id=principal.user_id,
    )


# Type alias for any callable / API that accepts both. Use in canPerform-style
# signatures so the rest of the codebase isn't forced to choose at the type
# system level.
PrincipalLike = PrincipalContext | PrincipalContextSnapshot
