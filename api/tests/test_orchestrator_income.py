"""INCOME_MATCHING engine: reference / amount / no-match outcomes + scope."""
from __future__ import annotations

from cyprus_bookkeeping_api.orchestrator.engines.income import handle_income_matching
from cyprus_bookkeeping_api.orchestrator.models import RunContext
from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps

BIZ = "biz-1"


def _ctx() -> RunContext:
    return RunContext(
        run_id="run-1", organization_id="org-1", business_id=BIZ,
        workflow_type="IN_MONTHLY", period_start="2026-05-01T00:00:00+00:00",
        period_end="2026-05-31T00:00:00+00:00", actor_user_id="user-1",
        principal_snapshot={}, trigger_kind="MANUAL", trigger_event_id=None,
    )


def _deps(gw):
    return PhaseDeps(gateway=gw, ctx=_ctx(), phase_state_id="ps-1", settings=None)


def _in_txn(tid, amount, ref, tdate="2026-05-04"):
    return {"id": tid, "business_id": BIZ, "direction": "IN", "income_match_outcome": None,
            "transaction_date": tdate, "amount": amount, "reference": ref}


def _apply(gw, tid):
    for p in gw.params_for("apply_income_match"):
        if p["p_transaction_id"] == tid:
            return p
    return None


def test_reference_full_match(gw):
    gw.tables["transactions"] = [_in_txn("t1", 1800, "INV-0012")]
    gw.tables["invoices"] = [{"id": "i1", "business_id": BIZ, "invoice_number": "INV-0012",
                              "total_amount": 1800}]
    out = handle_income_matching(_deps(gw))
    p = _apply(gw, "t1")
    assert p["p_outcome"] == "FULL_MATCH" and p["p_has_reference_match"] is True
    assert p["p_invoice_id"] == "i1"
    assert out.detail.get("FULL_MATCH") == 1


def test_reference_partial_payment(gw):
    gw.tables["transactions"] = [_in_txn("t1", 540, "INV-0013")]
    gw.tables["invoices"] = [{"id": "i1", "business_id": BIZ, "invoice_number": "INV-0013",
                              "total_amount": 1000}]
    handle_income_matching(_deps(gw))
    assert _apply(gw, "t1")["p_outcome"] == "PARTIAL_PAYMENT"


def test_amount_only_match(gw):
    gw.tables["transactions"] = [_in_txn("t1", 1800, None)]
    gw.tables["invoices"] = [{"id": "i1", "business_id": BIZ, "invoice_number": "X",
                              "total_amount": 1800}]
    p = (handle_income_matching(_deps(gw)), _apply(gw, "t1"))[1]
    assert p["p_outcome"] == "FULL_MATCH" and p["p_has_reference_match"] is False


def test_no_match(gw):
    gw.tables["transactions"] = [_in_txn("t1", 1800, "INV-0012")]
    gw.tables["invoices"] = [{"id": "i1", "business_id": BIZ, "invoice_number": "INV-9999",
                              "total_amount": 3570}]
    out = handle_income_matching(_deps(gw))
    p = _apply(gw, "t1")
    assert p["p_outcome"] == "NO_MATCH" and p["p_invoice_id"] is None
    assert out.detail.get("NO_MATCH") == 1


def test_scope_excludes_out_done_and_out_of_period(gw):
    gw.tables["transactions"] = [
        {**_in_txn("t-out", 100, None), "direction": "OUT"},
        {**_in_txn("t-done", 100, None), "income_match_outcome": "FULL_MATCH"},
        _in_txn("t-april", 100, None, tdate="2026-04-04"),
    ]
    gw.tables["invoices"] = []
    out = handle_income_matching(_deps(gw))
    assert out.detail.get("transactions") == 0
    assert gw.count("apply_income_match") == 0


def test_phase_recorders(gw):
    gw.tables["transactions"] = []
    gw.tables["invoices"] = []
    handle_income_matching(_deps(gw))
    assert "record_matching_phase_started" in gw.names()
    assert "record_matching_phase_completed" in gw.names()
    started = gw.params_for("record_matching_phase_started")[0]
    assert started["p_event_family"] == "INCOME_MATCHING"
