"""Internal worker-tick endpoint (P0.4).

A scheduler (pg_cron via pg_net in prod, or any external cron) can POST here to
run one orchestrator tick — consume the statement-upload outbox + advance every
runnable run — when the worker is not run as a continuous process. Guarded by a
shared secret. The default deployment runs ``python -m cyprus_bookkeeping_api.worker``
continuously and does not need this; the endpoint is disabled when no secret is set.
"""
from __future__ import annotations

import logging
import secrets
from typing import Annotated, Any

from fastapi import APIRouter, Header, HTTPException, status

from cyprus_bookkeeping_api.deps import SettingsDep
from cyprus_bookkeeping_api.orchestrator.rpc import RpcError, build_service_gateway
from cyprus_bookkeeping_api.worker import tick

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/internal/worker/tick")
def worker_tick(
    settings: SettingsDep,
    x_worker_tick_secret: Annotated[str | None, Header()] = None,
) -> dict[str, Any]:
    """Run one orchestrator tick. Requires the X-Worker-Tick-Secret header."""
    secret = (settings.worker_tick_secret or "").strip()
    if not secret:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="worker tick endpoint disabled (worker_tick_secret not configured)",
        )
    if not x_worker_tick_secret or not secrets.compare_digest(x_worker_tick_secret, secret):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="invalid worker tick secret")

    try:
        gateway = build_service_gateway(settings)
        result = tick(gateway, settings)
    except RpcError as exc:
        logger.exception("worker tick failed")
        raise HTTPException(
            status.HTTP_502_BAD_GATEWAY, detail=f"worker tick failed: {exc}"
        ) from exc

    consumed = result.get("consumed", {}) if isinstance(result, dict) else {}
    driven = result.get("driven", []) if isinstance(result, dict) else []
    return {
        "ok": True,
        "consumed_events": consumed.get("consumed", []),
        "created_run_ids": consumed.get("created_run_ids", []),
        "runs_driven": len(driven),
    }
