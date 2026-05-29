"""Supabase JWT verification.

Validates the bearer token Supabase Auth issues on signin. The JWT is
signed by Supabase's project-specific keys; we fetch the JWKS once and
cache it. The decoded payload exposes ``sub`` (auth.users.id) and ``email``
which we use as the identity for any FastAPI route requiring authentication.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

import httpx
from fastapi import HTTPException, status
from jose import jwt
from jose.exceptions import JOSEError

from cyprus_bookkeeping_api.config import Settings

# JWKS endpoint Supabase exposes for every project. Format:
#   https://<project_ref>.supabase.co/auth/v1/.well-known/jwks.json
JWKS_PATH = "/auth/v1/.well-known/jwks.json"

# Refresh the cached JWKS at most every 10 minutes; Supabase rotates rarely.
_JWKS_TTL_SECONDS = 600


@dataclass
class _JWKSCache:
    keys: list[dict[str, Any]]
    fetched_at: float


_cache: _JWKSCache | None = None


def _fetch_jwks(settings: Settings) -> _JWKSCache:
    url = settings.supabase_url.rstrip("/") + JWKS_PATH
    response = httpx.get(url, timeout=5.0)
    response.raise_for_status()
    payload = response.json()
    return _JWKSCache(keys=payload.get("keys", []), fetched_at=time.monotonic())


def _get_jwks(settings: Settings) -> list[dict[str, Any]]:
    global _cache
    if _cache is None or time.monotonic() - _cache.fetched_at > _JWKS_TTL_SECONDS:
        _cache = _fetch_jwks(settings)
    return _cache.keys


@dataclass(frozen=True)
class AuthenticatedUser:
    """A verified Supabase Auth principal.

    Carries the auth.users primary key (``id``) and the verified email
    claim. Downstream code resolves a ``public.users`` row via
    ``auth_user_id = AuthenticatedUser.id`` when needed.
    """

    id: str  # auth.users.id (uuid string)
    email: str | None
    raw_claims: dict[str, Any]


def verify_supabase_jwt(token: str, settings: Settings) -> AuthenticatedUser:
    """Validate a Supabase-issued JWT and return the principal.

    Raises 401 on any verification failure (expired, signature mismatch,
    audience mismatch, malformed).
    """
    try:
        unverified_header = jwt.get_unverified_header(token)
    except JOSEError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Malformed token") from exc

    kid = unverified_header.get("kid")
    if not kid:
        # Legacy Supabase projects sign with a single HS256 secret and no kid.
        # We don't support HS256 here; modern Supabase Auth issues ES256/RS256
        # with a kid. If you see this path, project JWT settings need rotation.
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Token missing kid")

    keys = _get_jwks(settings)
    key = next((k for k in keys if k.get("kid") == kid), None)
    if key is None:
        # Force a refresh in case Supabase rotated keys faster than our TTL.
        global _cache
        _cache = None
        keys = _get_jwks(settings)
        key = next((k for k in keys if k.get("kid") == kid), None)
    if key is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Unknown signing key")

    try:
        claims = jwt.decode(
            token,
            key,
            algorithms=[key.get("alg", "ES256")],
            audience=settings.supabase_jwt_audience,
            options={"verify_aud": True, "verify_exp": True, "verify_iat": True},
        )
    except JOSEError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc

    sub = claims.get("sub")
    if not sub:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="Token missing sub")

    return AuthenticatedUser(id=sub, email=claims.get("email"), raw_claims=claims)
