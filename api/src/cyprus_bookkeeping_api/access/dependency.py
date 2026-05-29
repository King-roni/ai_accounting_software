"""FastAPI dependency factory — wires `can_perform` into route handlers.

Usage:

    from cyprus_bookkeeping_api.access import PermissionSurface
    from cyprus_bookkeeping_api.access.dependency import require_permission

    @router.post("/finalization/lock", dependencies=[Depends(require_permission(PermissionSurface.FINALIZATION))])
    def lock_period(...): ...

The dependency raises 403 for DENY and 401 with a STEP_UP_REQUIRED hint
for REQUIRE_STEP_UP. Cross-tenant detection (target business comes from a
path/body param) is handled by the handler itself calling `can_perform(
principal, surface, target_business_id=...)` — the dependency factory
covers only the role × surface check.
"""
from __future__ import annotations

from collections.abc import Callable
from typing import Annotated

from fastapi import Depends, HTTPException, status

from cyprus_bookkeeping_api.access.decision import can_perform
from cyprus_bookkeeping_api.access.enums import Decision, PermissionSurface
from cyprus_bookkeeping_api.access.principal import PrincipalContext

# Phase 04 resolves PrincipalContext from the verified JWT + selected business.
# Phase 09 (Role Change Propagation) will wire the real resolver. Until then
# routes that need authorization must accept a PrincipalContext through their
# own dependency override or test fixture.
PrincipalDep = Annotated[PrincipalContext, Depends()]


def require_permission(
    surface: PermissionSurface,
) -> Callable[[PrincipalContext], PrincipalContext]:
    """Return a FastAPI dependency that enforces `surface` for the request.

    The returned callable consumes a `PrincipalContext` (provided by an
    upstream dependency or test override) and either returns it on ALLOW or
    raises an HTTPException on DENY / REQUIRE_STEP_UP.
    """

    def _dep(principal: PrincipalContext) -> PrincipalContext:
        decision = can_perform(principal, surface)
        if decision is Decision.ALLOW:
            return principal
        if decision is Decision.REQUIRE_STEP_UP:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail={
                    "error": "STEP_UP_REQUIRED",
                    "surface": surface.value,
                },
            )
        # DENY
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "error": "PERMISSION_DENIED",
                "surface": surface.value,
            },
        )

    return _dep
