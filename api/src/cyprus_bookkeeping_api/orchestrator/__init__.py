"""P0.1 pipeline orchestrator — the execution spine.

Consumes the statement-upload event outbox + workflow run state and sequences
the Block 03 DB primitives (transition_run, enter_phase / complete_phase /
hold_phase, list_phase_gates / record_gate_decision, pick_next_phase) to drive
a workflow run through its phases: ingestion → classification → … → ledger →
finalization-ready.

Design (ADR P0.1, "scale-shaped"):
  * Transport-agnostic core. ``engine.drive_run`` and ``outbox.consume_pending``
    contain all logic; ``worker.py`` is a thin long-lived entrypoint and the
    same functions are reused by the P0.4 pg_cron tick.
  * Deterministic phases call real Block 06–13 RPCs. AI-classify (layer 3),
    OCR and OAuth-gated evidence discovery are stubbed/skipped until P2 (R8).
"""
from __future__ import annotations

from cyprus_bookkeeping_api.orchestrator.engine import drive_run
from cyprus_bookkeeping_api.orchestrator.models import (
    OutcomeKind,
    PhaseOutcome,
    RunContext,
)
from cyprus_bookkeeping_api.orchestrator.outbox import consume_pending
from cyprus_bookkeeping_api.orchestrator.rpc import (
    RpcError,
    SupabaseGateway,
    build_service_gateway,
)

__all__ = [
    "drive_run",
    "consume_pending",
    "RunContext",
    "PhaseOutcome",
    "OutcomeKind",
    "SupabaseGateway",
    "RpcError",
    "build_service_gateway",
]
