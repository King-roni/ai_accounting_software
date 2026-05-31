"""R7.2 ingestion runner: claim → parse → normalize → dedup → transactions."""
from __future__ import annotations

from typing import Any

from cyprus_bookkeeping_api.ingestion.runner import parse_pending_statements

_CSV = (
    "Date,Description,Amount,Currency\n"
    "2026-06-02,Costa Coffee,-4.50,EUR\n"
    "2026-06-03,Client Payment,1200.00,EUR\n"
).encode("utf-8")


class FakeStorage:
    def __init__(self, blobs: dict[tuple[str, str], bytes] | None = None) -> None:
        self.blobs = blobs or {}
        self.downloads: list[tuple[str, str]] = []

    def upload(self, bucket: str, path: str, data: bytes, content_type: str) -> None:  # pragma: no cover
        self.blobs[(bucket, path)] = data

    def download(self, bucket: str, path: str) -> bytes:
        self.downloads.append((bucket, path))
        return self.blobs[(bucket, path)]


def _upload(**kw: Any) -> dict[str, Any]:
    row = {
        "id": "u1", "organization_id": "o1", "business_id": "b1", "bank_account_id": "ba1",
        "file_id": "o1/b1/STATEMENT/u1", "file_format": "CSV", "provider": "REVOLUT",
        "upload_status": "UPLOADED",
    }
    row.update(kw)
    return row


def _happy_path_scripts(gw) -> None:
    gw.script("start_statement_parse", {"ok": True, "parse_run_id": "pr1"})
    gw.script("record_parsed_row", {"ok": True, "parsed_row_id": "prow"})
    gw.script("complete_statement_parse", {"ok": True, "row_count": 2})
    gw.script("start_statement_normalization", {"ok": True, "normalization_run_id": "nr1"})
    gw.script("record_normalized_transaction", {"ok": True, "normalized_row_id": "nrow"})
    gw.script("complete_statement_normalization", {"ok": True})
    gw.script("start_statement_dedup", {"ok": True, "dedup_run_id": "dr1"})
    gw.script("classify_and_record_dedup_row", {"ok": True, "dedup_status": "NEW", "transaction_id": "tx"})
    gw.script("complete_statement_dedup", {
        "ok": True, "new_count": 2, "exact_duplicate_count": 0,
        "probable_duplicate_count": 0, "needs_review_count": 0,
    })


def test_full_pipeline_creates_transactions(gw, settings):
    gw.tables["statement_uploads"] = [_upload()]
    gw.tables["statement_upload_events_outbox"] = [
        {"statement_upload_id": "u1", "created_run_ids": ["run-out", "run-in"]}
    ]
    _happy_path_scripts(gw)
    storage = FakeStorage({("raw-uploads", "o1/b1/STATEMENT/u1"): _CSV})

    out = parse_pending_statements(gw, storage, settings)

    assert len(out["parsed"]) == 1
    result = out["parsed"][0]
    assert result["rows_parsed"] == 2 and result["new_count"] == 2
    assert storage.downloads == [("raw-uploads", "o1/b1/STATEMENT/u1")]
    # full B07 sequence ran
    assert gw.count("record_parsed_row") == 2
    assert gw.count("record_normalized_transaction") == 2
    assert gw.count("classify_and_record_dedup_row") == 2
    # dedup tied to the run the upload event created
    assert gw.params_for("start_statement_dedup")[0]["p_workflow_run_id"] == "run-out"


def test_pdf_upload_is_skipped_until_r8(gw, settings):
    gw.tables["statement_uploads"] = [_upload(file_format="PDF")]
    out = parse_pending_statements(gw, FakeStorage(), settings)
    assert out["skipped"] == ["u1"] and out["parsed"] == []
    assert "start_statement_parse" not in gw.names()


def test_no_workflow_run_skips(gw, settings):
    gw.tables["statement_uploads"] = [_upload()]
    gw.tables["statement_upload_events_outbox"] = [
        {"statement_upload_id": "u1", "created_run_ids": []}
    ]
    out = parse_pending_statements(gw, FakeStorage(), settings)
    assert out["skipped"] == ["u1"] and "start_statement_parse" not in gw.names()


def test_lost_claim_is_skipped(gw, settings):
    gw.tables["statement_uploads"] = [_upload()]
    gw.tables["statement_upload_events_outbox"] = [
        {"statement_upload_id": "u1", "created_run_ids": ["run-out"]}
    ]
    gw.script("start_statement_parse", {"ok": False, "reason": "UPLOAD_NOT_IN_UPLOADED_STATE"})
    out = parse_pending_statements(gw, FakeStorage({("raw-uploads", "o1/b1/STATEMENT/u1"): _CSV}), settings)
    assert out["skipped"] == ["u1"] and out["parsed"] == []


def test_empty_file_marks_parse_failed(gw, settings):
    gw.tables["statement_uploads"] = [_upload()]
    gw.tables["statement_upload_events_outbox"] = [
        {"statement_upload_id": "u1", "created_run_ids": ["run-out"]}
    ]
    gw.script("start_statement_parse", {"ok": True, "parse_run_id": "pr1"})
    storage = FakeStorage({("raw-uploads", "o1/b1/STATEMENT/u1"): b"   "})

    out = parse_pending_statements(gw, storage, settings)

    assert out["parsed"][0]["parse_failed"] is True
    failure = gw.params_for("fail_statement_parse")[0]
    assert failure["p_error_category"] == "EMPTY_FILE"
    assert "start_statement_normalization" not in gw.names()
