"""FastAPI application entry point."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from supabase import Client, create_client

from cyprus_bookkeeping_api.config import Settings, get_settings
from cyprus_bookkeeping_api.routes import health, me
from cyprus_bookkeeping_api.secure_http import verify_security_baseline

logger = logging.getLogger(__name__)


def _build_db_status_fn(settings: Settings) -> Any:
    """Return a zero-arg callable that fetches at_rest_encryption_status()."""

    def _call() -> dict[str, Any]:
        if not settings.supabase_service_role_key:
            # No service role key wired up yet: degrade to a documented
            # "unverifiable at startup" state. The application is still
            # running locally; production must set the key.
            return {
                "all_ok": False,
                "buckets": [],
                "note": "service_role_key not configured; at-rest self-check skipped",
            }
        client: Client = create_client(settings.supabase_url, settings.supabase_service_role_key)
        response = client.rpc("at_rest_encryption_status").execute()
        return response.data if isinstance(response.data, dict) else {}

    return _call


@asynccontextmanager
async def lifespan(app: FastAPI):
    """B05·P01 startup self-check: verify security baseline or refuse to serve.

    Behaviour:
      * In production (``APP_ENV=production``): a failed check raises and
        the app exits before binding the port — fail-fast contract.
      * In development / local: a failed check logs ERROR but lets the app
        start so developers can iterate without a full prod baseline.
    """
    settings = get_settings()
    result = verify_security_baseline(
        db_status_fn=_build_db_status_fn(settings),
        environment=settings.app_env,
    )
    if not result.ok:
        message = (
            f"Security baseline check FAILED in env={settings.app_env!r}: "
            f"{result.checks}"
        )
        if settings.app_env == "production":
            logger.critical(message)
            raise RuntimeError(message)
        logger.error(message)
    else:
        logger.info("Security baseline OK (env=%s, checks=%d)", settings.app_env, len(result.checks))
    yield


settings = get_settings()

app = FastAPI(
    title="Cyprus Bookkeeping API",
    version="0.1.0",
    description="Backend for the Cyprus Bookkeeping SaaS. Stage 7-2 baseline.",
    lifespan=lifespan,
)

# Development CORS: allow the Next.js dev server. Tighten in staging/prod.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "http://127.0.0.1:3000"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["*"],
)

app.include_router(health.router, tags=["health"])
app.include_router(me.router, tags=["me"])
