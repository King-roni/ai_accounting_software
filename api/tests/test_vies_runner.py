"""R7.6 VIES runner: validate the batch, record verdicts, skip outages."""
from __future__ import annotations

from cyprus_bookkeeping_api.vies.client import ViesResult, ViesUnavailable
from cyprus_bookkeeping_api.vies.runner import verify_pending_vies


class FakeVies:
    def __init__(self, mapping: dict) -> None:
        self.mapping = mapping
        self.calls: list[tuple[str, str]] = []

    def check(self, country: str, vat_number: str) -> ViesResult:
        self.calls.append((country, vat_number))
        value = self.mapping[(country, vat_number)]
        if isinstance(value, Exception):
            raise value
        return value


def test_records_valid_and_invalid(gw, settings):
    gw.script("clients_needing_vies_check", lambda _p: [
        {"country": "DE", "vat_number": "DE811569869"},
        {"country": "CY", "vat_number": "CY10259033X"},
    ])
    vies = FakeVies({
        ("DE", "DE811569869"): ViesResult("DE", "DE811569869", True, "ACME", None, "req1"),
        ("CY", "CY10259033X"): ViesResult("CY", "CY10259033X", False, None, None, None),
    })

    out = verify_pending_vies(gw, settings, vies=vies)

    assert len(out["checked"]) == 2 and out["unavailable"] == []
    assert gw.count("record_vies_check") == 2
    first = gw.params_for("record_vies_check")[0]
    assert first["p_country"] == "DE" and first["p_valid"] is True and first["p_registered_name"] == "ACME"


def test_unavailable_is_skipped_not_cached(gw, settings):
    gw.script("clients_needing_vies_check", lambda _p: [{"country": "DE", "vat_number": "DE811569869"}])
    vies = FakeVies({("DE", "DE811569869"): ViesUnavailable("down")})

    out = verify_pending_vies(gw, settings, vies=vies)

    assert out["checked"] == [] and out["unavailable"] == ["DE:DE811569869"]
    assert "record_vies_check" not in gw.names()


def test_no_pending_is_noop(gw, settings):
    gw.script("clients_needing_vies_check", lambda _p: [])
    out = verify_pending_vies(gw, settings, vies=FakeVies({}))
    assert out == {"checked": [], "unavailable": []}
