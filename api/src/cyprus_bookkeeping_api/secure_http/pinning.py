"""SPKI pin map + fingerprint extraction.

A pin is the SHA-256 of the certificate's SubjectPublicKeyInfo (RFC 7469 §2.4),
NOT the cert itself. This survives cert rotation as long as the key is the
same, and survives chain shuffling (intermediate CA change) as long as the
leaf key is the same. Pin the LEAF (not the CA) for hosts where we can.

The values below are PLACEHOLDERS in `PLACEHOLDER:` prefix form — production
deployment must replace them with the actual fingerprints captured from each
service via the procedure in the cert-pinning sub-doc. The PlaceholderPinError
makes that a fail-fast condition rather than a silent no-op.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Iterable, Mapping

from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


class PinMismatchError(RuntimeError):
    """The live SPKI fingerprint isn't in the configured pin set for the host."""


class PlaintextBlockedError(RuntimeError):
    """Caller attempted an http:// request; only https:// is permitted."""


class PlaceholderPinError(RuntimeError):
    """A pinned host still has a placeholder pin — refuse to dial."""


def spki_fingerprint_from_der(cert_der: bytes) -> str:
    """SHA-256 hex of the cert's SubjectPublicKeyInfo (lowercase, no separators).

    Stable across cert reissuance for the same key. Produces a 64-char hex.
    """
    cert = x509.load_der_x509_certificate(cert_der)
    spki = cert.public_key().public_bytes(
        Encoding.DER, PublicFormat.SubjectPublicKeyInfo
    )
    return hashlib.sha256(spki).hexdigest()


@dataclass(frozen=True)
class PinSet:
    """The set of allowed SPKI hex fingerprints for a single host."""

    host: str
    fingerprints: frozenset[str] = field(default_factory=frozenset)

    @classmethod
    def from_iterable(cls, host: str, items: Iterable[str]) -> "PinSet":
        return cls(host=host, fingerprints=frozenset(s.lower() for s in items))

    def matches(self, candidate_hex: str) -> bool:
        return candidate_hex.lower() in self.fingerprints

    @property
    def has_placeholder(self) -> bool:
        return any(fp.startswith("placeholder:") for fp in self.fingerprints)


# Pin map: host → PinSet.
# Production deployment must replace `PLACEHOLDER:*` with the actual SPKI
# fingerprints captured via the cert-pinning sub-doc procedure.
DEFAULT_PIN_MAP: Mapping[str, PinSet] = {
    "api.anthropic.com": PinSet.from_iterable(
        "api.anthropic.com",
        # Anthropic leaf SPKI fingerprints (primary + backup). Replace before prod.
        ["PLACEHOLDER:anthropic-leaf-primary", "PLACEHOLDER:anthropic-leaf-backup"],
    ),
    "googleapis.com": PinSet.from_iterable(
        "googleapis.com",
        # Google leaf SPKI fingerprints. Replace before prod.
        ["PLACEHOLDER:google-leaf-primary", "PLACEHOLDER:google-leaf-backup"],
    ),
    "freetsa.org": PinSet.from_iterable(
        "freetsa.org",
        # RFC 3161 timestamping service used by B05·P03.
        ["PLACEHOLDER:freetsa-leaf-primary", "PLACEHOLDER:freetsa-leaf-backup"],
    ),
}


def find_pin_set(host: str, pins: Mapping[str, PinSet]) -> PinSet | None:
    """Return the PinSet for the host (or for its parent zone if pinned that way).

    Looks for exact match first, then suffix match (so pinning ``googleapis.com``
    covers ``oauth2.googleapis.com``, ``gmail.googleapis.com``, etc.). Use
    suffix pins sparingly — they're broader by design.
    """
    if host in pins:
        return pins[host]
    for pinned_host, pin_set in pins.items():
        if host.endswith("." + pinned_host):
            return pin_set
    return None


def assert_no_placeholder(pins: Mapping[str, PinSet], *, allow_in_dev: bool = False) -> None:
    """Raise PlaceholderPinError if any pin in the map is still a placeholder.

    The api/web boot path calls this in production mode. Dev/test setups can
    pass allow_in_dev=True to keep the placeholders so the rest of the
    codebase can be exercised without real network calls.
    """
    if allow_in_dev:
        return
    offenders = [host for host, ps in pins.items() if ps.has_placeholder]
    if offenders:
        raise PlaceholderPinError(
            "secure_http: placeholder pins detected for: " + ", ".join(sorted(offenders))
        )
