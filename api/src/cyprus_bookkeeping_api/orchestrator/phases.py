"""Per-phase handlers + registry.

A handler does a phase's actual work by calling that block's real RPCs, then
returns a :class:`PhaseOutcome`. The engine owns the lifecycle (enter/gates/
complete/hold); handlers own the *work*.

Wiring status for this increment (P0.1 layer 1):
  * WIRED        — INGESTION (unsnooze), IN_FILTER (single per-run RPC),
                   FINALIZATION (await-approval sentinel), the no-tool phases.
  * STUB (P2)    — AI_END_SCAN, EVIDENCE_DISCOVERY_* (AI / OCR / OAuth-gated).
  * PENDING      — CLASSIFICATION, MATCHING, INCOME_MATCHING, LEDGER_PREPARATION
                   advance the lifecycle but their per-transaction proposer→writer
                   tool loops are wired in the next P0.1 pass (layer 2). They
                   record a SKIPPED marker so it is auditable that the
                   deterministic work has not yet run.
"""
from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from cyprus_bookkeeping_api.config import Settings
from cyprus_bookkeeping_api.orchestrator.models import (
    FINALIZATION_PHASE,
    PhaseOutcome,
    RunContext,
    ToolStatus,
)
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway

logger = logging.getLogger(__name__)

WILDCARD = "*"


@dataclass(frozen=True)
class PhaseDeps:
    gateway: Gateway
    ctx: RunContext
    phase_state_id: str
    settings: Settings


Handler = Callable[[PhaseDeps], PhaseOutcome]


def _record_tool(
    deps: PhaseDeps,
    tool_name: str,
    status: ToolStatus,
    *,
    error_summary: str | None = None,
) -> None:
    params: dict[str, Any] = {
        "p_phase_state_id": deps.phase_state_id,
        "p_tool_name": tool_name,
        "p_status": status.value,
    }
    if error_summary is not None:
        params["p_error_summary"] = error_summary[:2000]
    deps.gateway.rpc("record_tool_invocation", params)


def _period_date(value: str | None) -> str | None:
    """ISO timestamptz → 'YYYY-MM-DD' for date-typed RPC params."""
    return value[:10] if value else None


# --------------------------------------------------------------------------- #
# Handlers
# --------------------------------------------------------------------------- #
def handle_ingestion(deps: PhaseDeps) -> PhaseOutcome:
    """INGESTION: unsnooze any review issues due at run start (review_queue)."""
    deps.gateway.rpc(
        "unsnooze_at_run_start",
        {"p_workflow_run_id": deps.ctx.run_id, "p_context": {}},
    )
    _record_tool(deps, "review_queue.unsnooze_at_run_start", ToolStatus.SUCCESS)
    return PhaseOutcome.complete(phase="INGESTION")


def handle_in_filter(deps: PhaseDeps) -> PhaseOutcome:
    """IN_FILTER: select in-scope income transactions for the period (B13)."""
    result = deps.gateway.rpc(
        "filter_in_transactions",
        {
            "p_organization_id": deps.ctx.organization_id,
            "p_business_id": deps.ctx.business_id,
            "p_workflow_run_id": deps.ctx.run_id,
            "p_period_start": _period_date(deps.ctx.period_start),
            "p_period_end": _period_date(deps.ctx.period_end),
            "p_actor_user_id": deps.ctx.actor_user_id,
            "p_context": {},
        },
    )
    _record_tool(deps, "in_workflow.filter_in_transactions", ToolStatus.SUCCESS)
    detail = result if isinstance(result, dict) else {"result": result}
    return PhaseOutcome.complete(phase="IN_FILTER", **detail)


def handle_ai_end_scan_stub(deps: PhaseDeps) -> PhaseOutcome:
    """AI_END_SCAN: real LLM end-scan is P2 (R8). Record a SKIPPED marker."""
    _record_tool(
        deps,
        "ai.end_scan",
        ToolStatus.SKIPPED,
        error_summary="AI end-scan stubbed until P2 (R8: real integrations).",
    )
    return PhaseOutcome.complete(phase="AI_END_SCAN", stubbed=True)


