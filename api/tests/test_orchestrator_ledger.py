"""LEDGER_PREPARATION engine: prepared+enrich / held / chart-not-configured / scope."""
from __future__ import annotations

from cyprus_bookkeeping_api.orchestrator.engines.ledger import handle_ledger_preparation
from cyprus_bookkeeping_api.orchestrator.models import OutcomeKind, RunContext
from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps
from cyprus_bookkeeping_api.orchestrator.rpc import RpcError

BIZ = "biz-1"


def _ctx() -> RunContext:
    return RunContext(
        run_id="run-1", organization_id="org-1", business_id=BIZ,
        workflow_type="OUT_MONTHLY", period_start="2026-05-01T00:00:00+00:00",
        period_end="2026-05-31T00:00:00+00:00", actor_user_id="user-1",
        principal_snapshot={}, trigger_kind="MANUAL", trigger_event_id=None,
    )


def _deps(gw):
    return PhaseDeps(gateway=gw, ctx=_ctx(), phase_state_id="ps-1", settings=None)


def _txn(tid="t1", ttype="OUT_EXPENSE", tdate="2026-05-09"):
    return {"id": tid, "business_id": BIZ, "transaction_type": ttype, "direction": "OUT",
            "transaction_date": tdate, "amount": -213.77, "counterparty_country": "US"}


def _raise(_p):
    raise RpcError("NO_ACTIVE_MAPPING_VERSION_FOR_PERIOD")


def test_prepared_creates_and_enriches(gw):
    gw.tables["transactions"] = [_txn()]
    gw.tables["draft_ledger_entries"] = [
        {"id": "e1", "parent_transaction_id": "t1", "entry_kind": "PRIMARY"},
        {"id": "e2", "parent_transaction_id": "t1", "entry_kind": "PRIMARY"},
        {"id": "e3", "parent_transaction_id": "t1", "entry_kind": "VAT_RECLAIM"},
    ]
    gw.script("prepare_ledger_entries", {"decision": "PREPARED", "entries_created": 2})
    out = handle_ledger_preparation(_deps(gw))
    assert out.kind == OutcomeKind.COMPLETE and out.detail.get("PREPARED") == 1
    assert gw.count("classify_vat_treatment") == 2   # PRIMARY entries only
    assert gw.count("compute_reverse_charge_and_vies") == 2
    assert gw.count("compute_vat_and_evidence_flags") == 2
    assert "record_ledger_phase_started" in gw.names()
    assert "record_ledger_phase_completed" in gw.names()


def test_held_unknown_type(gw):
    gw.tables["transactions"] = [_txn(ttype="UNKNOWN")]
    gw.script("prepare_ledger_entries", {"decision": "HELD", "reason": "UNKNOWN_TYPE"})
    out = handle_ledger_preparation(_deps(gw))
    assert out.detail.get("HELD") == 1
    assert gw.count("classify_vat_treatment") == 0


def test_chart_not_configured_is_graceful(gw):
    gw.tables["transactions"] = [_txn()]
    gw.script("prepare_ledger_entries", _raise)
    out = handle_ledger_preparation(_deps(gw))
    assert out.kind == OutcomeKind.COMPLETE
    assert out.detail.get("CHART_NOT_CONFIGURED") == 1
    assert gw.count("classify_vat_treatment") == 0


def test_enricher_errors_non_fatal(gw):
    gw.tables["transactions"] = [_txn()]
    gw.tables["draft_ledger_entries"] = [
        {"id": "e1", "parent_transaction_id": "t1", "entry_kind": "PRIMARY"}]
    gw.script("prepare_ledger_entries", {"decision": "PREPARED"})
    gw.script("compute_vat_and_evidence_flags", lambda _p: (_ for _ in ()).throw(RpcError("x")))
    out = handle_ledger_preparation(_deps(gw))
    assert out.kind == OutcomeKind.COMPLETE and out.detail.get("PREPARED") == 1


def test_scope_only_in_period(gw):
    gw.tables["transactions"] = [_txn(tdate="2026-04-09")]  # out of May period
    out = handle_ledger_preparation(_deps(gw))
    assert out.detail.get("transactions") == 0
    assert gw.count("prepare_ledger_entries") == 0
