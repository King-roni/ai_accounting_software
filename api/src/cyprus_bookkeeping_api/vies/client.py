"""Client for the EU VIES VAT-number-check REST service.

POSTs ``{countryCode, vatNumber}`` to the public endpoint and returns a clean
verdict. A definite valid/invalid answer → :class:`ViesResult`; anything else
(member-state service down, HTTP error, timeout, no verdict) → :class:`ViesUnavailable`
so the caller can retry later instead of caching a wrong "invalid".
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Protocol

import httpx

from cyprus_bookkeeping_api.config import Settings

logger = logging.getLogger(__name__)


class ViesUnavailable(RuntimeError):
    """VIES gave no definitive verdict (service down / error / timeout)."""


@dataclass(frozen=True)
class ViesResult:
    country: str
    vat_number: str  # as stored (may include the country prefix)
    valid: bool
    name: str | None
    address: str | None
    request_identifier: str | None


class ViesPort(Protocol):
    def check(self, country: str, vat_number: str) -> ViesResult: ...


def _national_number(country: str, vat_number: str) -> str:
    """VIES wants the number WITHOUT the country prefix; strip it if present."""
    vn = vat_number.strip().replace(" ", "")
    cc = country.strip().upper()
    if vn.upper().startswith(cc):
        vn = vn[len(cc):]
    return vn


def _clean(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return None if text in ("", "---") else text


class ViesClient:
    """Concrete VIES client over the public REST endpoint."""

    def __init__(self, settings: Settings) -> None:
        self._endpoint = settings.vies_endpoint
        self._timeout = settings.vies_timeout_seconds

    def check(self, country: str, vat_number: str) -> ViesResult:
        cc = country.strip().upper()
        national = _national_number(cc, vat_number)
        try:
            resp = httpx.post(
                self._endpoint,
                json={"countryCode": cc, "vatNumber": national},
                headers={"content-type": "application/json"},
                timeout=self._timeout,
            )
        except httpx.HTTPError as exc:
            raise ViesUnavailable(f"VIES request failed for {cc}{national}: {exc}") from exc
        if resp.status_code != 200:
            raise ViesUnavailable(f"VIES HTTP {resp.status_code} for {cc}{national}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise ViesUnavailable(f"VIES non-JSON response for {cc}{national}") from exc
        valid = data.get("valid")
        if not isinstance(valid, bool):
            raise ViesUnavailable(
                f"VIES gave no verdict for {cc}{national}: {data.get('errorWrappers') or 'unknown'}"
            )
        return ViesResult(
            country=cc,
            vat_number=vat_number,
            valid=valid,
            name=_clean(data.get("name")),
            address=_clean(data.get("address")),
            request_identifier=_clean(data.get("requestIdentifier")),
        )


def build_vies_client(settings: Settings) -> ViesClient:
    return ViesClient(settings)
