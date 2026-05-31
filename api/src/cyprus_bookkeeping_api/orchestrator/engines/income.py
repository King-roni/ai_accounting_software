"""INCOME_MATCHING engine (Block 13 IN-side) — match income txns to invoices.

For each IN-direction transaction in the run period, find a candidate invoice
(by payment reference == invoice_number, else by exact amount), decide the
income outcome, and persist via ``apply_income_match`` (sets
transactions.income_match_outcome + matched_invoice_id). No ``get_match_candidates``
RPC exists, so candidate discovery is app-side over the invoices table.

Outcomes (income_match_outcome_enum): FULL_MATCH / PARTIAL_PAYMENT / OVERPAYMENT
when a candidate is found; NO_MATCH otherwise. The exit gate
``evaluate_income_matching_exit_gate`` requires every IN-direction txn in period
to have income_match_outcome set. MVP: single-invoice matching by reference or
exact amount; multi-invoice / split allocations are a documented follow-up.
"""
from __future__ import annotations

import logging
from datetime import date
from typing import TYPE_CHECKING, Any

from cyprus_bookkeeping_api.orchestrator.models import PhaseOutcome, ToolStatus

if TYPE_CHECKING:
    from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps

logger = logging.getLogger(__name__)

PHASE = "INCOME_MATCHING"
EVENT_FAMILY = "INCOME_MATCHING"


def handle_income_matching(deps: "PhaseDeps") -> PhaseOutcome:
    gw, ctx = deps.gateway, deps.ctx
    actor = ctx.actor_user_id
    gw.rpc("record_matching_phase_started",
           {"p_workflow_run_id": ctx.run_id, "p_event_family": EVENT_FAMILY,
            "p_phase_name": PHASE, "p_context": {}})

    p_start, p_end = _date(ctx.period_start), _date(ctx.period_end)
    txns = [t for t in gw.select("transactions", filters={"business_id": ctx.business_id})
            if (t.get("direction") or "").upper() == "IN"
            and t.get("income_match_outcome") is None
            and _in_period(_date(t.get("transaction_date")), p_start, p_end)]
    invoices = gw.select("invoices", filters={"business_id": ctx.business_id})

    counts: dict[str, int] = {}
    for txn in txns:
        invoice, outcome, has_ref = _match_income(txn, invoices)
        gw.rpc("apply_income_match", {
            "p_transaction_id": txn["id"],
            "p_invoice_id": invoice["id"] if invoice else None,
            "p_outcome": outcome,
            "p_workflow_run_id": ctx.run_id,
            "p_has_reference_match": has_ref,
            "p_actor_user_id": actor,
            "p_context": {},
        })
        counts[outcome] = counts.get(outcome, 0) + 1

    _record_tool(deps, "matching.income_match_outcome", ToolStatus.SUCCESS)
    gw.rpc("record_matching_phase_completed",
           {"p_workflow_run_id": ctx.run_id, "p_event_family": EVENT_FAMILY,
            "p_phase_name": PHASE, "p_status_counts": counts, "p_context": {}})
    logger.info("INCOME_MATCHING %s: %s txns %s", ctx.run_id, len(txns), counts)
    return PhaseOutcome.complete(phase=PHASE, transactions=len(txns), **counts)


def _match_income(txn, invoices) -> tuple[dict[str, Any] | None, str, bool]:
    ref = (txn.get("reference") or "").strip()
    amount = abs(float(txn["amount"])) if txn.get("amount") is not None else None

    if ref:
        for inv in invoices:
            if (inv.get("invoice_number") or "").strip() == ref:
                return inv, _amount_outcome(amount, inv.get("total_amount")), True

    if amount is not None:
        for inv in invoices:
            total = inv.get("total_amount")
            if total is not None and abs(abs(float(total)) - amount) < 0.005:
                return inv, "FULL_MATCH", False

    return None, "NO_MATCH", False


def _amount_outcome(amount: float | None, total: Any) -> str:
    if amount is None or total is None:
        return "FULL_MATCH"
    total_f = abs(float(total))
    if abs(total_f - amount) < 0.005:
        return "FULL_MATCH"
    return "PARTIAL_PAYMENT" if amount < total_f else "OVERPAYMENT"


def _date(value: Any) -> date | None:
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _in_period(d: date | None, start: date | None, end: date | None) -> bool:
    if d is None:
        return False
    if start and d < start:
        return False
    if end and d > end:
        return False
    return True


def _record_tool(deps: "PhaseDeps", tool: str, status: ToolStatus,
                 error_summary: str | None = None) -> None:
    params: dict[str, Any] = {
        "p_phase_state_id": deps.phase_state_id, "p_tool_name": tool, "p_status": status.value,
    }
    if error_summary:
        params["p_error_summary"] = error_summary[:2000]
    deps.gateway.rpc("record_tool_invocation", params)
