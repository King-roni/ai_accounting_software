"""Outbox consumer (B07·P09 producer ↔ B03·P09 consumer).

Polls ``statement_upload_events_outbox`` for PENDING rows and calls
``consume_statement_upload_completed_event`` per event — which creates the
OUT_MONTHLY + IN_MONTHLY runs (honouring per-business enable config) and marks
the row CONSUMED. This is the "Python consumer loop / poll outbox" the B07·P09
header documents but was never built. No NOTIFY exists, so it is poll-based;
the SELECT is bounded and indexed on ``(status, emitted_at)``.
"""
from __future__ import annotations

import logging
from typing import Any

from cyprus_bookkeeping_api.config import Settings
from cyprus_bookkeeping_api.orchestrator.models import first_row
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway, RpcError

logger = logging.getLogger(__name__)


def consume_pending(
    gateway: Gateway, settings: Settings, *, limit: int | None = None
) -> dict[str, Any]:
    """Consume PENDING outbox events. Returns created run ids + consumed/failed."""
    rows = gateway.select(
        "statement_upload_events_outbox",
        columns="event_id,status,emitted_at",
        in_filters={"status": ["PENDING"]},
        order="emitted_at",
        limit=limit or settings.worker_batch_size,
    )

    consumed: list[str] = []
    failed: list[str] = []
    created_run_ids: list[str] = []

    for row in rows:
        event_id = row["event_id"]
        try:
            result = first_row(
                gateway.rpc(
                    "consume_statement_upload_completed_event",
                    {"p_event_id": event_id},
                )
            ) or {}
        except RpcError as exc:
            logger.exception("consume failed for event %s", event_id)
            _record_failed(gateway, event_id, "CONSUME_ERROR", str(exc))
            failed.append(event_id)
            continue

        if result.get("ok"):
            consumed.append(event_id)
            created_run_ids.extend(str(r) for r in (result.get("created_run_ids") or []))
        else:
            reason = result.get("reason", "UNKNOWN")
            logger.warning("consume rejected event %s: %s", event_id, reason)
            _record_failed(gateway, event_id, "CONSUME_REJECTED", reason)
            failed.append(event_id)

    if consumed or failed:
        logger.info(
            "outbox: consumed=%d failed=%d new_runs=%d",
            len(consumed), len(failed), len(created_run_ids),
        )
    return {"consumed": consumed, "failed": failed, "created_run_ids": created_run_ids}


def _record_failed(
    gateway: Gateway, event_id: str, category: str, message: str
) -> None:
    try:
        gateway.rpc(
            "record_statement_upload_event_handler_failed",
            {
                "p_event_id": event_id,
                "p_error_category": category,
                "p_error_message": (message or category)[:2000],
            },
        )
    except RpcError:
        logger.exception("could not record outbox failure for %s", event_id)
