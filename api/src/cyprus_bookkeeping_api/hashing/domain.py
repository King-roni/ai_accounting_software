"""Domain-specific hash derivations consumed by B07 (dedup),
B03 (tool-invocation dedup), and B15 (archive bundle hash).

Each derivation is a thin wrapper over `hash_record`/`hash_bytes`. The
wrappers exist to pin the canonical input shape so callers can't
accidentally hash a slightly different representation and miss the
match. The wrappers are part of the public hashing contract — changing
their input shape is a breaking change.
"""
from __future__ import annotations

import re
from typing import Any

from cyprus_bookkeeping_api.hashing.core import canonical_json, hash_bytes, hash_record


def source_row_hash(raw_row: str | bytes | dict[str, Any]) -> str:
    """SHA-256 of a raw bank-statement row. B07 dedup uses this to
    detect "this exact row was already imported."

    - bytes/str: hashed directly (UTF-8 if str).
    - dict: canonical_json then SHA-256 (use when the source is JSON).
    """
    if isinstance(raw_row, (bytes, bytearray)):
        return hash_bytes(bytes(raw_row))
    if isinstance(raw_row, str):
        return hash_bytes(raw_row.encode("utf-8"))
    return hash_record(raw_row)


def transaction_fingerprint(normalized: dict[str, Any]) -> str:
    """Softer match key for B07's `DUPLICATE_POSSIBLE` detection.

    Built from a fixed-shape canonical record:
        { "date", "amount", "currency", "description" }

    The description is whitespace-collapsed and lowercased. Amounts are
    expected as a string in canonical decimal form (e.g. "1234.56" — no
    thousands separators, two-decimal). The caller is responsible for
    that normalization; this function only enforces the shape.
    """
    required = {"date", "amount", "currency", "description"}
    missing = required - normalized.keys()
    if missing:
        raise ValueError(f"transaction_fingerprint: missing fields {sorted(missing)}")

    description = str(normalized["description"])
    description = re.sub(r"\s+", " ", description).strip().lower()

    canonical = {
        "date": str(normalized["date"]),
        "amount": str(normalized["amount"]),
        "currency": str(normalized["currency"]).upper(),
        "description": description,
    }
    return hash_record(canonical)


def archive_bundle_hash(bundle_manifest: dict[str, Any]) -> str:
    """Hash anchor for B15's sealed archive bundle.

    The MANIFEST (jsonb describing every file in the bundle + its
    individual file hash + metadata) is what we hash here — not the
    physical zip. The zip's own hash is computed via `hash_file` on the
    raw bytes; both anchors live alongside the bundle.
    """
    return hash_record(bundle_manifest)


def default_dedup_key(tool_name: str, input_payload: Any) -> str:
    """Fallback dedup key for B03's tool-invocation registry.

    Tools that don't supply their own dedup key generator get this:
    `sha256(tool_name || "\\x00" || canonical_json(input))`. The NUL
    byte is a domain separator so a malicious or accidental tool_name
    of the form `"foo{...payload"` can't collide with a different
    `(tool, input)` pair.
    """
    payload_canonical = canonical_json(input_payload).encode("utf-8")
    name_bytes = tool_name.encode("utf-8")
    return hash_bytes(name_bytes + b"\x00" + payload_canonical)
