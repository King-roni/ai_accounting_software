"""Unit specs for gates, phase handlers, and the outbox consumer."""
from __future__ import annotations

from cyprus_bookkeeping_api.orchestrator import phases
from cyprus_bookkeeping_api.orchestrator.gates import GateEngine
from cyprus_bookkeeping_api.orchestrator.models import (
    GateDecision,
    OutcomeKind,
    RunContext,
)
from cyprus_bookkeeping_api.orchestrator.outbox import consume_pending
from cyprus_bookkeeping_api.orchestrator.phases import PhaseDeps, PhaseRegistry


def _ctx(workflow_type: str = "OUT_MONTHLY") -> RunContext:
    return RunContext(
        run_id="run-1",
        organization_id="org-1",
        business_id="biz-1",
        workflow_type=workflow_type,
        period_start="2026-05-01T00:00:00+00:00",
        period_end="2026-06-01T00:00:00+00:00",
        actor_user_id="user-1",
        principal_snapshot={},
        trigger_kind="MANUAL",
        trigger_event_id=None,
    )


# ----------------------------- gates --------------------------------------- #
def test_gate_engine_advances_when_no_gates(gw):
    result = GateEngine().evaluate(gw, _ctx(), "ps-1", "INGESTION", "ENTRY")
    assert result.hold is False


def test_gate_engine_default_unregistered_gate_advances_and_records(gw):
    gw.script("list_phase_gates", lambda _p: [{"gate_name": "some.gate_v1"}])
    result = GateEngine(evaluators={}).evaluate(gw, _ctx(), "ps-1", "OUT_FILTER", "EXIT")
    assert result.hold is False
    decisions = [p["p_decision"] for p in gw.params_for("record_gate_decision")]
    assert decisions == ["ADVANCE"]


def test_gate_engine_holds_on_blocking_evaluator(gw):
    gw.script("list_phase_gates", lambda _p: [{"gate_name": "x.block_v1"}])
    engine = GateEngine(evaluators={
        "x.block_v1": lambda *_: (GateDecision.HOLD, "stop"),
    })
    result = engine.evaluate(gw, _ctx(), "ps-1", "MATCHING", "EXIT")
    assert result.hold is True and result.gate_name == "x.block_v1"
    rec = gw.params_for("record_gate_decision")[0]
    assert rec["p_decision"] == "HOLD" and rec["p_severity"] == "BLOCKING"


def test_gate_engine_db_satisfied_evaluator_wired_for_ledger_exit(gw):
    gw.script("list_phase_gates",
              lambda _p: [{"gate_name": "ledger.exit_all_in_scope_entries_drafted_or_held_v1"}])
    gw.script("evaluate_ledger_exit_gate", {"satisfied": False, "reason": "TX_NOT_DRAFTED"})
    result = GateEngine().evaluate(gw, _ctx(), "ps-1", "LEDGER_PREPARATION", "EXIT")
    assert result.hold is True
    assert "evaluate_ledger_exit_gate" in gw.names()


# ----------------------------- phases -------------------------------------- #
def _deps(gw, settings, workflow_type="OUT_MONTHLY"):
    return PhaseDeps(gateway=gw, ctx=_ctx(workflow_type), phase_state_id="ps-1",
                     settings=settings)


def test_ingestion_handler_unsnoozes(gw, settings):
    out = phases.handle_ingestion(_deps(gw, settings))
    assert out.kind == OutcomeKind.COMPLETE
    assert "unsnooze_at_run_start" in gw.names()
    tool = gw.params_for("record_tool_invocation")[0]
    assert tool["p_status"] == "SUCCESS"


def test_in_filter_handler_calls_filter_with_dates(gw, settings):
    out = phases.handle_in_filter(_deps(gw, settings, "IN_MONTHLY"))
    assert out.kind == OutcomeKind.COMPLETE
    call = gw.params_for("filter_in_transactions")[0]
    assert call["p_period_start"] == "2026-05-01"
    assert call["p_period_end"] == "2026-06-01"
    assert call["p_business_id"] == "biz-1"


def test_ai_end_scan_is_stubbed_skipped(gw, settings):
    out = phases.handle_ai_end_scan_stub(_deps(gw, settings))
    assert out.kind == OutcomeKind.COMPLETE
    assert gw.params_for("record_tool_invocation")[0]["p_status"] == "SKIPPED"


def test_wiring_pending_records_skip_and_completes(gw, settings):
    out = phases.handle_wiring_pending(_deps(gw, settings))
    assert out.kind == OutcomeKind.COMPLETE
    assert gw.params_for("record_tool_invocation")[0]["p_status"] == "SKIPPED"


def test_skip_optional_yields_skip_outcome(gw, settings):
    out = phases.handle_skip_optional(_deps(gw, settings))
    assert out.kind == OutcomeKind.SKIP


def test_registry_resolves_specific_then_wildcard_then_default():
    reg = PhaseRegistry()
    assert reg.resolve("IN_MONTHLY", "IN_FILTER") is phases.handle_in_filter
    assert reg.resolve("OUT_MONTHLY", "INGESTION") is phases.handle_ingestion
    assert reg.resolve("OUT_MONTHLY", "UNKNOWN_PHASE") is phases.handle_noop_complete


# ----------------------------- outbox -------------------------------------- #
def test_consume_pending_collects_created_run_ids(gw, settings):
    gw.tables["statement_upload_events_outbox"] = [
        {"event_id": "evt-1", "status": "PENDING", "emitted_at": "t1"},
    ]
    gw.script("consume_statement_upload_completed_event",
              {"ok": True, "created_run_ids": ["run-a", "run-b"]})
    result = consume_pending(gw, settings)
    assert result["consumed"] == ["evt-1"]
    assert result["created_run_ids"] == ["run-a", "run-b"]


def test_consume_pending_records_rejection(gw, settings):
    gw.tables["statement_upload_events_outbox"] = [
        {"event_id": "evt-x", "status": "PENDING", "emitted_at": "t1"},
    ]
    gw.script("consume_statement_upload_completed_event",
              {"ok": False, "reason": "EVENT_NOT_FOUND"})
    result = consume_pending(gw, settings)
    assert result["failed"] == ["evt-x"]
    assert "record_statement_upload_event_handler_failed" in gw.names()
