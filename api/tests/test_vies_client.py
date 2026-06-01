"""R7.6 VIES client: parsing valid/invalid + treating non-verdicts as unavailable."""
from __future__ import annotations

import httpx
import pytest

from cyprus_bookkeeping_api.config import Settings
from cyprus_bookkeeping_api.vies import client as vies_client
from cyprus_bookkeeping_api.vies.client import ViesClient, ViesUnavailable


class _Resp:
    def __init__(self, status_code: int, payload: object) -> None:
        self.status_code = status_code
        self._payload = payload

    def json(self) -> object:
        if isinstance(self._payload, Exception):
            raise self._payload
        return self._payload


def _settings() -> Settings:
    return Settings(_env_file=None, vies_endpoint="https://vies.test/check", vies_timeout_seconds=5)


def _patch(monkeypatch, result, capture: dict | None = None) -> None:
    def fake_post(url, json=None, headers=None, timeout=None):  # noqa: A002
        if capture is not None:
            capture.update({"url": url, "json": json})
        if isinstance(result, Exception):
            raise result
        return result

    monkeypatch.setattr(vies_client.httpx, "post", fake_post)


def test_valid_true_strips_country_prefix(monkeypatch):
    cap: dict = {}
    _patch(monkeypatch, _Resp(200, {"valid": True, "name": "ACME GmbH", "address": "Berlin",
                                    "requestIdentifier": "abc"}), cap)
    r = ViesClient(_settings()).check("DE", "DE811569869")
    assert r.valid is True and r.name == "ACME GmbH" and r.request_identifier == "abc"
    assert r.vat_number == "DE811569869"  # stored as-is
    assert cap["json"] == {"countryCode": "DE", "vatNumber": "811569869"}  # prefix stripped for VIES


def test_valid_false_cleans_dash_placeholders(monkeypatch):
    _patch(monkeypatch, _Resp(200, {"valid": False, "name": "---", "address": "---"}))
    r = ViesClient(_settings()).check("CY", "CY10259033X")
    assert r.valid is False and r.name is None and r.address is None


def test_no_verdict_is_unavailable(monkeypatch):
    _patch(monkeypatch, _Resp(200, {"actionSucceed": False, "errorWrappers": [{"error": "MS_UNAVAILABLE"}]}))
    with pytest.raises(ViesUnavailable):
        ViesClient(_settings()).check("DE", "811569869")


def test_non_200_is_unavailable(monkeypatch):
    _patch(monkeypatch, _Resp(503, {}))
    with pytest.raises(ViesUnavailable):
        ViesClient(_settings()).check("DE", "811569869")


def test_transport_error_is_unavailable(monkeypatch):
    _patch(monkeypatch, httpx.ConnectError("boom"))
    with pytest.raises(ViesUnavailable):
        ViesClient(_settings()).check("DE", "811569869")
