"""FastAPI dependency wiring."""
from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Header, HTTPException, status

from cyprus_bookkeeping_api.auth import AuthenticatedUser, verify_supabase_jwt
from cyprus_bookkeeping_api.config import Settings, get_settings

SettingsDep = Annotated[Settings, Depends(get_settings)]


def current_user(
    settings: SettingsDep,
    authorization: Annotated[str | None, Header()] = None,
) -> AuthenticatedUser:
    """Extracts the bearer token from the Authorization header and verifies it."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Empty bearer token")
    return verify_supabase_jwt(token, settings)


CurrentUser = Annotated[AuthenticatedUser, Depends(current_user)]
