"""Live `PrincipalContext` resolver (B02·P09).

Block 02 phases 4–8 deferred this resolver: tests constructed
`PrincipalContext` manually, FastAPI handlers had nothing protected to
gate. Phase 09 puts it in place.

The resolver is a pure function over an injectable `RoleLookup` protocol.
Production code wires the Supabase server client; tests inject fakes.
This isolates the access module from any specific DB driver and keeps the
unit tests fast.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol
from uuid import UUID

from cyprus_bookkeeping_api.access.enums import PermissionSurface, Role
from cyprus_bookkeeping_api.access.principal import PrincipalContext


@dataclass(frozen=True)
class LookupResult:
    """Everything needed to build a `PrincipalContext` for one (user, business).

    Returned by `RoleLookup.lookup`. `mfa_recent_at` is the issued_at of the
    most recent unconsumed unexpired `step_up_token` for the caller on the
    given business + surface — i.e., the Postgres `latest_step_up_for` RPC
    from B02·P06.
    """

    user_id: UUID
    organization_id: UUID
    role: Role
    mfa_recent_at: datetime | None = None


class RoleLookup(Protocol):
    """Adapter contract a production caller fulfills with a Supabase client.

    Implementations MUST:
      - Return `None` when the user has no ACTIVE role on the business
        (caller is treated as having no access; cross-tenant detection in
        `can_perform` handles the wrong-business case separately).
      - Read from the canonical sources: `public.users` (auth_user_id link),
        `business_user_roles` (status = ACTIVE), `step_up_tokens` (via the
        `latest_step_up_for(business_id, surface)` SECURITY DEFINER RPC).
    """

    def lookup(
        self,
        auth_user_id: UUID,
        business_id: UUID,
        step_up_surface: PermissionSurface | None = None,
    ) -> LookupResult | None: ...


def resolve_live_principal(
    role_lookup: RoleLookup,
    *,
    auth_user_id: UUID,
    business_id: UUID,
    step_up_surface: PermissionSurface | None = None,
) -> PrincipalContext | None:
    """Resolve the live `PrincipalContext` for a request.

    Returns `None` if the caller has no role on the target business — the
    caller then maps this to a 403 / DENY. `step_up_surface` lets the
    resolver populate `mfa_recent_at` from the surface-specific step-up
    token (the only fresh-MFA shape that the rest of the matrix understands);
    pass `None` for non-step-up paths and `mfa_recent_at` stays None.
    """
    result = role_lookup.lookup(auth_user_id, business_id, step_up_surface)
    if result is None:
        return None
    return PrincipalContext(
        user_id=result.user_id,
        organization_id=result.organization_id,
        business_id=business_id,
        role=result.role,
        permissions=(),
        mfa_recent_at=result.mfa_recent_at,
    )
