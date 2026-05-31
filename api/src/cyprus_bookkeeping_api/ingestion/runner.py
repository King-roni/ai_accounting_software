"""Statement-ingestion runner — parse UPLOADED statements into transactions.

For each ``UPLOADED`` statement: claim it (``start_statement_parse`` flips it to
PARSING under a row lock, so two workers never double-parse), read the bytes,
parse → record rows → normalize → dedup, which inserts the ``transactions``.
The dedup is tied to the workflow run the upload event created (resolved from
the outbox), matching the B07 design where ingestion is run-scoped.
"""
from __future__ import annotations

import logging
from typing import Any

from cyprus_bookkeeping_api.config import Settings
from cyprus_bookkeeping_api.exports.storage import StoragePort
from cyprus_bookkeeping_api.ingestion.normalize import NormalizationError, normalize
from cyprus_bookkeeping_api.orchestrator.models import first_row
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway, RpcError
from cyprus_bookkeeping_api.parsers import ParsedStatement
from cyprus_bookkeeping_api.parsers import revolut_csv

logger = logging.getLogger(__name__)

_UPLOAD_COLUMNS = (
    "id,organization_id,business_id,bank_account_id,file_id,file_format,provider,upload_status"
)
# file_format → parser callable. PDF (OCR) is R8; only CSV is wired now.
_PARSERS = {"CSV": revolut_csv.parse}


def parse_pending_statements(
    gateway: Gateway, storage: StoragePort, settings: Settings
) -> dict[str, Any]:
    """Parse every claimable UPLOADED statement. Returns per-upload outcomes."""
    pending = gateway.select(
        "statement_uploads",
        columns=_UPLOAD_COLUMNS,
        in_filters={"upload_status": ["UPLOADED"]},
        order="uploaded_at",
        limit=settings.worker_statement_batch_size,
    )

    parsed: list[dict[str, Any]] = []
    failed: list[str] = []
    skipped: list[str] = []

    for upload in pending:
        upload_id = str(upload["id"])
        file_format = upload.get("file_format")
        if file_format not in _PARSERS:
            skipped.append(upload_id)  # PDF/OCR → R8
            continue
        run_id = _resolve_run_id(gateway, upload_id)
        if run_id is None:
            skipped.append(upload_id)  # no workflow run yet (event not consumed / disabled)
            continue
        try:
            result = _ingest_one(gateway, storage, settings, upload, run_id)
            if result.get("claimed"):
                parsed.append({"statement_upload_id": upload_id, **result})
            else:
                skipped.append(upload_id)  # another worker claimed it first
        except Exception:  # noqa: BLE001 — one bad statement must not stop the batch
            logger.exception("statement %s ingestion failed", upload_id)
            failed.append(upload_id)

    if parsed or failed:
        logger.info("statements: parsed=%d failed=%d skipped=%d",
                    len(parsed), len(failed), len(skipped))
    return {"parsed": parsed, "failed": failed, "skipped": skipped}


def _resolve_run_id(gateway: Gateway, upload_id: str) -> str | None:
    events = gateway.select(
        "statement_upload_events_outbox",
        columns="statement_upload_id,created_run_ids",
        filters={"statement_upload_id": upload_id},
    )
    for event in events:
        created = event.get("created_run_ids") or []
        if created:
            return str(created[0])
    return None


def _require_ok(result: Any, what: str) -> dict[str, Any]:
    row = first_row(result) or {}
    if row.get("ok") is False:
        raise RpcError(f"{what} rejected: {row.get('reason', row)}")
    return row


