"""Gate evaluation (B03·P05).

The DB only *catalogs* gates (gate_registry + phase_gate_assignments) and
records outcomes (record_gate_decision / record_gate_threw); gate *bodies* are
code-side and — because the API was health+me — none existed before P0.1. This
module supplies them:

  * ``list_phase_gates`` enumerates the ENTRY/EXIT gates for a phase.
  * Each gate is evaluated by a registered evaluator, or defaults to ADVANCE.
  * Some gates already ship a DB-side evaluator function (e.g.
    ``evaluate_ledger_exit_gate``); those are registered as thin RPC wrappers.
  * Every outcome is persisted via ``record_gate_decision`` for the audit trail.

MVP policy: unregistered gates ADVANCE (the deterministic happy path). Real
per-gate checks are added to ``DB_GATE_EVALUATORS`` / ``_EVALUATORS`` as each
block's gate body is wired — without touching the engine.
"""
from __future__ import annotations

import logging
from collections.abc import Callable
from typing import Any

from cyprus_bookkeeping_api.orchestrator.models import (
    GateDecision,
    GateResult,
    RunContext,
)
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway, RpcError

logger = logging.getLogger(__name__)

# A code-side evaluator: (gateway, ctx, phase_state_id) -> (decision, reason).
Evaluator = Callable[[Gateway, RunContext, str], tuple[GateDecision, str | None]]


def _db_satisfied_gate(rpc_name: str, **extra_params: str) -> Evaluator:
    """Wrap a DB gate evaluator that returns ``{"satisfied": bool, "reason"?}``."""

    def _evaluate(
        gateway: Gateway, ctx: RunContext, phase_state_id: str
    ) -> tuple[GateDecision, str | None]:
        params: dict[str, Any] = {"p_workflow_run_id": ctx.run_id}
        params.update(extra_params)
        result = gateway.rpc(rpc_name, params) or {}
        if isinstance(result, list):
            result = result[0] if result else {}
        satisfied = bool(result.get("satisfied"))
        if satisfied:
            return GateDecision.ADVANCE, None
        return GateDecision.HOLD, result.get("reason") or f"{rpc_name} not satisfied"

    return _evaluate


# gate_name -> evaluator. Extend as block gate bodies are wired.
_EVALUATORS: dict[str, Evaluator] = {
    "ledger.exit_all_in_scope_entries_drafted_or_held_v1": _db_satisfied_gate(
        "evaluate_ledger_exit_gate"
    ),
}


class GateEngine:
    """Evaluates the ENTRY/EXIT gates of a phase and records each decision."""

    def __init__(self, evaluators: dict[str, Evaluator] | None = None) -> None:
        self._evaluators = evaluators if evaluators is not None else dict(_EVALUATORS)

    def evaluate(
        self,
        gateway: Gateway,
        ctx: RunContext,
        phase_state_id: str,
        phase_name: str,
        kind: str,
    ) -> GateResult:
        gates = gateway.rpc(
            "list_phase_gates",
            {
                "p_workflow_type": ctx.workflow_type,
                "p_phase_name": phase_name,
                "p_kind": kind,
            },
        )
        for gate in gates or []:
            gate_name = gate["gate_name"]
            decision, reason = self._eval_one(gateway, ctx, phase_state_id, gate_name)
            self._record(gateway, phase_state_id, gate_name, decision, reason)
            if decision in (GateDecision.HOLD, GateDecision.ROUTE_TO_SIDE_PHASE):
                logger.info(
                    "gate %s (%s/%s) → %s: %s",
                    gate_name,
                    phase_name,
                    kind,
                    decision.value,
                    reason,
                )
                return GateResult(hold=True, gate_name=gate_name, reason=reason)
        return GateResult(hold=False)

    def _eval_one(
        self, gateway: Gateway, ctx: RunContext, phase_state_id: str, gate_name: str
    ) -> tuple[GateDecision, str | None]:
        evaluator = self._evaluators.get(gate_name)
        if evaluator is None:
            return GateDecision.ADVANCE, None
        try:
            return evaluator(gateway, ctx, phase_state_id)
        except RpcError as exc:
            # A gate that throws is a BLOCKING hold per spec — never crash the run.
            self._record_threw(gateway, phase_state_id, gate_name, str(exc))
            return GateDecision.HOLD, f"gate evaluator raised: {exc}"

    @staticmethod
    def _record(
        gateway: Gateway,
        phase_state_id: str,
        gate_name: str,
        decision: GateDecision,
        reason: str | None,
    ) -> None:
        params: dict[str, Any] = {
            "p_phase_state_id": phase_state_id,
            "p_gate_name": gate_name,
            "p_decision": decision.value,
            "p_actor_user_id": None,  # SYSTEM
        }
        if decision != GateDecision.ADVANCE:
            params["p_reason"] = reason or f"{gate_name} blocked"
            params["p_severity"] = "BLOCKING"
        gateway.rpc("record_gate_decision", params)

    @staticmethod
    def _record_threw(
        gateway: Gateway, phase_state_id: str, gate_name: str, message: str
    ) -> None:
        try:
            gateway.rpc(
                "record_gate_threw",
                {
                    "p_phase_state_id": phase_state_id,
                    "p_gate_name": gate_name,
                    "p_exception_message": message[:2000],
                },
            )
        except RpcError:
            logger.exception("failed to record gate exception for %s", gate_name)
