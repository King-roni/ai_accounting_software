"""Canonical JSON + primitive SHA-256 helpers.

The canonical form is RFC-8785-style: keys sorted lexicographically and
recursively, compact separators (no whitespace), non-ASCII characters
emitted as UTF-8 (NOT escaped). Numbers are emitted via Python's default
`json.dumps`, which produces the same shortest-form output Node's
`JSON.stringify` produces for IEEE-754 doubles. Callers SHOULD avoid
passing floats whose stringification differs between platforms; integers
and strings are fully safe.
"""
from __future__ import annotations

import hashlib
import json
from io import IOBase
from typing import Any, BinaryIO

CHUNK_SIZE = 64 * 1024


def canonical_json(value: Any) -> str:
    """Canonical JSON serialization: sorted keys, compact separators,
    UTF-8 (no ASCII-escape). The output is the input to every record-
    level hash function. Two semantically equal inputs ALWAYS produce
    the same canonical string — that's what makes the hashes stable.
    """
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )


def hash_bytes(data: bytes) -> str:
    """SHA-256 hex of raw bytes."""
    return hashlib.sha256(data).hexdigest()


def hash_file(source: bytes | bytearray | memoryview | BinaryIO | IOBase) -> str:
    """SHA-256 of an in-memory buffer or a binary stream. Streams are
    consumed in 64 KiB chunks so large files don't blow up memory.
    """
    h = hashlib.sha256()
    if isinstance(source, (bytes, bytearray, memoryview)):
        h.update(source)
        return h.hexdigest()
    # Assume file-like
    while True:
        chunk = source.read(CHUNK_SIZE)
        if not chunk:
            break
        h.update(chunk)
    return h.hexdigest()


def hash_record(record: Any) -> str:
    """SHA-256 of `canonical_json(record).encode("utf-8")`."""
    return hash_bytes(canonical_json(record).encode("utf-8"))


def hash_chain_append(prev_hash: str, event_payload: Any) -> str:
    """Audit-chain append (B05 contract): the next chain head is
    `sha256(prev_hash_hex || canonical_json(event).encode())`. Treating
    `prev_hash` as its lowercase hex string means SQL and Python emit
    identical inputs to the digest.

    For the very first event in a chain, `prev_hash` is the all-zeros
    hex string `"0" * 64`.
    """
    h = hashlib.sha256()
    h.update(prev_hash.encode("utf-8"))
    h.update(canonical_json(event_payload).encode("utf-8"))
    return h.hexdigest()
