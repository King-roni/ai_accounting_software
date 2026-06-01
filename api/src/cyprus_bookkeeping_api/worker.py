"""Orchestrator worker entrypoint — ``python -m cyprus_bookkeeping_api.worker``.

A thin, long-lived process around the transport-agnostic engine. Each tick:
  1. consume PENDING outbox events → create runs;
  2. advance every runnable run (CREATED / RUNNING) one drive_run at a time.

The same :func:`tick` is reused by the P0.4 pg_cron HTTP endpoint, and the loop
is safe to run as N replicas once the claim/lease lands (per-run RPCs already
``SELECT … FOR UPDATE``). Runs as its own process, never inside the web
request path (the "for scale" non-negotiable).
"""
from __future__ import annotations

import logging
import signal
import time
from types import FrameType
from typing import Any

from cyprus_bookkeeping_api.config import Settings, get_settings
from cyprus_bookkeeping_api.exports.runner import generate_pending_exports
from cyprus_bookkeeping_api.exports.storage import StoragePort, build_service_storage
from cyprus_bookkeeping_api.ingestion.runner import parse_pending_statements
from cyprus_bookkeeping_api.orchestrator.engine import safe_drive_run
from cyprus_bookkeeping_api.orchestrator.gates import GateEngine
from cyprus_bookkeeping_api.orchestrator.models import DRIVABLE_STATUSES, first_row
from cyprus_bookkeeping_api.orchestrator.outbox import consume_pending
from cyprus_bookkeeping_api.orchestrator.phases import PhaseRegistry
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway, RpcError, build_service_gateway

logger = logging.getLogger(__name__)


def tick(
    gateway: Gateway,
    settings: Settings,
    *,
    gate_engine: GateEngine | None = None,
    phase_registry: PhaseRegistry | None = None,
    storage: StoragePort | None = None,
) -> dict[str, Any]:
    """One full pass: consume the outbox, advance runnable runs, generate exports.

    Export generation runs only when a ``storage`` port is supplied (and the
    feature flag is on) — the long-lived worker and the tick endpoint provide
    one; callers that don't pass storage simply skip it.
    """
    gate_engine = gate_engine or GateEngine()
    phase_registry = phase_registry or PhaseRegistry()

    consumed = consume_pending(gateway, settings)

    # Parse UPLOADED statements → transactions BEFORE driving runs, so a run
    # created this same tick finds its transactions when its phases advance.
    statements: dict[str, Any] = {}
    if storage is not None and settings.worker_parse_statements:
        statements = parse_pending_statements(gateway, storage, settings)

    runnable = gateway.select(
        "workflow_runs",
        columns="id,status,created_at",
        in_filters={"status": sorted(DRIVABLE_STATUSES)},
        order="created_at",
        limit=settings.worker_batch_size,
    )
    driven = [
        safe_drive_run(
            gateway,
            settings,
            str(run["id"]),
            gate_engine=gate_engine,
            phase_registry=phase_registry,
        )
        for run in runnable
    ]

    exports: dict[str, Any] = {}
    if storage is not None and settings.worker_generate_exports:
        exports = generate_pending_exports(gateway, storage, settings)

    notifications: dict[str, Any] = {}
    if settings.worker_project_notifications:
        try:
            notifications = first_row(gateway.rpc("project_notifications", {})) or {}
        except RpcError:
            logger.exception("notification projection failed; continuing")

    return {
        "consumed": consumed,
        "statements": statements,
        "driven": driven,
        "exports": exports,
        "notifications": notifications,
    }


class _Stopper:
    """Flips on SIGTERM/SIGINT so the loop finishes its tick then exits cleanly."""

    def __init__(self) -> None:
        self.stop = False

    def __call__(self, signum: int, _frame: FrameType | None) -> None:
        logger.info("received signal %s; stopping after current tick", signum)
        self.stop = True


def run_worker(settings: Settings | None = None) -> None:
    settings = settings or get_settings()
    gateway = build_service_gateway(settings)
    gate_engine = GateEngine()
    phase_registry = PhaseRegistry()
    storage = build_service_storage(settings) if settings.worker_generate_exports else None

    stopper = _Stopper()
    signal.signal(signal.SIGTERM, stopper)
    signal.signal(signal.SIGINT, stopper)

    logger.info(
        "orchestrator worker started (env=%s, poll=%ss, batch=%d)",
        settings.app_env,
        settings.worker_poll_interval_seconds,
        settings.worker_batch_size,
    )
    while not stopper.stop:
        try:
            tick(
                gateway,
                settings,
                gate_engine=gate_engine,
                phase_registry=phase_registry,
                storage=storage,
            )
        except Exception:  # noqa: BLE001 — a tick failure must not kill the loop
            logger.exception("worker tick failed; continuing")
        for _ in range(int(max(1, settings.worker_poll_interval_seconds))):
            if stopper.stop:
                break
            time.sleep(1)
    logger.info("orchestrator worker stopped")


def main() -> None:
    settings = get_settings()
    logging.basicConfig(
        level=getattr(logging, settings.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    run_worker(settings)


if __name__ == "__main__":
    main()
