"""MATCHING engine: exact / strong-probable / no-match, scope, rejection memory."""
from __future__ import annotations

from cyprus_bookkeeping_api.orchestrator.engines.matching import handle_matching
from cyprus_bookkeeping_api.orchestrator.models import OutcomeKind, RunContext
from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps

BIZ = "biz-1"
ORG = "org-1"


def _ctx() -> RunContext:
    return RunContext(
        run_id="run-1", organization_id=ORG, business_id=BIZ,
        workflow_type="OUT_MONTHLY", period_start="2026-05-01T00:00:00+00:00",
        period_end="2026-05-31T00:00:00+00:00", actor_user_id="user-1",
        principal_snapshot={}, trigger_kind="MANUAL", trigger_event_id=None,
    )


def _deps(gw):
    return PhaseDeps(gateway=gw, ctx=_ctx(), phase_state_id="ps-1", settings=None)


def _txn(tid, cp, amount, tdate):
    return {"id": tid, "business_id": BIZ, "transaction_type": "OUT_EXPENSE",
            "match_status": "UNMATCHED", "counterparty_name": cp, "amount": amount,
            "currency": "EUR", "transaction_date": tdate, "reference": None}


def _doc(did, supplier, total, ddate, inv=None):
    return {"id": did, "business_id": BIZ, "supplier_name": supplier,
            "amount_total": total, "currency": "EUR", "invoice_date": ddate,
            "invoice_number": inv}


def _weights(gw):
    gw.tables["match_signal_weights"] = [
        {"signal_name": "amount_exact_match", "weight": 0.20, "enabled": True},
        {"signal_name": "supplier_exact_match", "weight": 0.20, "enabled": True},
        {"signal_name": "date_proximity", "weight": 0.15, "enabled": True},
        {"signal_name": "currency_match", "weight": 0.10, "enabled": True},
        {"signal_name": "invoice_number_match", "weight": 0.10, "enabled": True},
        {"signal_name": "supplier_fuzzy_match", "weight": 0.10, "enabled": True},
        {"signal_name": "recurring_vendor_signal", "weight": 0.05, "enabled": True},
    ]


def _level_for(gw, tid):
    for p in gw.params_for("apply_match_score"):
        if p["p_transaction_id"] == tid:
            return p["p_match_level"]
    return None


def test_exact_match(gw):
    _weights(gw)
    gw.tables["transactions"] = [_txn("t-costa", "Costa Coffee", -42.5, "2026-05-02")]
    gw.tables["documents"] = [_doc("d-costa", "Costa Coffee", 42.5, "2026-05-02")]
    out = handle_matching(_deps(gw))
    assert out.kind == OutcomeKind.COMPLETE
    assert _level_for(gw, "t-costa") == "EXACT"


def test_strong_probable_on_fuzzy_supplier(gw):
    _weights(gw)
    gw.tables["transactions"] = [_txn("t-aws", "Amazon Web Services", -213.77, "2026-05-09")]
    gw.tables["documents"] = [_doc("d-aws", "Amazon Web Services EMEA", 213.77, "2026-05-09")]
    handle_matching(_deps(gw))
    assert _level_for(gw, "t-aws") == "STRONG_PROBABLE"


def test_no_match_when_no_candidate(gw):
    _weights(gw)
    gw.tables["transactions"] = [_txn("t-jb", "JetBrains", -89.99, "2026-05-28")]
    gw.tables["documents"] = []  # no candidate
    out = handle_matching(_deps(gw))
    assert gw.count("record_match_no_match") == 1
    assert gw.params_for("record_match_no_match")[0]["p_transaction_id"] == "t-jb"
    assert out.detail.get("NO_MATCH") == 1


def test_far_date_is_no_match(gw):
    _weights(gw)
    gw.tables["transactions"] = [_txn("t-x", "Foo", -100.0, "2026-05-02")]
    gw.tables["documents"] = [_doc("d-x", "Foo", 100.0, "2026-01-01")]  # >30 days
    handle_matching(_deps(gw))
    assert gw.count("record_match_no_match") == 1
    assert gw.count("apply_match_score") == 0


def test_scope_excludes_non_out_expense_and_matched_and_out_of_period(gw):
    _weights(gw)
    gw.tables["transactions"] = [
        {**_txn("t-in", "Acme", 100.0, "2026-05-05"), "transaction_type": "IN_INCOME"},
        {**_txn("t-done", "X", -10.0, "2026-05-05"), "match_status": "MATCHED_CONFIRMED"},
        {**_txn("t-april", "Y", -10.0, "2026-04-05")},  # out of period
    ]
    gw.tables["documents"] = []
    out = handle_matching(_deps(gw))
    assert out.detail.get("transactions") == 0
    assert gw.count("apply_match_score") == 0
    assert gw.count("record_match_no_match") == 0


def test_rejection_memory_excludes_pair(gw):
    _weights(gw)
    gw.tables["transactions"] = [_txn("t-costa", "Costa Coffee", -42.5, "2026-05-02")]
    gw.tables["documents"] = [_doc("d-costa", "Costa Coffee", 42.5, "2026-05-02")]
    gw.tables["match_rejection_memory"] = [
        {"business_id": BIZ, "transaction_id": "t-costa", "document_id": "d-costa"},
    ]
    handle_matching(_deps(gw))
    assert gw.count("apply_match_score") == 0
    assert gw.count("record_match_no_match") == 1


def test_phase_boundary_and_deferred_markers(gw):
    _weights(gw)
    gw.tables["transactions"] = []
    gw.tables["documents"] = []
    handle_matching(_deps(gw))
    assert "record_matching_phase_started" in gw.names()
    assert "record_matching_phase_completed" in gw.names()
    skipped_tools = {p["p_tool_name"] for p in gw.params_for("record_tool_invocation")
                     if p["p_status"] == "SKIPPED"}
    assert {"matching.detect_split_payments", "matching.detect_duplicates",
            "matching.generate_reasons"} <= skipped_tools
