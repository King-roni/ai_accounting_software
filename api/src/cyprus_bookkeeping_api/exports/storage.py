"""Object-storage port for the export worker.

The worker uploads generated artifacts to the private ``export-artifacts``
bucket with the service role (the only writer — INSERT on storage.objects is
default-deny for authenticated). A :class:`StoragePort` keeps the transport
swappable so the runner is testable without a live bucket.
"""
from __future__ import annotations

import logging
from typing import Protocol

from cyprus_bookkeeping_api.config import Settings

logger = logging.getLogger(__name__)


class StorageError(RuntimeError):
    """Raised when an object upload fails."""


class StoragePort(Protocol):
    def upload(self, bucket: str, path: str, data: bytes, content_type: str) -> None: ...


class SupabaseStorage:
    """Concrete uploader backed by ``supabase.Client`` storage."""

    def __init__(self, client: object) -> None:
        self._client = client

    def upload(self, bucket: str, path: str, data: bytes, content_type: str) -> None:
        try:
            self._client.storage.from_(bucket).upload(  # type: ignore[attr-defined]
                path,
                data,
                {"content-type": content_type, "upsert": "true"},
            )
        except Exception as exc:  # noqa: BLE001 — normalise transport errors
            raise StorageError(f"upload to {bucket}/{path} failed: {exc}") from exc


def build_service_storage(settings: Settings) -> SupabaseStorage:
    """Build a service-role storage uploader. Imports supabase lazily."""
    if not settings.supabase_service_role_key:
        raise StorageError(
            "supabase_service_role_key not configured; the export worker requires "
            "service-role access to upload artifacts."
        )
    from supabase import create_client

    client = create_client(settings.supabase_url, settings.supabase_service_role_key)
    return SupabaseStorage(client)
