"""B05·P01 secure-HTTP tests.

Coverage:
  * Plaintext (http://) URLs raise PlaintextBlockedError.
  * Unpinned hosts pass through (no live-cert handshake).
  * Pinned host with a mismatching live SPKI raises PinMismatchError.
  * Pinned host with a matching live SPKI succeeds and caches the verdict.
  * Startup self-check fails fast on bad bucket state.
  * Startup self-check rejects placeholder pins in production env only.
"""

from __future__ import annotations

import hashlib
from typing import Any

import pytest

from cyprus_bookkeeping_api.secure_http import (
    BaselineCheckResult,
    PinMismatchError,
    PinSet,
    PlaintextBlockedError,
    SecureClient,
    spki_fingerprint_from_der,
    verify_security_baseline,
)


# --- minimal fake DER cert generator -------------------------------------
# The pinning module reads SPKI via cryptography.x509. For unit tests we
# generate a real self-signed cert + key in-process so SPKI extraction
# produces a deterministic, comparable fingerprint.

def _generate_test_cert_der() -> tuple[bytes, str]:
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    from datetime import datetime, timedelta, timezone

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test.local")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(1)
        .not_valid_before(now - timedelta(minutes=1))
        .not_valid_after(now + timedelta(hours=1))
        .sign(key, hashes.SHA256())
    )
    der = cert.public_bytes(Encoding.DER)
    spki = cert.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    return der, hashlib.sha256(spki).hexdigest()


class _StubClient:
    """Minimal stand-in for httpx.Client.request used by SecureClient.

    SecureClient only calls .request and .close. We record the calls so the
    test can assert the secure path reached the inner client (pin/scheme
    checks passed) without doing any real network I/O.
    """

    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []
        self.closed = False

    def request(self, method: str, url: str, **kwargs: Any):
        self.calls.append((method, url))
        return f"OK {method} {url}"

    def close(self) -> None:
        self.closed = True


def _build_client(*, pins=None) -> tuple[SecureClient, _StubClient]:
    inner = _StubClient()
    client = SecureClient(
        pins=pins if pins is not None else {},
        httpx_client=inner,  # type: ignore[arg-type]
    )
    return client, inner


# ---- plaintext rejection -------------------------------------------------

def test_get_blocks_plaintext():
    client, _inner = _build_client()
    with pytest.raises(PlaintextBlockedError):
        client.get("http://example.com/")


def test_post_blocks_plaintext():
    client, _inner = _build_client()
    with pytest.raises(PlaintextBlockedError):
        client.post("http://api.anthropic.com/v1/messages")


# ---- unpinned host pass-through ------------------------------------------

def test_unpinned_host_passes_through(monkeypatch: pytest.MonkeyPatch):
    client, inner = _build_client(pins={})
    # _fetch_live_spki would only run if a pin is configured, but assert
    # it's not called by replacing it with something that would fail loudly.
    monkeypatch.setattr(
        client, "_fetch_live_spki",
        lambda *a, **k: pytest.fail("should not attempt SPKI fetch for unpinned host"),
    )
    result = client.get("https://example.com/")
    assert inner.calls == [("GET", "https://example.com/")]
    assert result == "OK GET https://example.com/"


# ---- pin mismatch --------------------------------------------------------

def test_pin_mismatch_raises(monkeypatch: pytest.MonkeyPatch):
    _der, actual_fp = _generate_test_cert_der()
    pins = {"api.anthropic.com": PinSet.from_iterable("api.anthropic.com", ["deadbeef" * 8])}
    client, _inner = _build_client(pins=pins)
    monkeypatch.setattr(client, "_fetch_live_spki", lambda *_a, **_k: actual_fp)
    with pytest.raises(PinMismatchError) as exc_info:
        client.get("https://api.anthropic.com/v1/messages")
    assert "SPKI pin mismatch" in str(exc_info.value)
    assert actual_fp in str(exc_info.value)


# ---- pin match ----------------------------------------------------------

def test_pin_match_succeeds_and_caches(monkeypatch: pytest.MonkeyPatch):
    _der, fp = _generate_test_cert_der()
    pins = {"api.anthropic.com": PinSet.from_iterable("api.anthropic.com", [fp])}
    client, inner = _build_client(pins=pins)

    fetch_count = 0

    def _spy_fetch(host: str, port: int) -> str:
        nonlocal fetch_count
        fetch_count += 1
        return fp

    monkeypatch.setattr(client, "_fetch_live_spki", _spy_fetch)
    client.get("https://api.anthropic.com/v1/messages")
    client.get("https://api.anthropic.com/v1/messages")  # cached on 2nd call
    assert fetch_count == 1
    assert len(inner.calls) == 2


# ---- suffix-pin coverage -------------------------------------------------

def test_suffix_pin_covers_subdomain(monkeypatch: pytest.MonkeyPatch):
    _der, fp = _generate_test_cert_der()
    pins = {"googleapis.com": PinSet.from_iterable("googleapis.com", [fp])}
    client, _inner = _build_client(pins=pins)
    monkeypatch.setattr(client, "_fetch_live_spki", lambda *_a, **_k: fp)
    client.get("https://oauth2.googleapis.com/token")  # should resolve to the suffix pin


# ---- SPKI helper round-trip ---------------------------------------------

def test_spki_fingerprint_extraction_roundtrip():
    der, expected = _generate_test_cert_der()
    assert spki_fingerprint_from_der(der) == expected
    assert len(expected) == 64  # hex SHA-256


# ---- startup self-check -------------------------------------------------

def test_startup_baseline_ok():
    db = {"all_ok": True, "buckets": [{"id": "raw-uploads", "is_private": True}]}
    result = verify_security_baseline(
        db_status_fn=lambda: db,
        pins={},
        environment="development",
    )
    assert isinstance(result, BaselineCheckResult)
    assert result.ok is True


def test_startup_baseline_fails_on_bad_bucket():
    db = {"all_ok": False, "buckets": [{"id": "raw-uploads", "is_private": False}]}
    result = verify_security_baseline(
        db_status_fn=lambda: db,
        pins={},
        environment="development",
    )
    assert result.ok is False


def test_startup_baseline_rejects_placeholders_in_production():
    pins = {
        "api.anthropic.com": PinSet.from_iterable(
            "api.anthropic.com", ["PLACEHOLDER:not-real"]
        )
    }
    result = verify_security_baseline(
        db_status_fn=lambda: {"all_ok": True, "buckets": []},
        pins=pins,
        environment="production",
    )
    assert result.ok is False


def test_startup_baseline_allows_placeholders_in_dev():
    pins = {
        "api.anthropic.com": PinSet.from_iterable(
            "api.anthropic.com", ["PLACEHOLDER:not-real"]
        )
    }
    result = verify_security_baseline(
        db_status_fn=lambda: {"all_ok": True, "buckets": []},
        pins=pins,
        environment="development",
    )
    assert result.ok is True