def handle_skip_optional(deps: PhaseDeps) -> PhaseOutcome:
    """Optional evidence-discovery phases need OAuth + OCR → skipped until P2."""
    if deps.settings.worker_drive_optional_phases:
        # Reserved for P2 when keys are present; for now still a stub.
        logger.info("optional phase requested but drivers not wired; skipping")
    _record_tool(
        deps,
        "intake.evidence_discovery",
        ToolStatus.SKIPPED,
        error_summary="Evidence discovery (email/drive OCR) skipped until P2 (R8).",
    )
    return PhaseOutcome.skip("optional evidence-discovery phase deferred to P2")


def handle_noop_complete(deps: PhaseDeps) -> PhaseOutcome:
    """No-tool phases (OUT_FILTER, hold phases): the gate governs; complete."""
    return PhaseOutcome.complete(phase="noop")


def handle_wiring_pending(deps: PhaseDeps) -> PhaseOutcome:
    """Deterministic phase whose block-RPC loop is wired in the next P0.1 pass.

    Advances the lifecycle so the state machine can be validated end-to-end, but
    records a SKIPPED marker so the un-done deterministic work is auditable.
    """
    _record_tool(
        deps,
        "orchestrator.phase_wiring_pending",
        ToolStatus.SKIPPED,
        error_summary=(
            "Deterministic tool loop not yet wired (P0.1 layer 2). Lifecycle "
            "advanced; no block work performed."
        ),
    )
    logger.warning(
        "phase %s for %s advanced WITHOUT deterministic work (wiring pending)",
        deps.ctx.workflow_type,
        deps.ctx.run_id,
    )
    return PhaseOutcome.complete(phase="wiring_pending")


def handle_finalization(deps: PhaseDeps) -> PhaseOutcome:
    """FINALIZATION is user-approved (B15 lock sequence) — stop and await approval."""
    return PhaseOutcome.await_approval(phase=FINALIZATION_PHASE)


# --------------------------------------------------------------------------- #
# Registry
# --------------------------------------------------------------------------- #
_REGISTRY: dict[tuple[str, str], Handler] = {
    (WILDCARD, "INGESTION"): handle_ingestion,
    (WILDCARD, "OUT_FILTER"): handle_noop_complete,
    (WILDCARD, "EVIDENCE_DISCOVERY_EMAIL"): handle_skip_optional,
    (WILDCARD, "EVIDENCE_DISCOVERY_DRIVE"): handle_skip_optional,
    (WILDCARD, "MANUAL_UPLOAD_HOLD"): handle_noop_complete,
    (WILDCARD, "HUMAN_REVIEW_HOLD"): handle_noop_complete,
    (WILDCARD, "AI_END_SCAN"): handle_ai_end_scan_stub,
    # CLASSIFICATION + MATCHING wired at module bottom (layer-2 engines).
    ("IN_MONTHLY", "INCOME_MATCHING"): handle_wiring_pending,
    ("IN_MONTHLY", "IN_FILTER"): handle_in_filter,
    (WILDCARD, "LEDGER_PREPARATION"): handle_wiring_pending,
    (WILDCARD, FINALIZATION_PHASE): handle_finalization,
}


class PhaseRegistry:
    """Resolves a handler for ``(workflow_type, phase_name)`` and runs it."""

    def __init__(self, handlers: dict[tuple[str, str], Handler] | None = None) -> None:
        self._handlers = handlers if handlers is not None else dict(_REGISTRY)

    def resolve(self, workflow_type: str, phase_name: str) -> Handler:
        return (
            self._handlers.get((workflow_type, phase_name))
            or self._handlers.get((WILDCARD, phase_name))
            or handle_noop_complete
        )

    def run(self, workflow_type: str, phase_name: str, deps: PhaseDeps) -> PhaseOutcome:
        return self.resolve(workflow_type, phase_name)(deps)


# --------------------------------------------------------------------------- #
# Layer-2 engine handlers — imported after PhaseDeps + _REGISTRY exist so the
# engines (which type-hint PhaseDeps) never create an import cycle.
# --------------------------------------------------------------------------- #
from cyprus_bookkeeping_api.orchestrator.engines.classification import (  # noqa: E402
    handle_classification,
)
from cyprus_bookkeeping_api.orchestrator.engines.matching import (  # noqa: E402
    handle_matching,
)

_REGISTRY[(WILDCARD, "CLASSIFICATION")] = handle_classification
_REGISTRY[("OUT_MONTHLY", "MATCHING")] = handle_matching
