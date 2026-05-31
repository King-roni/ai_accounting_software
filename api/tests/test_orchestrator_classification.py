"""CLASSIFICATION engine: rule / vendor-memory / fallback paths + dedup."""
from __future__ import annotations

import pytest

from cyprus_bookkeeping_api.orchestrator.engines.classification import (
    handle_classification,
)
from cyprus_bookkeeping_api.orchestrator.models import OutcomeKind, RunContext
from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps

BIZ = "biz-1"


def _ctx() -> RunContext:
    return RunContext(
        run_id="run-1", organization_id="org-1", business_id=BIZ,
        workflow_type="OUT_MONTHLY", period_start="2026-05-01T00:00:00+00:00",
        period_end="2026-06-01T00:00:00+00:00", actor_user_id="user-1",
        principal_snapshot={}, trigger_kind="MANUAL", trigger_event_id=None,
    )


def _seed(gw, txns):
    gw.tables["transactions"] = txns
    gw.tables["recurring_vendor_memory"] = [{
        "counterparty_signature": "amazon web services", "suggested_type": "OUT_EXPENSE",
        "suggested_tag": "Cloud hosting", "confirmations_count": 5, "status": "ACTIVE",
        "business_id": BIZ,
    }]
    gw.tables["classification_auto_confirm_thresholds"] = [
        {"transaction_type": "OUT_EXPENSE", "threshold": 0.85, "never_auto_confirm": False, "business_id": None},
        {"transaction_type": "IN_INCOME", "threshold": 0.85, "never_auto_confirm": False, "business_id": None},
        {"transaction_type": "BANK_FEE", "threshold": 0.75, "never_auto_confirm": False, "business_id": None},
        {"transaction_type": "UNKNOWN", "threshold": 1.0, "never_auto_confirm": True, "business_id": None},
    ]
    gw.tables["tag_taxonomy_versions"] = [{
        "is_default": True, "retired_at": None, "definition": [
            {"transaction_type": "OUT_EXPENSE", "tag_name": "Office expenses", "is_type_default": True},
            {"transaction_type": "IN_INCOME", "tag_name": "Customer payment", "is_type_default": True},
            {"transaction_type": "BANK_FEE", "tag_name": "Bank fees", "is_type_default": True},
        ],
    }]
    gw.tables["bank_accounts"] = []
    gw.script("check_shared_phase_can_dedup", {"sibling_phase_completed": False})
    gw.script("get_classification_rules_for_business", lambda _p: [{
        "id": "rule-fee", "rule_kind": "REGEX_DESCRIPTION", "priority": 10,
        "rule_predicate": {"pattern": "^(Fee|Revolut Fee|Card replacement)", "flags": "i"},
        "assigned_type": "BANK_FEE", "assigned_tag": "Bank fees",
    }])


def _txn(tid, cp, direction, desc):
    return {"id": tid, "business_id": BIZ, "counterparty_name": cp, "direction": direction,
            "normalized_description": desc, "raw_description": None,
            "classification_status": "PENDING", "fx_paired_legs": None}


def _deps(gw):
    return PhaseDeps(gateway=gw, ctx=_ctx(), phase_state_id="ps-1", settings=None)


def test_vendor_memory_high_tier_auto_confirms(gw):
    _seed(gw, [_txn("t-aws", "Amazon Web Services", "OUT", "AWS hosting")])
    out = handle_classification(_deps(gw))
    assert out.kind == OutcomeKind.COMPLETE
    ac = gw.params_for("record_classification_auto_confirmed")
    assert len(ac) == 1
    assert ac[0]["p_chosen_type"] == "OUT_EXPENSE"
    assert ac[0]["p_classification_method"] == "VENDOR_MEMORY"
    assert ac[0]["p_merged_confidence"] == pytest.approx(0.90)


def test_direction_fallback_needs_confirmation(gw):
    _seed(gw, [_txn("t-coffee", "Costa Coffee", "OUT", "Card payment — coffee")])
    handle_classification(_deps(gw))
    nc = gw.params_for("record_classification_needs_confirmation")
    assert len(nc) == 1
    assert nc[0]["p_chosen_type"] == "OUT_EXPENSE"
    assert nc[0]["p_classification_method"] == "NO_AI_AVAILABLE"
    assert nc[0]["p_workflow_run_id"] == "run-1"
    assert gw.count("record_classification_auto_confirmed") == 0


def test_in_direction_fallback_is_income(gw):
    _seed(gw, [_txn("t-acme", "Acme Corp", "IN", "Client payment INV-0012")])
    handle_classification(_deps(gw))
    nc = gw.params_for("record_classification_needs_confirmation")
    assert nc[0]["p_chosen_type"] == "IN_INCOME"


def test_regex_rule_match_auto_confirms_bank_fee(gw):
    _seed(gw, [_txn("t-fee", "Revolut", "OUT", "Revolut Fee 1.50")])
    handle_classification(_deps(gw))
    assert gw.count("record_classification_rule_matched") == 1
    ac = gw.params_for("record_classification_auto_confirmed")
    assert ac[0]["p_chosen_type"] == "BANK_FEE"
    assert ac[0]["p_classification_method"] == "RULE"


def test_phase_boundary_and_snapshot_recorded(gw):
    _seed(gw, [_txn("t1", "X", "OUT", "y")])
    handle_classification(_deps(gw))
    for fn in ("record_classify_phase_started", "snapshot_taxonomy",
               "record_classify_phase_completed"):
        assert fn in gw.names()


def test_shared_phase_dedup_skips_work(gw):
    _seed(gw, [_txn("t1", "X", "OUT", "y")])
    gw.script("check_shared_phase_can_dedup",
              {"sibling_phase_completed": True, "sibling_phase_state_id": "sib-ps"})
    out = handle_classification(_deps(gw))
    assert out.kind == OutcomeKind.COMPLETE and out.detail.get("deduped") is True
    assert "record_shared_phase_dedup_hit" in gw.names()
    assert gw.count("record_classification_auto_confirmed") == 0
    assert gw.count("record_classification_needs_confirmation") == 0


def test_mixed_batch_counts(gw):
    _seed(gw, [
        _txn("t-aws", "Amazon Web Services", "OUT", "AWS hosting"),   # vendor → auto
        _txn("t-coffee", "Costa Coffee", "OUT", "coffee"),            # fallback → needs
        _txn("t-acme", "Acme Corp", "IN", "INV-0012"),                # fallback → needs
    ])
    out = handle_classification(_deps(gw))
    assert out.detail.get("CONFIRMED") == 1
    assert out.detail.get("NEEDS_CONFIRMATION") == 2