def _ingest_one(
    gateway: Gateway, storage: StoragePort, settings: Settings,
    upload: dict[str, Any], run_id: str,
) -> dict[str, Any]:
    upload_id = str(upload["id"])

    started = first_row(gateway.rpc("start_statement_parse", {"p_statement_upload_id": upload_id})) or {}
    if not started.get("ok"):
        # lost the claim (another worker) or no active parser — nothing to do.
        return {"claimed": False, "reason": started.get("reason")}
    parse_run_id = started["parse_run_id"]

    try:
        data = storage.download(settings.raw_upload_bucket, upload["file_id"])
        statement = _PARSERS[upload["file_format"]](data)
        if statement.failed:
            gateway.rpc("fail_statement_parse", {
                "p_parse_run_id": parse_run_id,
                "p_error_category": statement.error_category,
                "p_error_message": (statement.error_message or "")[:2000],
            })
            return {"claimed": True, "parse_failed": True, "reason": statement.error_category}

        parsed_pairs = _record_parsed_rows(gateway, parse_run_id, statement)
        gateway.rpc("complete_statement_parse", {"p_parse_run_id": parse_run_id})

        norm_run_id = _require_ok(
            gateway.rpc("start_statement_normalization", {"p_statement_upload_id": upload_id}),
            "start_statement_normalization",
        )["normalization_run_id"]
        normalized_ids = _record_normalized(gateway, norm_run_id, parsed_pairs, settings)
        gateway.rpc("complete_statement_normalization", {"p_normalization_run_id": norm_run_id})

        dedup_run_id = _require_ok(
            gateway.rpc("start_statement_dedup", {
                "p_statement_upload_id": upload_id, "p_workflow_run_id": run_id,
            }),
            "start_statement_dedup",
        )["dedup_run_id"]
        for normalized_row_id in normalized_ids:
            gateway.rpc("classify_and_record_dedup_row", {
                "p_dedup_run_id": dedup_run_id,
                "p_normalized_row_id": normalized_row_id,
                "p_soft_window_days": settings.statement_dedup_soft_window_days,
                "p_amount_tolerance_cents": settings.statement_dedup_amount_tolerance_cents,
            })
        dedup = first_row(gateway.rpc("complete_statement_dedup", {"p_dedup_run_id": dedup_run_id})) or {}
    except Exception as exc:  # noqa: BLE001 — record the failure on the parse run, then re-raise
        gateway.rpc("fail_statement_parse", {
            "p_parse_run_id": parse_run_id,
            "p_error_category": "INTERNAL_ERROR",
            "p_error_message": str(exc)[:2000],
        })
        raise

    return {
        "claimed": True,
        "rows_parsed": len(parsed_pairs),
        "warnings": len(statement.warnings),
        "new_count": dedup.get("new_count", 0),
        "exact_duplicate_count": dedup.get("exact_duplicate_count", 0),
        "probable_duplicate_count": dedup.get("probable_duplicate_count", 0),
        "needs_review_count": dedup.get("needs_review_count", 0),
    }


def _record_parsed_rows(gateway: Gateway, parse_run_id: str, statement: ParsedStatement) -> list[tuple[str, Any]]:
    pairs: list[tuple[str, Any]] = []
    for row in statement.rows:
        recorded = first_row(gateway.rpc("record_parsed_row", {
            "p_parse_run_id": parse_run_id,
            "p_source_row_index": row.source_row_index,
            "p_provider_native": row.provider_native,
            "p_date_text": row.date_text,
            "p_amount_text": row.amount_text,
            "p_currency": row.currency or "EUR",
            "p_direction_hint": row.direction_hint,
            "p_description_text": row.description_text,
            "p_reference_text": row.reference_text,
            "p_counterparty_text": row.counterparty_text,
        })) or {}
        if recorded.get("ok") and recorded.get("parsed_row_id"):
            pairs.append((recorded["parsed_row_id"], row))
        else:
            logger.warning("record_parsed_row skipped row %s: %s", row.source_row_index, recorded.get("reason"))
    return pairs


def _record_normalized(
    gateway: Gateway, norm_run_id: str, parsed_pairs: list[tuple[str, Any]], settings: Settings
) -> list[str]:
    normalized_ids: list[str] = []
    for parsed_row_id, row in parsed_pairs:
        try:
            norm = normalize(row, default_currency=settings.statement_default_currency)
        except NormalizationError as exc:
            logger.warning("normalization skipped row %s: %s", row.source_row_index, exc)
            continue
        recorded = first_row(gateway.rpc("record_normalized_transaction", {
            "p_normalization_run_id": norm_run_id,
            "p_parsed_row_ids": [parsed_row_id],
            "p_transaction_date": norm.transaction_date,
            "p_amount": str(norm.amount),
            "p_currency": norm.currency,
            "p_direction": norm.direction,
            "p_normalized_description": norm.normalized_description,
            "p_source_row_hash": norm.source_row_hash,
            "p_transaction_fingerprint": norm.transaction_fingerprint,
            "p_counterparty_name": norm.counterparty_name,
            "p_reference": norm.reference,
        })) or {}
        if recorded.get("ok") and recorded.get("normalized_row_id"):
            normalized_ids.append(recorded["normalized_row_id"])
        else:
            logger.warning("record_normalized skipped row %s: %s", row.source_row_index, recorded.get("reason"))
    return normalized_ids
