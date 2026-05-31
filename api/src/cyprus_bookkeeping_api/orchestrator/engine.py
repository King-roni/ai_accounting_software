"""The advanceRun loop — the code-side driver B03·P06 expects.

``drive_run`` takes a run from CREATED to either AWAITING_APPROVAL (all
automated phases done; waiting for user approval to finalize) or REVIEW_HOLD
(a gate or phase needs a human). It never force-advances past a human gate and
never writes ``workflow_runs.status`` directly — only ``transition_run`` does.

Per phase: enter_phase → ENTRY gates → handler → EXIT gates → complete_phase,
holding via REVIEW_HOLD on any blocking gate or handler hold. Shared-phase
dedup (CLASSIFICATION across an OUT/IN pair via check_shared_phase_can_dedup)
lands with the layer-2 CLASSIFICATION handler; it is a no-op while that phase
is wiring-pending.
"""
from __future__ import annotations

import logging
from dataclasses import replace
from typing import Any

from cyprus_bookkeeping_api.config import Settings
from cyprus_bookkeeping_api.orchestrator.actors import require_actor
from cyprus_bookkeeping_api.orchestrator.gates import GateEngine
from cyprus_bookkeeping_api.orchestrator.models import (
    DRIVABLE_STATUSES,
    FINALIZATION_PHASE,
    TERMINAL_STATUSES,
    GateKind,
    OutcomeKind,
    RunContext,
    RunStatus,
    first_row,
)
from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps, PhaseRegistry
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway, RpcError

logger = logging.getLogger(__name__)


class OrchestratorError(RuntimeError):
    """Unrecoverable engine error (e.g. an illegal transition we cannot resolve)."""


def _load_run(gateway: Gateway, run_id: str) -> dict[str, Any] | None:
    rows = gateway.select("workflow_runs", filters={"id": run_id}, limit=1)
    return rows[0] if rows else None


def _build_context(run: dict[str, Any]) -> RunContext:
    snapshot = run.get("principal_snapshot")
    return RunContext(
        run_id=str(run["id"]),
        organization_id=str(run["organization_id"]),
        business_id=str(run["business_id"]),
        workflow_type=run["workflow_type"],
        period_start=run.get("period_start"),
        period_end=run.get("period_end"),
        actor_user_id=None,  # set by caller after actor resolution
        principal_snapshot=snapshot if isinstance(snapshot, dict) else {},
        trigger_kind=run.get("trigger_kind"),
        trigger_event_id=run.get("trigger_event_id"),
    )


def _transition(
    gateway: Gateway,
    run_id: str,
    target: RunStatus,
    actor: str,
    *,
    reason: str | None = None,
) -> dict[str, Any]:
    result = gateway.rpc(
        "transition_run",
        {
            "p_run_id": run_id,
            "p_target_state": target.value,
            "p_actor_user_id": actor,
            "p_reason": reason,
        },
    )
    result = result if isinstance(result, dict) else (first_row(result) or {})
    if not result.get("ok"):
        raise OrchestratorError(
            f"transition_run {run_id} → {target.value} rejected: "
            f"{result.get('reason')} ({result.get('message')})"
        )
    return result


def _hold(
    gateway: Gateway,
    ctx: RunContext,
    phase_state_id: str,
    actor: str,
    reason: str,
) -> None:
    gateway.rpc(
        "hold_phase",
        {"p_phase_state_id": phase_state_id, "p_reason": reason, "p_severity": "BLOCKING"},
    )
    _transition(gateway, ctx.run_id, RunStatus.REVIEW_HOLD, actor, reason=reason)


