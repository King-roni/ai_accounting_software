"""Export-generation runner — the work the worker does for PENDING exports.

For each PENDING export: claim it (PENDING -> RUNNING, atomic), generate the
artifact, upload to the bucket at ``{org}/{business}/{export_id}.{ext}``, then
mark it COMPLETED (or FAILED on any error). Safe to run as N replicas — the
claim is a status-guarded UPDATE, so two workers never generate the same row.
"""
from __future__ import annotations

import hashlib
import logging
from typing import Any

from cyprus_bookkeeping_api.config import Settings
from cyprus_bookkeeping_api.exports.generators import GenContext, generate
from cyprus_bookkeeping_api.exports.storage import StoragePort
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway

logger = logging.getLogger(__name__)

_EXPORT_COLUMNS = (
    "id,organization_id,business_id,export_kind,format,period_start,period_end,status"
)
_CONTEXT = {"generated_by": "export_worker"}


def generate_pending_exports(
    gateway: Gateway, storage: StoragePort, settings: Settings
) -> dict[str, Any]:
    """Generate every claimable PENDING export. Returns per-export outcomes."""
    pending = gateway.select(
        "exports",
        columns=_EXPORT_COLUMNS,
        in_filters={"status": ["PENDING"]},
        order="requested_at",
        limit=settings.worker_export_batch_size,
    )

    generated: list[str] = []
    failed: list[str] = []
    skipped: list[str] = []

    for row in pending:
        export_id = str(row["id"])
        claimed = gateway.update(
            "exports", {"status": "RUNNING"}, filters={"id": export_id, "status": "PENDING"}
        )
        if not claimed:
            skipped.append(export_id)  # another worker took it
            continue
        try:
            _generate_one(gateway, storage, settings, row, export_id)
            generated.append(export_id)
        except Exception as exc:  # noqa: BLE001 — one bad export must not stop the batch
            logger.exception("export %s generation failed", export_id)
            _mark_failed(gateway, export_id, str(exc))
            failed.append(export_id)

    if generated or failed:
        logger.info(
            "exports: generated=%d failed=%d skipped=%d",
            len(generated), len(failed), len(skipped),
        )
    return {"generated": generated, "failed": failed, "skipped": skipped}


def _generate_one(
    gateway: Gateway,
    storage: StoragePort,
    settings: Settings,
    row: dict[str, Any],
    export_id: str,
) -> None:
    ctx = GenContext(
        gateway=gateway,
        export_id=export_id,
        business_id=str(row["business_id"]),
        organization_id=str(row["organization_id"]),
        export_kind=row["export_kind"],
        fmt=row["format"],
        period_start=row.get("period_start"),
        period_end=row.get("period_end"),
    )
    artifact = generate(ctx)
    path = f"{row['organization_id']}/{row['business_id']}/{export_id}.{artifact.extension}"
    storage.upload(settings.export_bucket, path, artifact.data, artifact.content_type)

    file_hash = hashlib.sha256(artifact.data).hexdigest()
    byte_size = len(artifact.data)

    if ctx.export_kind == "accountant_export_pack":
        gateway.rpc(
            "mark_accountant_pack_completed",
            {
                "p_export_id": export_id,
                "p_bundle_hash_anchor": file_hash,
                "p_component_count": artifact.component_count,
                "p_storage_object_id": path,
                "p_byte_size": byte_size,
                "p_signed_url_expires_at": None,
                "p_context": _CONTEXT,
            },
        )
    else:
        gateway.rpc(
            "mark_export_completed",
            {
                "p_export_id": export_id,
                "p_storage_object_id": path,
                "p_byte_size": byte_size,
                "p_file_hash": file_hash,
                "p_source_data_hash": None,
                "p_signed_url_expires_at": None,
                "p_context": _CONTEXT,
            },
        )


def _mark_failed(gateway: Gateway, export_id: str, message: str) -> None:
    try:
        gateway.rpc(
            "mark_export_failed",
            {"p_export_id": export_id, "p_failure_message": message[:2000], "p_context": {}},
        )
    except Exception:  # noqa: BLE001
        logger.exception("could not mark export %s failed", export_id)
