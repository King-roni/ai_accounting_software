"""Thin service-role gateway over the Supabase client.

The orchestrator runs server-side with the service-role key (bypasses RLS) and
calls the same Block 03–13 ``SECURITY DEFINER`` RPCs the rest of the system
exposes. Every DB touch goes through :class:`SupabaseGateway` so tests can swap
in a fake and the real transport stays in one place.
"""
from __future__ import annotations

import logging
from typing import Any, Protocol

from cyprus_bookkeeping_api.config import Settings

logger = logging.getLogger(__name__)


class RpcError(RuntimeError):
    """Raised when a Supabase RPC / select fails or returns an error envelope."""


class Gateway(Protocol):
    """Structural type the engine depends on (real gateway or a test fake)."""

    def rpc(self, fn: str, params: dict[str, Any] | None = None) -> Any: ...

    def select(
        self,
        table: str,
        columns: str = "*",
        *,
        filters: dict[str, Any] | None = None,
        in_filters: dict[str, list[Any]] | None = None,
        order: str | None = None,
        limit: int | None = None,
    ) -> list[dict[str, Any]]: ...

    def update(
        self,
        table: str,
        values: dict[str, Any],
        *,
        filters: dict[str, Any],
    ) -> list[dict[str, Any]]: ...


class SupabaseGateway:
    """Concrete gateway backed by ``supabase.Client``."""

    def __init__(self, client: Any) -> None:
        self._client = client

    def rpc(self, fn: str, params: dict[str, Any] | None = None) -> Any:
        try:
            response = self._client.rpc(fn, params or {}).execute()
        except Exception as exc:  # noqa: BLE001 — normalise every transport error
            raise RpcError(f"RPC {fn} failed: {exc}") from exc
        return response.data

    def select(
        self,
        table: str,
        columns: str = "*",
        *,
        filters: dict[str, Any] | None = None,
        in_filters: dict[str, list[Any]] | None = None,
        order: str | None = None,
        limit: int | None = None,
    ) -> list[dict[str, Any]]:
        query = self._client.table(table).select(columns)
        for column, value in (filters or {}).items():
            query = query.eq(column, value)
        for column, values in (in_filters or {}).items():
            query = query.in_(column, values)
        if order is not None:
            query = query.order(order)
        if limit is not None:
            query = query.limit(limit)
        try:
            response = query.execute()
        except Exception as exc:  # noqa: BLE001
            raise RpcError(f"select {table} failed: {exc}") from exc
        return response.data or []

    def update(
        self,
        table: str,
        values: dict[str, Any],
        *,
        filters: dict[str, Any],
    ) -> list[dict[str, Any]]:
        query = self._client.table(table).update(values)
        for column, value in filters.items():
            query = query.eq(column, value)
        try:
            response = query.execute()
        except Exception as exc:  # noqa: BLE001
            raise RpcError(f"update {table} failed: {exc}") from exc
        return response.data or []


def build_service_gateway(settings: Settings) -> SupabaseGateway:
    """Build a service-role gateway. Imports supabase lazily (worker-only dep)."""
    if not settings.supabase_service_role_key:
        raise RpcError(
            "supabase_service_role_key not configured; the worker requires "
            "service-role access to drive runs."
        )
    from supabase import create_client

    client = create_client(settings.supabase_url, settings.supabase_service_role_key)
    return SupabaseGateway(client)
