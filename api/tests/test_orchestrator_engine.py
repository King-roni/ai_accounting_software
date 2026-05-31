"""drive_run loop: happy path, holds, waiting/terminal short-circuits, actor."""
from __future__ import annotations

import pytest

from cyprus_bookkeeping_api.orchestrator.actors import ActorResolutionError
from cyprus_bookkeeping_api.orchestrator.engine import (
    OrchestratorError,
    drive_run,
    safe_drive_run,
)
from cyprus_bookkeeping_api.orchestrator.gates import GateEngine
from cyprus_bookkeeping_api.orchestrator.models import GateDecision


def _phase_id(params):
    return {"id": f"ps-{params['p_phase_name']}", "phase_name": params["p_phase_name"]}


def test_drive_run_walks_phases_to_awaiting_approval(gw, settings, make_run):
    gw.tables["workflow_runs"] = [make_run()]
    gw.script("pick_next_phase", ["INGESTION", "OUT_FILTER", "FINALIZATION"])
    gw.script("enter_phase", _phase_id)

    result = drive_run(gw, settings, make_run()["id"])

    assert result["ok"] is True
    assert result["status"] == "AWAITING_APPROVAL"
    assert result["phases_advanced"] == 2  # INGESTION + OUT_FILTER; FINALIZATION stops
    # CREATED→RUNNING start, then RUNNING→AWAITING_APPROVAL.
    targets = [p["p_target_state"] for p in gw.params_for("transition_run")]
    assert targets == ["RUNNING", "AWAITING_APPROVAL"]
    assert gw.count("enter_phase") == 2
    assert gw.count("complete_phase") == 2
    # FINALIZATION must NOT be entered — it is the user-approved lock sequence.
    entered = [p["p_phase_name"] for p in gw.params_for("enter_phase")]
    assert "FINALIZATION" not in entered


def test_drive_run_backfills_started_by_when_missing(gw, settings, make_run):
    # Event/system runs are created without started_by; the start transition needs
    # it (wfr_started_state_chk). Engine must backfill it to the resolved actor.
    run = make_run(started_by=None)
    run["principal_snapshot"] = {"actor_user_id": "event-uploader-id"}
    gw.tables["workflow_runs"] = [run]
    gw.script("pick_next_phase", ["FINALIZATION"])  # immediately await approval

    drive_run(gw, settings, run["id"])

    updates = gw.params_for("update:workflow_runs")
    assert updates and updates[0]["values"] == {"started_by": "event-uploader-id"}


def test_drive_run_skips_backfill_when_started_by_present(gw, settings, make_run):
    gw.tables["workflow_runs"] = [make_run()]  # started_by already set
    gw.script("pick_next_phase", ["FINALIZATION"])
    drive_run(gw, settings, make_run()["id"])
    assert gw.params_for("update:workflow_runs") == []


def test_drive_run_holds_on_blocking_entry_gate(gw, settings, make_run):
    gw.tables["workflow_runs"] = [make_run()]
    gw.script("pick_next_phase", ["INGESTION"])
    gw.script("enter_phase", _phase_id)
    gw.script("list_phase_gates", lambda p: (
        [{"gate_name": "demo.block_v1"}] if p["p_kind"] == "ENTRY" else []
    ))

    def _block(_gw, _ctx, _psid):
        return GateDecision.HOLD, "needs human"

    gates = GateEngine(evaluators={"demo.block_v1": _block})
    result = drive_run(gw, settings, make_run()["id"], gate_engine=gates)

    assert result["status"] == "REVIEW_HOLD"
    assert result["stopped"].startswith("ENTRY_GATE_HOLD")
    assert gw.count("hold_phase") == 1
    targets = [p["p_target_state"] for p in gw.params_for("transition_run")]
    assert targets == ["RUNNING", "REVIEW_HOLD"]


def test_drive_run_short_circuits_terminal_and_waiting(gw, settings, make_run):
    gw.tables["workflow_runs"] = [make_run(status="FINALIZED")]
    assert drive_run(gw, settings, make_run()["id"])["stopped"] == "TERMINAL"
    assert gw.count("transition_run") == 0

    gw.tables["workflow_runs"] = [make_run(status="REVIEW_HOLD")]
    assert drive_run(gw, settings, make_run()["id"])["stopped"] == "WAITING"
    assert gw.count("transition_run") == 0


def test_drive_run_missing_run(gw, settings):
    assert drive_run(gw, settings, "no-such")["reason"] == "RUN_NOT_FOUND"


def test_drive_run_requires_actor(gw, settings, make_run):
    # No started_by AND no principal actor; clear the configured fallback too.
    settings.worker_system_actor_user_id = ""
    gw.tables["workflow_runs"] = [make_run(started_by=None)]
    with pytest.raises(ActorResolutionError):
        drive_run(gw, settings, make_run()["id"])


def test_safe_drive_run_swallows_errors(gw, settings, make_run):
    gw.tables["workflow_runs"] = [make_run()]
    gw.script("pick_next_phase", lambda _p: (_ for _ in ()).throw(RuntimeError("boom")))
    out = safe_drive_run(gw, settings, make_run()["id"])
    assert out["ok"] is False
    assert out["reason"] in {"DRIVE_FAILED", "CRASH"}


def test_drive_run_raises_on_illegal_transition(gw, settings, make_run):
    gw.tables["workflow_runs"] = [make_run()]
    gw.script("transition_run", {"ok": False, "reason": "ILLEGAL_TRANSITION",
                                 "message": "nope"})
    with pytest.raises(OrchestratorError):
        drive_run(gw, settings, make_run()["id"])
