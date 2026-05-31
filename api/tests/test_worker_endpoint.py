"""POST /internal/worker/tick (P0.4): secret guard + tick dispatch."""
from __future__ import annotations

import pytest
from fastapi import HTTPException

from cyprus_bookkeeping_api.config import Settings
from cyprus_bookkeeping_api.routes import worker as worker_route


def _settings(secret: str = "") -> Settings:
    return Settings(_env_file=None, worker_tick_secret=secret, supabase_service_role_key="x")


def test_disabled_without_secret():
    with pytest.raises(HTTPException) as ei:
        worker_route.worker_tick(settings=_settings(""), x_worker_tick_secret="anything")
    assert ei.value.status_code == 503


def test_rejects_wrong_secret():
    with pytest.raises(HTTPException) as ei:
        worker_route.worker_tick(settings=_settings("s3cret"), x_worker_tick_secret="wrong")
    assert ei.value.status_code == 401


def test_rejects_missing_header():
    with pytest.raises(HTTPException) as ei:
        worker_route.worker_tick(settings=_settings("s3cret"), x_worker_tick_secret=None)
    assert ei.value.status_code == 401


def test_runs_tick_on_valid_secret(monkeypatch):
    monkeypatch.setattr(worker_route, "build_service_gateway", lambda s: object())
    monkeypatch.setattr(worker_route, "build_service_storage", lambda s: object())
    monkeypatch.setattr(
        worker_route, "tick",
        lambda gw, s, **k: {
            "consumed": {"consumed": ["e1"], "failed": [], "created_run_ids": ["r1", "r2"]},
            "driven": [{"ok": True}, {"ok": True}],
            "exports": {"generated": ["x1"], "failed": []},
        },
    )
    out = worker_route.worker_tick(settings=_settings("s3cret"), x_worker_tick_secret="s3cret")
    assert out["ok"] is True
    assert out["consumed_events"] == ["e1"]
    assert out["created_run_ids"] == ["r1", "r2"]
    assert out["runs_driven"] == 2
    assert out["exports_generated"] == ["x1"]
