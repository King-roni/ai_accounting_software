"""Shared fakes + fixtures for orchestrator tests (mock-first / London school)."""
from __future__ import annotations

from typing import Any

import pytest

from cyprus_bookkeeping_api.config import Settings

# Default RPC return values for calls a test doesn't explicitly script.
_RPC_DEFAULTS: dict[str, Any] = {
    "transition_run": {"ok": True},
    "list_phase_gates": [],
    "record_gate_decision": {"decision": "ADVANCE"},
    "record_gate_threw": {},
    "complete_phase": {},
    "hold_phase": {},
    "record_tool_invocation": {},
    "unsnooze_at_run_start": {"ok": True},
}


class FakeGateway:
    """In-memory stand-in for :class:`SupabaseGateway`.

    * ``rpc`` records every call and returns a scripted value: a queue (list,
      popped left-to-right), a callable(params)->value, or a default.
    * ``select`` serves rows from ``tables`` applying id / status filters.
    """

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.rpc_handlers: dict[str, Any] = {}
        self.tables: dict[str, list[dict[str, Any]]] = {}

    def script(self, fn: str, value: Any) -> "FakeGateway":
        self.rpc_handlers[fn] = value
        return self

    def rpc(self, fn: str, params: dict[str, Any] | None = None) -> Any:
        params = params or {}
        self.calls.append((fn, params))
        handler = self.rpc_handlers.get(fn)
        if handler is None:
            return _RPC_DEFAULTS.get(fn)
        if callable(handler):
            return handler(params)
        if isinstance(handler, list):
            return handler.pop(0) if handler else None
        return handler

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
        self.calls.append((f"select:{table}", {"filters": filters, "in": in_filters}))
        rows = list(self.tables.get(table, []))
        if filters:
            for col, val in filters.items():
                rows = [r for r in rows if str(r.get(col)) == str(val)]
        if in_filters:
            for col, vals in in_filters.items():
                rows = [r for r in rows if r.get(col) in vals]
        return rows[:limit] if limit else rows

    def update(
        self,
        table: str,
        values: dict[str, Any],
        *,
        filters: dict[str, Any],
    ) -> list[dict[str, Any]]:
        self.calls.append((f"update:{table}", {"values": values, "filters": filters}))
        updated = []
        for row in self.tables.get(table, []):
            if all(str(row.get(c)) == str(v) for c, v in filters.items()):
                row.update(values)
                updated.append(row)
        return updated

    # -- assertions helpers --
    def names(self) -> list[str]:
        return [fn for fn, _ in self.calls]

    def params_for(self, fn: str) -> list[dict[str, Any]]:
        return [p for f, p in self.calls if f == fn]

    def count(self, fn: str) -> int:
        return self.names().count(fn)


@pytest.fixture
def gw() -> FakeGateway:
    return FakeGateway()


@pytest.fixture
def settings() -> Settings:
    # _env_file=None → never read api/.env during tests.
    return Settings(
        _env_file=None,
        worker_system_actor_user_id="00000000-0000-0000-0000-000000000099",
        worker_max_phase_iterations=30,
        worker_batch_size=10,
    )


@pytest.fixture
def make_run():
    def _make(
        *,
        run_id: str = "11111111-1111-4111-8111-111111111111",
        workflow_type: str = "OUT_MONTHLY",
        status: str = "CREATED",
        started_by: str | None = "019e751a-0eda-7c6e-9c79-7e2c4ea9bff7",
    ) -> dict[str, Any]:
        return {
            "id": run_id,
            "organization_id": "0e000000-0000-4000-8000-0000000000a1",
            "business_id": "0e000000-0000-4000-8000-0000000000b1",
            "workflow_type": workflow_type,
            "status": status,
            "period_start": "2026-05-01T00:00:00+00:00",
            "period_end": "2026-06-01T00:00:00+00:00",
            "started_by": started_by,
            "principal_snapshot": {},
            "trigger_kind": "MANUAL",
            "trigger_event_id": None,
        }

    return _make
