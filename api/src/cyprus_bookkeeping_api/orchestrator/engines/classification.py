"""CLASSIFICATION engine (Block 08) — deterministic-first transaction classifier.

Three layers per the spec (Docs/blocks/08 + CLASSIFY_MATCH_ENGINE_CONTRACT.md):
  L1 deterministic rules (classification_rules) → L2 recurring vendor memory →
  L3 AI fallback (STUB until P2). Confidences merge; a per-type auto-confirm
  threshold decides CONFIRMED vs NEEDS_CONFIRMATION. Persistence + review-issue
  raising go through the DB recorders; this module only *decides*.

Reference data is read live (rules / thresholds / taxonomy / vendor memory) — no
hardcoding. Layer-3 AI is stubbed: unresolved rows take a direction-based
fallback at low confidence (→ NEEDS_CONFIRMATION), method NO_AI_AVAILABLE.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from cyprus_bookkeeping_api.orchestrator.models import PhaseOutcome, ToolStatus

if TYPE_CHECKING:
    from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps

logger = logging.getLogger(__name__)

PHASE = "CLASSIFICATION"

# Vendor-memory tier confidences (spec: 1 conf = medium/review, 3+ = high/auto).
_VENDOR_HIGH = 0.90  # > every per-type threshold except UNKNOWN
_VENDOR_MEDIUM = 0.65
_RULE_CONFIDENCE = 0.95
_FALLBACK_CONFIDENCE = 0.40  # below all thresholds → NEEDS_CONFIRMATION

# Best-effort tax-authority keywords (no tax_authorities registry table exists).
_TAX_KEYWORDS = ("tax department", "inland revenue", "vat service", "vat office",
                 "tax authority", "mof ", "ministry of finance")

_PENDING_STATUSES = {None, "PENDING"}


@dataclass
class _Decision:
    chosen_type: str
    tag: str | None
    confidence: float
    method: str  # RULE | VENDOR_MEMORY | NO_AI_AVAILABLE
    rule_id: str | None = None


def handle_classification(deps: PhaseDeps) -> PhaseOutcome:
    gw, ctx = deps.gateway, deps.ctx
    actor = ctx.actor_user_id

    # Shared phase: if the OUT/IN sibling already classified the shared txns, reuse.
    dedup = gw.rpc("check_shared_phase_can_dedup",
                   {"p_run_id": ctx.run_id, "p_phase_name": PHASE}) or {}
    if isinstance(dedup, dict) and dedup.get("sibling_phase_completed"):
        gw.rpc("record_shared_phase_dedup_hit", {
            "p_run_id": ctx.run_id, "p_phase_name": PHASE,
            "p_sibling_phase_state_id": dedup.get("sibling_phase_state_id"),
            "p_actor_user_id": actor,
        })
        _record_tool(deps, "classification.assign_status", ToolStatus.SKIPPED,
                     "shared-phase dedup: sibling run already classified")
        return PhaseOutcome.complete(phase=PHASE, deduped=True)

    gw.rpc("record_classify_phase_started",
           {"p_workflow_run_id": ctx.run_id, "p_user_id": actor})
    gw.rpc("snapshot_taxonomy", {"p_workflow_run_id": ctx.run_id, "p_user_id": actor})

    rules = sorted(
        gw.rpc("get_classification_rules_for_business",
               {"p_business_id": ctx.business_id}) or [],
        key=lambda r: r.get("priority", 1000),
    )
    thresholds = _load_thresholds(gw, ctx.business_id)
    default_tags = _load_default_tags(gw)
    vendor = _load_vendor_memory(gw, ctx.business_id)
    account_sigs = _load_account_signatures(gw, ctx.business_id)

    txns = [t for t in gw.select("transactions", filters={"business_id": ctx.business_id})
            if t.get("classification_status") in _PENDING_STATUSES]

    counts: dict[str, int] = {}
    for txn in txns:
        decision = _classify_one(deps, txn, rules, vendor, account_sigs, default_tags)
        thr, never = thresholds.get(decision.chosen_type, (1.0, True))
        auto = decision.confidence > thr and not never
        common = {
            "p_transaction_id": txn["id"],
            "p_merged_confidence": round(decision.confidence, 4),
            "p_chosen_type": decision.chosen_type,
            "p_classification_method": decision.method,
            "p_chosen_tag": decision.tag,
            "p_actor_user_id": actor,
        }
        if auto:
            gw.rpc("record_classification_auto_confirmed", common)
            counts["CONFIRMED"] = counts.get("CONFIRMED", 0) + 1
        else:
            gw.rpc("record_classification_needs_confirmation",
                   {**common, "p_workflow_run_id": ctx.run_id})
            counts["NEEDS_CONFIRMATION"] = counts.get("NEEDS_CONFIRMATION", 0) + 1

    _record_tool(deps, "classification.assign_status", ToolStatus.SUCCESS)
    gw.rpc("record_classify_phase_completed",
           {"p_workflow_run_id": ctx.run_id, "p_user_id": actor,
            "p_per_status_counts": counts})
    logger.info("CLASSIFICATION %s: %s txns %s", ctx.run_id, len(txns), counts)
    return PhaseOutcome.complete(phase=PHASE, transactions=len(txns), **counts)


def _classify_one(deps, txn, rules, vendor, account_sigs, default_tags) -> _Decision:
    gw, ctx, actor = deps.gateway, deps.ctx, deps.ctx.actor_user_id

    # ---- Layer 1: deterministic rules ----
    matches = [m for m in (_match_rule(r, txn, account_sigs) for r in rules) if m]
    types = {m[0] for m in matches}
    l1: tuple[str, str | None] | None = None
    if len(types) > 1:
        gw.rpc("record_classification_rule_conflict", {
            "p_transaction_id": txn["id"], "p_workflow_run_id": ctx.run_id,
            "p_conflicting_rule_ids": [m[2] for m in matches], "p_actor_user_id": actor,
        })
        l1 = (matches[0][0], matches[0][1])  # highest-priority (rules pre-sorted)
        l1_conf = _FALLBACK_CONFIDENCE  # conflict → route to review
    elif matches:
        gw.rpc("record_classification_rule_matched", {
            "p_transaction_id": txn["id"], "p_rule_id": matches[0][2],
            "p_confidence": _RULE_CONFIDENCE, "p_actor_user_id": actor,
        })
        l1 = (matches[0][0], matches[0][1])
        l1_conf = _RULE_CONFIDENCE
    else:
        gw.rpc("record_classification_rule_no_match",
               {"p_transaction_id": txn["id"], "p_actor_user_id": actor})

    if l1:
        return _Decision(l1[0], l1[1] or default_tags.get(l1[0]), l1_conf, "RULE",
                         matches[0][2])

    # ---- Layer 2: recurring vendor memory ----
    hit = _vendor_hit(txn, vendor)
    if hit:
        vtype, vtag, vconf = hit
        return _Decision(vtype, vtag or default_tags.get(vtype), vconf, "VENDOR_MEMORY")

    # ---- Layer 3: AI fallback STUB → direction-based default (low confidence) ----
    direction = (txn.get("direction") or "").upper()
    if direction == "OUT":
        ctype = "OUT_EXPENSE"
    elif direction == "IN":
        ctype = "IN_INCOME"
    else:
        ctype = "UNKNOWN"
    return _Decision(ctype, default_tags.get(ctype), _FALLBACK_CONFIDENCE,
                     "NO_AI_AVAILABLE")


def _match_rule(rule, txn, account_sigs) -> tuple[str, str | None, str] | None:
    """Return (type, tag, rule_id) if the rule matches the txn, else None."""
    kind = rule.get("rule_kind")
    pred = rule.get("rule_predicate") or {}
    desc = (txn.get("normalized_description") or txn.get("raw_description") or "")
    cp = (txn.get("counterparty_name") or "").strip().lower()
    out = (rule.get("assigned_type"), rule.get("assigned_tag"), rule.get("id") or rule.get("rule_id"))

    if kind == "REGEX_DESCRIPTION":
        pattern = pred.get("pattern")
        if not pattern:
            return None
        flags = re.IGNORECASE if "i" in (pred.get("flags") or "") else 0
        if not re.search(pattern, desc, flags):
            return None
        if pred.get("requires") == "fx_paired_legs_not_null" and not txn.get("fx_paired_legs"):
            return None
        return out
    if kind == "OWN_ACCOUNT_TRANSFER":
        ident = (txn.get("counterparty_identifier_masked") or "").lower()
        if cp and (cp in account_sigs or ident in account_sigs):
            return out
        return None
    if kind == "COUNTERPARTY_NAME":  # tax_authorities registry absent → keyword heuristic
        if cp and any(kw in cp for kw in _TAX_KEYWORDS):
            return out
        return None
    if kind == "COUNTERPARTY_DOMAIN":
        # registry (known_suppliers / known_clients) does not exist as a table →
        # cannot assert "known counterparty"; rule does not fire (see contract).
        return None
    return None  # AMOUNT_THRESHOLD / MERCHANT_CATEGORY_CODE: not seeded


def _vendor_hit(txn, vendor) -> tuple[str, str | None, float] | None:
    sig = (txn.get("counterparty_name") or "").strip().lower()
    row = vendor.get(sig)
    if not row:
        return None
    confirmations = row.get("confirmations_count") or 0
    conf = _VENDOR_HIGH if confirmations >= 3 else _VENDOR_MEDIUM
    return row.get("suggested_type"), row.get("suggested_tag"), conf


def _load_thresholds(gw, business_id) -> dict[str, tuple[float, bool]]:
    rows = gw.select("classification_auto_confirm_thresholds")
    out: dict[str, tuple[float, bool]] = {}
    for r in sorted(rows, key=lambda x: x.get("business_id") is not None):
        # global first, then business-specific overrides
        if r.get("business_id") in (None, business_id):
            out[r["transaction_type"]] = (float(r["threshold"]),
                                          bool(r.get("never_auto_confirm")))
    return out


def _load_default_tags(gw) -> dict[str, str]:
    rows = gw.select("tag_taxonomy_versions")
    active = next((r for r in rows if r.get("retired_at") is None and r.get("is_default")),
                  rows[0] if rows else None)
    tags: dict[str, str] = {}
    for entry in (active or {}).get("definition", []) or []:
        if entry.get("is_type_default"):
            tags[entry["transaction_type"]] = entry["tag_name"]
    return tags


def _load_vendor_memory(gw, business_id) -> dict[str, dict[str, Any]]:
    rows = gw.select("recurring_vendor_memory", filters={"business_id": business_id})
    return {
        (r.get("counterparty_signature") or "").strip().lower(): r
        for r in rows
        if r.get("status") == "ACTIVE"
    }


def _load_account_signatures(gw, business_id) -> set[str]:
    sigs: set[str] = set()
    for a in gw.select("bank_accounts", filters={"business_id": business_id}):
        for key in ("account_name", "iban_masked", "iban_encrypted"):
            val = a.get(key)
            if val:
                sigs.add(str(val).strip().lower())
    return sigs


def _record_tool(deps: PhaseDeps, tool: str, status: ToolStatus,
                 error_summary: str | None = None) -> None:
    params: dict[str, Any] = {
        "p_phase_state_id": deps.phase_state_id,
        "p_tool_name": tool,
        "p_status": status.value,
    }
    if error_summary:
        params["p_error_summary"] = error_summary[:2000]
    deps.gateway.rpc("record_tool_invocation", params)
