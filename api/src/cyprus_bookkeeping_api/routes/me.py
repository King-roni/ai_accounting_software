"""Authenticated identity routes."""
from __future__ import annotations

from fastapi import APIRouter

from cyprus_bookkeeping_api.deps import CurrentUser

router = APIRouter()


@router.get("/me")
def read_me(user: CurrentUser) -> dict[str, object]:
    """Returns the verified principal from the Supabase JWT.

    Stage 7-2 baseline. Phase 04 (Role Model & Permission Matrix) will
    add the resolved role context; for now we only echo the auth claims.
    """
    return {
        "auth_user_id": user.id,
        "email": user.email,
    }
