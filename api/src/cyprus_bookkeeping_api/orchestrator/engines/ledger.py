"""LEDGER_PREPARATION engine (Block 11) — draft ledger entry derivation.

Real RPC sequence (verified against the live implementations, not the tool
declarations — see CLASSIFY_MATCH_ENGINE_CONTRACT.md):

  per in-period transaction:
    1. resolve_counterparty(txn, match_record, doc country/vat)  — proposer + audit
    2. prepare_ledger_entries(txn, ...)                          — the single writer:
         · UNKNOWN type → HELD + HIGH review issue (no entries)
         · else → PRIMARY debit/credit draft rows (+ VAT-split lines if VAT flags),
           idempotent delete-and-replace per (txn, mapping_version)
    3. enrich each PRIMARY draft entry (post-creation, take draft_ledger_entry_id):
         classify_vat_treatment → compute_reverse_charge_and_vies →
         compute_vat_and_evidence_flags(+ matched doc VAT/evidence)
  then generate_vat_explanations (AI, Tier 2/3) → STUB until P2.

Exit gate ``evaluate_ledger_exit_gate`` requires every in-scope txn to have ≥1
draft entry OR a LEDGER_HELD_PENDING_CLASSIFICATION audit; the engine loop holds
the run (REVIEW_HOLD) if it doesn't pass — e.g. when the business chart of
accounts / mapping version is not yet configured (prepare raises). That hold is
correct: no chart → no derivable ledger. Enrichers + resolve are best-effort
(failures are logged, not fatal); the writer's outcome drives the phase.
"""
from __future__ import annotations

import logging
from datetime import date
from typing import TYPE_CHECKING, Any, cast

from cyprus_bookkeeping_api.orchestrator.models import PhaseOutcome, ToolStatus, first_row
from cyprus_bookkeeping_api.orchestrator.rpc import RpcError

if TYPE_CHECKING:
    from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps

logger = logging.getLogger(__name__)

PHASE = "LEDGER_PREPARATION"


def handle_ledger_preparation(deps: "PhaseDeps") -> PhaseOutcome:
    gw, ctx = deps.gateway, deps.ctx
    actor = ctx.actor_user_id
    gw.rpc("record_ledger_phase_started",
           {"p_workflow_run_id": ctx.run_id, "p_phase_name": PHASE, "p_context": {}})

    p_start, p_end = _date(ctx.period_start), _date(ctx.period_end)
    txns = [t for t in gw.select("transactions", filters={"business_id": ctx.business_id})
            if _in_period(_date(t.get("transaction_date")), p_start, p_end)]
    matches: dict[str, dict[str, Any]] = {}
    for m in gw.select("match_records", filters={"business_id": ctx.business_id}):
        matches.setdefault(m["transaction_id"], m)
    docs = {d["id"]: d for d in gw.select("documents", filters={"business_id": ctx.business_id})}

    counts: dict[str, int] = {}
    for txn in txns:
        mr = matches.get(txn["id"])
        doc = docs.get(mr.get("document_id")) if mr else None

        _safe(gw, "resolve_counterparty", {
            "p_organization_id": ctx.organization_id, "p_business_id": ctx.business_id,
            "p_transaction_id": txn["id"], "p_workflow_run_id": ctx.run_id,
            "p_match_record_id": mr["id"] if mr else None,
            "p_doc_country": (doc or {}).get("supplier_country"),
            "p_doc_vat_number": (doc or {}).get("supplier_vat_number"),
            "p_doc_extraction_layer": None,
            "p_iban_country_candidate": txn.get("counterparty_country"),
            "p_actor_user_id": actor, "p_context": {},
        })

        try:
            prepared = gw.rpc("prepare_ledger_entries", {
                "p_organization_id": ctx.organization_id, "p_business_id": ctx.business_id,
                "p_transaction_id": txn["id"], "p_workflow_run_id": ctx.run_id,
                "p_match_record_id": mr["id"] if mr else None,
                "p_input_vat_reclaimable": False, "p_output_vat_due": False,
                "p_vat_amount": None, "p_entry_period": _iso(txn.get("transaction_date")),
                "p_actor_user_id": actor, "p_context": {},
            })
        except RpcError as exc:
            # No active mapping version / no mapping rule → chart not configured.
            # Non-fatal here; the exit gate will hold the run with a clear reason.
            logger.warning("prepare_ledger_entries failed for %s: %s", txn["id"], exc)
            counts["CHART_NOT_CONFIGURED"] = counts.get("CHART_NOT_CONFIGURED", 0) + 1
            continue

        res = cast("dict[str, Any]", first_row(prepared) or {})
        decision = res.get("decision")
        if decision == "HELD":
            counts["HELD"] = counts.get("HELD", 0) + 1
            continue
        if decision == "PREPARED":
            for entry in gw.select("draft_ledger_entries",
                                   filters={"parent_transaction_id": txn["id"]}):
                if entry.get("entry_kind") != "PRIMARY":
                    continue
                eid = entry["id"]
                _safe(gw, "classify_vat_treatment", {
                    "p_organization_id": ctx.organization_id, "p_business_id": ctx.business_id,
                    "p_draft_ledger_entry_id": eid, "p_workflow_run_id": ctx.run_id,
                    "p_actor_user_id": actor, "p_context": {}})
                _safe(gw, "compute_reverse_charge_and_vies", {
                    "p_organization_id": ctx.organization_id, "p_business_id": ctx.business_id,
                    "p_draft_ledger_entry_id": eid, "p_workflow_run_id": ctx.run_id,
                    "p_actor_user_id": actor, "p_context": {}})
                _safe(gw, "compute_vat_and_evidence_flags", {
                    "p_organization_id": ctx.organization_id, "p_business_id": ctx.business_id,
                    "p_draft_ledger_entry_id": eid, "p_workflow_run_id": ctx.run_id,
                    "p_document_extracted_vat_amount": (doc or {}).get("vat_amount"),
                    "p_matched_evidence_kind": (doc or {}).get("document_type"),
                    "p_actor_user_id": actor, "p_context": {}})
            counts["PREPARED"] = counts.get("PREPARED", 0) + 1

    _record_tool(deps, "ledger.prepare_entries", ToolStatus.SUCCESS)
    _record_tool(deps, "ledger.generate_vat_explanations", ToolStatus.SKIPPED,
                 "AI VAT explanations are P2; entries carry structured data only")
    gw.rpc("record_ledger_phase_completed",
           {"p_workflow_run_id": ctx.run_id, "p_phase_name": PHASE,
            "p_status_counts": counts, "p_context": {}})
    logger.info("LEDGER_PREPARATION %s: %s txns %s", ctx.run_id, len(txns), counts)
    return PhaseOutcome.complete(phase=PHASE, transactions=len(txns), **counts)


def _safe(gw, fn: str, params: dict[str, Any]) -> None:
    """Best-effort RPC: enrichment/resolve failures are logged, never fatal."""
    try:
        gw.rpc(fn, params)
    except RpcError as exc:
        logger.warning("ledger enrichment %s failed: %s", fn, exc)


def _date(value: Any) -> date | None:
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _iso(value: Any) -> str | None:
    d = _date(value)
    return d.isoformat() if d else None


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
