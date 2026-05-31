"""R7.1 runner: claim → generate → upload → mark, plus the failure path."""
from __future__ import annotations

from typing import Any

from cyprus_bookkeeping_api.exports.runner import generate_pending_exports


class FakeStorage:
    def __init__(self) -> None:
        self.uploads: list[tuple[str, str, bytes, str]] = []

    def upload(self, bucket: str, path: str, data: bytes, content_type: str) -> None:
        self.uploads.append((bucket, path, data, content_type))


def _pending(**overrides: Any) -> dict[str, Any]:
    row = {
        "id": "e1", "organization_id": "o1", "business_id": "b1",
        "export_kind": "transaction_report", "format": "CSV",
        "period_start": "2026-05-01", "period_end": "2026-05-31", "status": "PENDING",
    }
    row.update(overrides)
    return row


def test_generates_uploads_and_marks_completed(gw, settings):
    gw.tables["exports"] = [_pending()]
    gw.rpc_handlers["_compose_transactions_json"] = lambda _p: [{"id": "t1", "direction": "OUT"}]
    storage = FakeStorage()

    out = generate_pending_exports(gw, storage, settings)

    assert out["generated"] == ["e1"] and out["failed"] == []
    assert len(storage.uploads) == 1
    bucket, path, data, content_type = storage.uploads[0]
    assert bucket == "export-artifacts" and path == "o1/b1/e1.csv"
    assert content_type.startswith("text/csv")
    # claim flipped PENDING -> RUNNING
    assert gw.tables["exports"][0]["status"] == "RUNNING"
    # completion recorded with the uploaded object + a real sha256
    params = gw.params_for("mark_export_completed")[0]
    assert params["p_storage_object_id"] == "o1/b1/e1.csv"
    assert params["p_byte_size"] == len(data)
    assert len(params["p_file_hash"]) == 64


def test_pending_only_is_selected(gw, settings):
    gw.tables["exports"] = [_pending(status="RUNNING")]
    storage = FakeStorage()
    out = generate_pending_exports(gw, storage, settings)
    assert out["generated"] == [] and storage.uploads == []


def test_failure_marks_failed_and_skips_upload(gw, settings):
    gw.tables["exports"] = [_pending(export_kind="no_such_report")]
    storage = FakeStorage()

    out = generate_pending_exports(gw, storage, settings)

    assert out["failed"] == ["e1"] and out["generated"] == []
    assert storage.uploads == []
    assert "mark_export_failed" in gw.names()


def test_accountant_pack_uses_pack_completion(gw, settings):
    gw.tables["exports"] = [_pending(export_kind="accountant_export_pack", format="ZIP")]
    for fn in (
        "_compose_transactions_json", "_compose_matches_json",
        "_compose_supplier_overview_json", "_compose_evidence_index_json",
        "_compose_vat_summary_json", "_compose_ledger_entries_json",
    ):
        gw.rpc_handlers[fn] = lambda _p: []
    storage = FakeStorage()

    out = generate_pending_exports(gw, storage, settings)

    assert out["generated"] == ["e1"]
    assert storage.uploads[0][1] == "o1/b1/e1.zip"
    assert "mark_accountant_pack_completed" in gw.names()
    assert "mark_export_completed" not in gw.names()
    assert gw.params_for("mark_accountant_pack_completed")[0]["p_component_count"] >= 1
