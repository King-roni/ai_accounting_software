"""B05·P01 secure HTTP client primitives.

Enforces the project-wide outbound HTTP policy:

  * https:// scheme only (no plaintext fallback)
  * SubjectPublicKeyInfo (SPKI) SHA-256 fingerprint pinning for known external
    services (Anthropic, Google APIs, RFC 3161 timestamping, etc.)
  * Refuses to call a pinned host whose live SPKI fingerprint isn't in the
    configured set
  * Fail-fast startup self-check for the security baseline

Rotation: each pinned host carries a SET of fingerprints, so a new pin can be
installed alongside the old one before traffic is cut over (the "primary +
backup" model from RFC 7469). See the certificate-pinning sub-doc.
"""

from .pinning import (
    PinSet,
    PinMismatchError,
    PlaintextBlockedError,
    spki_fingerprint_from_der,
)
from .client import SecureClient, SecureClientError
from .startup import verify_security_baseline, BaselineCheckResult

__all__ = [
    "PinSet",
    "PinMismatchError",
    "PlaintextBlockedError",
    "spki_fingerprint_from_der",
    "SecureClient",
    "SecureClientError",
    "verify_security_baseline",
    "BaselineCheckResult",
]
