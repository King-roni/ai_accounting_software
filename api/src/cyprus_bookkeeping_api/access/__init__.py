"""Block 02 Phase 04 — Role Model & Permission Matrix.

Single source of truth for `(role, surface) → Decision`. Every protected
action in the system routes through `can_perform()`; no inline role checks
in handlers.

Surface taxonomy follows `Docs/sub/reference/permission_matrix.md` (the
canonical post-amendments consolidated matrix). The resource/CRUD surface
enum in `permission_surface_enum.md` is a separate concern handled by
per-block write paths in later phases.
"""
from __future__ import annotations

from cyprus_bookkeeping_api.access.audit import (
    AuditEmitter,
    register_audit_emitter,
)
from cyprus_bookkeeping_api.access.decision import (
    SENSITIVE_SURFACES_FOR_AUDIT,
    can_perform,
)
from cyprus_bookkeeping_api.access.enums import (
    Decision,
    DenyReason,
    PermissionSurface,
    Role,
)
from cyprus_bookkeeping_api.access.matrix import (
    PERMISSION_MATRIX,
    assert_matrix_complete,
    matrix_as_table,
)
from cyprus_bookkeeping_api.access.principal import (
    PrincipalContext,
    PrincipalContextSnapshot,
    PrincipalLike,
    snapshot_principal,
)
from cyprus_bookkeeping_api.access.resolver import (
    LookupResult,
    RoleLookup,
    resolve_live_principal,
)

__all__ = [
    "AuditEmitter",
    "Decision",
    "DenyReason",
    "LookupResult",
    "PERMISSION_MATRIX",
    "PermissionSurface",
    "PrincipalContext",
    "PrincipalContextSnapshot",
    "PrincipalLike",
    "Role",
    "RoleLookup",
    "SENSITIVE_SURFACES_FOR_AUDIT",
    "assert_matrix_complete",
    "can_perform",
    "matrix_as_table",
    "register_audit_emitter",
    "resolve_live_principal",
    "snapshot_principal",
]