def drive_run(
    gateway: Gateway,
    settings: Settings,
    run_id: str,
    *,
    gate_engine: GateEngine | None = None,
    phase_registry: PhaseRegistry | None = None,
) -> dict[str, Any]:
    """Drive a single run as far as the worker is permitted to. Idempotent."""
    gates = gate_engine or GateEngine()
    phases = phase_registry or PhaseRegistry()

    run = _load_run(gateway, run_id)
    if run is None:
        return {"run_id": run_id, "ok": False, "reason": "RUN_NOT_FOUND"}

    status = run["status"]
    if status in TERMINAL_STATUSES:
        return {"run_id": run_id, "ok": True, "status": status, "stopped": "TERMINAL"}
    if status not in DRIVABLE_STATUSES:
        # PAUSED / REVIEW_HOLD / AWAITING_APPROVAL / FINALIZING: waiting on a
        # human or another process — never auto-advanced here.
        return {"run_id": run_id, "ok": True, "status": status, "stopped": "WAITING"}

    actor = require_actor(run, settings)
    ctx = replace(_build_context(run), actor_user_id=actor)

    from_status = status
    if status == RunStatus.CREATED:
        # wfr_started_state_chk requires started_by once RUNNING, but the 'start'
        # transition only stamps started_at and the event-creation paths
        # (consume_* / trigger_run_from_event) never set started_by. Backfill it
        # to the resolved actor so SYSTEM/event runs can start. started_by is not
        # status-guarded; service_role bypasses RLS.
        if not run.get("started_by"):
            gateway.update("workflow_runs", {"started_by": actor}, filters={"id": run_id})
        _transition(gateway, run_id, RunStatus.RUNNING, actor, reason="engine start")
        status = RunStatus.RUNNING.value

    advanced = 0
    for _ in range(settings.worker_max_phase_iterations):
        phase_name = gateway.rpc("pick_next_phase", {"p_run_id": run_id})
        if not phase_name:
            _transition(gateway, run_id, RunStatus.AWAITING_APPROVAL, actor)
            return _summary(run_id, ctx, from_status, RunStatus.AWAITING_APPROVAL.value,
                            advanced, "ALL_PHASES_DONE")

        if phase_name == FINALIZATION_PHASE:
            # User-approved B15 lock sequence; stop and await approval.
            _transition(gateway, run_id, RunStatus.AWAITING_APPROVAL, actor)
            return _summary(run_id, ctx, from_status, RunStatus.AWAITING_APPROVAL.value,
                            advanced, "AWAITING_APPROVAL")

        state = first_row(gateway.rpc(
            "enter_phase", {"p_run_id": run_id, "p_phase_name": phase_name}
        ))
        if not state or "id" not in state:
            raise OrchestratorError(f"enter_phase returned no row for {phase_name}")
        phase_state_id = str(state["id"])

        entry = gates.evaluate(gateway, ctx, phase_state_id, phase_name, GateKind.ENTRY.value)
        if entry.hold:
            _hold(gateway, ctx, phase_state_id, actor,
                  entry.reason or f"{phase_name} entry gate hold")
            return _summary(run_id, ctx, from_status, RunStatus.REVIEW_HOLD.value,
                            advanced, f"ENTRY_GATE_HOLD:{entry.gate_name}")

        deps = PhaseDeps(gateway=gateway, ctx=ctx, phase_state_id=phase_state_id,
                         settings=settings)
        outcome = phases.run(ctx.workflow_type, phase_name, deps)

        if outcome.kind == OutcomeKind.HOLD:
            _hold(gateway, ctx, phase_state_id, actor,
                  outcome.reason or f"{phase_name} held")
            return _summary(run_id, ctx, from_status, RunStatus.REVIEW_HOLD.value,
                            advanced, f"PHASE_HOLD:{phase_name}")

        if outcome.kind == OutcomeKind.AWAIT_APPROVAL:
            _transition(gateway, run_id, RunStatus.AWAITING_APPROVAL, actor)
            return _summary(run_id, ctx, from_status, RunStatus.AWAITING_APPROVAL.value,
                            advanced, "AWAITING_APPROVAL")

        if outcome.kind == OutcomeKind.COMPLETE:
            exit_gate = gates.evaluate(
                gateway, ctx, phase_state_id, phase_name, GateKind.EXIT.value
            )
            if exit_gate.hold:
                _hold(gateway, ctx, phase_state_id, actor,
                      exit_gate.reason or f"{phase_name} exit gate hold")
                return _summary(run_id, ctx, from_status, RunStatus.REVIEW_HOLD.value,
                                advanced, f"EXIT_GATE_HOLD:{exit_gate.gate_name}")

        # COMPLETE and SKIP both terminate the phase so the loop progresses.
        gateway.rpc("complete_phase", {"p_phase_state_id": phase_state_id})
        advanced += 1

    raise OrchestratorError(
        f"run {run_id} exceeded worker_max_phase_iterations "
        f"({settings.worker_max_phase_iterations}) — possible phase loop"
    )


def _summary(
    run_id: str,
    ctx: RunContext,
    from_status: str,
    final_status: str,
    advanced: int,
    stopped: str,
) -> dict[str, Any]:
    return {
        "run_id": run_id,
        "ok": True,
        "workflow_type": ctx.workflow_type,
        "from_status": from_status,
        "status": final_status,
        "phases_advanced": advanced,
        "stopped": stopped,
    }


def safe_drive_run(
    gateway: Gateway,
    settings: Settings,
    run_id: str,
    **kwargs: Any,
) -> dict[str, Any]:
    """drive_run wrapper that never raises — for the worker's per-run isolation."""
    try:
        return drive_run(gateway, settings, run_id, **kwargs)
    except (OrchestratorError, RpcError) as exc:
        logger.exception("drive_run failed for %s", run_id)
        return {"run_id": run_id, "ok": False, "reason": "DRIVE_FAILED", "error": str(exc)}
    except Exception as exc:  # noqa: BLE001 — worker must survive one bad run
        logger.exception("drive_run crashed for %s", run_id)
        return {"run_id": run_id, "ok": False, "reason": "CRASH", "error": str(exc)}
