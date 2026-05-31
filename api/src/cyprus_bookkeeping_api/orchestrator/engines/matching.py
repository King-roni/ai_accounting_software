"""MATCHING engine (Block 10) — deterministic transaction↔document scorer.

Deterministic-first (Docs/blocks/10 + CLASSIFY_MATCH_ENGINE_CONTRACT.md): for
each in-scope OUT_EXPENSE transaction, score candidate documents on the live
``match_signal_weights`` signals, pick the best above threshold, classify into
EXACT / STRONG_PROBABLE / WEAK_POSSIBLE, and persist via ``apply_match_score``
(the single match_records writer). Transactions with no qualifying candidate go
through ``record_match_no_match`` (Missing Documents). Rejection memory is
honoured (pair-scoped, never re-suggested).

MVP boundary (documented in the contract): the core scorer + NO_MATCH path +
deterministic plain-language reasons ship now. Combinatorial split-payment
detection, the duplicate-detection pass, and AI reason rephrasing (Tier 2/3)
record SKIPPED markers and land later.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import date
from difflib import SequenceMatcher
from typing import TYPE_CHECKING, Any

from cyprus_bookkeeping_api.orchestrator.models import PhaseOutcome, ToolStatus

if TYPE_CHECKING:
    from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps

logger = logging.getLogger(__name__)

PHASE = "MATCHING"
EVENT_FAMILY = "MATCHING"
_NEEDS_MATCH_STATUS = {"UNMATCHED", None}
_WEAK_MIN_SCORE = 0.50
_FUZZY_STRONG = 0.80
_LEGAL_SUFFIXES = (" ltd", " ltd.", " limited", " llc", " inc", " inc.", " plc",
                   " gmbh", " bv", " ag", " sa", " oy", " co")


@dataclass
class _ScoredCandidate:
    document_id: str
    score: float
    level: str  # EXACT | STRONG_PROBABLE | WEAK_POSSIBLE
    signals: dict[str, Any]
    reason: str
    days: int = field(default=0)


def handle_matching(deps: "PhaseDeps") -> PhaseOutcome:
    gw, ctx = deps.gateway, deps.ctx
    actor = ctx.actor_user_id
    gw.rpc("record_matching_phase_started",
           {"p_workflow_run_id": ctx.run_id, "p_event_family": EVENT_FAMILY,
            "p_phase_name": PHASE, "p_context": {}})

    weights = _load_weights(gw)
    vendor_sigs = _load_vendor_signatures(gw, ctx.business_id)
    rejected = _load_rejected_pairs(gw, ctx.business_id)
    p_start, p_end = _date(ctx.period_start), _date(ctx.period_end)

    txns = [
        t for t in gw.select("transactions", filters={"business_id": ctx.business_id})
        if t.get("transaction_type") == "OUT_EXPENSE"
        and t.get("match_status") in _NEEDS_MATCH_STATUS
        and _in_period(_date(t.get("transaction_date")), p_start, p_end)
    ]
    documents = gw.select("documents", filters={"business_id": ctx.business_id})

    counts: dict[str, int] = {}
    for txn in txns:
        best = _best_candidate(txn, documents, weights, vendor_sigs, rejected)
        if best is None:
            gw.rpc("record_match_no_match", {
                "p_organization_id": ctx.organization_id, "p_business_id": ctx.business_id,
                "p_transaction_id": txn["id"], "p_workflow_run_id": ctx.run_id,
                "p_actor_user_id": actor, "p_context": {},
            })
            counts["NO_MATCH"] = counts.get("NO_MATCH", 0) + 1
            continue
        gw.rpc("apply_match_score", {
            "p_organization_id": ctx.organization_id, "p_business_id": ctx.business_id,
            "p_transaction_id": txn["id"], "p_document_id": best.document_id,
            "p_signal_breakdown": best.signals, "p_match_score": round(best.score, 4),
            "p_match_level": best.level, "p_match_method": "DETERMINISTIC_RULE",
            "p_match_reason_plain_language": best.reason,
            "p_matched_by_system": "matching_engine", "p_context": {},
        })
        counts[best.level] = counts.get(best.level, 0) + 1

    # Secondary passes deferred to a follow-up (see contract): record markers.
    _record_tool(deps, "matching.score_pair", ToolStatus.SUCCESS)
    _record_tool(deps, "matching.detect_split_payments", ToolStatus.SKIPPED,
                 "combinatorial split detection deferred (MVP)")
    _record_tool(deps, "matching.detect_duplicates", ToolStatus.SKIPPED,
                 "duplicate-detection pass deferred (MVP)")
    _record_tool(deps, "matching.generate_reasons", ToolStatus.SKIPPED,
                 "AI reason rephrasing is P2; deterministic reasons used")

    gw.rpc("record_matching_phase_completed",
           {"p_workflow_run_id": ctx.run_id, "p_event_family": EVENT_FAMILY,
            "p_phase_name": PHASE, "p_status_counts": counts, "p_context": {}})
    logger.info("MATCHING %s: %s txns %s", ctx.run_id, len(txns), counts)
    return PhaseOutcome.complete(phase=PHASE, transactions=len(txns), **counts)


def _best_candidate(txn, documents, weights, vendor_sigs, rejected) -> _ScoredCandidate | None:
    best: _ScoredCandidate | None = None
    for doc in documents:
        if (txn["id"], doc["id"]) in rejected:
            continue
        scored = _score_pair(txn, doc, weights, vendor_sigs)
        if scored is None:
            continue
        if best is None or scored.score > best.score:
            best = scored
    return best


def _score_pair(txn, doc, weights, vendor_sigs) -> _ScoredCandidate | None:
    t_date, d_date = _date(txn.get("transaction_date")), _date(doc.get("invoice_date"))
    if t_date is None or d_date is None:
        return None
    days = abs((t_date - d_date).days)
    if days > 30:
        return None

    amt_exact = _amount_eq(txn.get("amount"), doc.get("amount_total"))
    currency = (txn.get("currency") or "") == (doc.get("currency") or "")
    t_sup, d_sup = _norm(txn.get("counterparty_name")), _norm(doc.get("supplier_name"))
    sup_exact = bool(t_sup) and t_sup == d_sup
    sup_fuzzy = 0.0 if sup_exact else SequenceMatcher(None, t_sup, d_sup).ratio()
    inv_match = bool((txn.get("reference") or "").strip()
                     and (txn.get("reference") or "").strip() == (doc.get("invoice_number") or "").strip())
    recurring = t_sup in vendor_sigs
    date_prox = 1.0 if days <= 3 else 0.6 if days <= 10 else 0.3

    signals = {
        "amount_exact_match": 1.0 if amt_exact else 0.0,
        "currency_match": 1.0 if currency else 0.0,
        "supplier_exact_match": 1.0 if sup_exact else 0.0,
        "supplier_fuzzy_match": 0.0 if sup_exact else round(sup_fuzzy, 3),
        "date_proximity": date_prox,
        "invoice_number_match": 1.0 if inv_match else 0.0,
        "recurring_vendor_signal": 1.0 if recurring else 0.0,
    }
    score = sum(val * weights.get(name, 0.0) for name, val in signals.items())

    if amt_exact and currency and sup_exact and days <= 3:
        level = "EXACT"
    elif amt_exact and days <= 10 and (sup_exact or sup_fuzzy >= _FUZZY_STRONG or recurring):
        level = "STRONG_PROBABLE"
    elif score >= _WEAK_MIN_SCORE:
        level = "WEAK_POSSIBLE"
    else:
        return None

    supplier = doc.get("supplier_name") or txn.get("counterparty_name") or "supplier"
    reason = (f"Matched on amount {doc.get('currency') or ''} {doc.get('amount_total')}, "
              f"supplier {supplier}, "
              f"document date {'same day as' if days == 0 else f'{days} day(s) from'} "
              f"the transaction.")
    return _ScoredCandidate(doc["id"], score, level, signals, reason, days)


# --------------------------------------------------------------------------- #
def _norm(name: str | None) -> str:
    s = (name or "").strip().lower()
    for suffix in _LEGAL_SUFFIXES:
        if s.endswith(suffix):
            s = s[: -len(suffix)].strip()
            break
    return " ".join(s.split())


def _amount_eq(txn_amount, doc_total) -> bool:
    if txn_amount is None or doc_total is None:
        return False
    return abs(abs(float(txn_amount)) - abs(float(doc_total))) < 0.005


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


def _load_weights(gw) -> dict[str, float]:
    return {
        r["signal_name"]: float(r["weight"])
        for r in gw.select("match_signal_weights")
        if r.get("enabled", True)
    }


def _load_vendor_signatures(gw, business_id) -> set[str]:
    return {
        _norm(r.get("counterparty_signature"))
        for r in gw.select("recurring_vendor_memory", filters={"business_id": business_id})
        if r.get("status") == "ACTIVE"
    }


def _load_rejected_pairs(gw, business_id) -> set[tuple[str, str]]:
    pairs: set[tuple[str, str]] = set()
    for r in gw.select("match_rejection_memory", filters={"business_id": business_id}):
        tid, did = r.get("transaction_id"), r.get("document_id")
        if tid and did:
            pairs.add((tid, did))
    return pairs


def _record_tool(deps: "PhaseDeps", tool: str, status: ToolStatus,
                 error_summary: str | None = None) -> None:
    params: dict[str, Any] = {
        "p_phase_state_id": deps.phase_state_id, "p_tool_name": tool, "p_status": status.value,
    }
    if error_summary:
        params["p_error_summary"] = error_summary[:2000]
    deps.gateway.rpc("record_tool_invocation", params)
