"""Block 04 Phase 01 — hashing & ID utilities.

Canonical implementations consumed by every downstream phase:
deduplication keys (B07), audit-chain append (B05), archive bundle hash
(B15), workflow dedup-key fallback (B03), and the operational schema's
UUID v7 primary keys (B04·P02+).

Cross-platform parity is a hard contract: the Python implementations
here, the TypeScript mirror in `web/src/lib/hashing/`, and the Postgres
helpers in migration 20260519000013 all produce **byte-identical** output
for the same input. Golden-value tests pin this; changing a helper's
output is a breaking change that requires a migration plan.
"""
from __future__ import annotations

from cyprus_bookkeeping_api.hashing.core import (
    canonical_json,
    hash_bytes,
    hash_chain_append,
    hash_file,
    hash_record,
)
from cyprus_bookkeeping_api.hashing.domain import (
    archive_bundle_hash,
    default_dedup_key,
    source_row_hash,
    transaction_fingerprint,
)
from cyprus_bookkeeping_api.hashing.uuid7 import new_uuid, parse_uuid7_timestamp

__all__ = [
    "archive_bundle_hash",
    "canonical_json",
    "default_dedup_key",
    "hash_bytes",
    "hash_chain_append",
    "hash_file",
    "hash_record",
    "new_uuid",
    "parse_uuid7_timestamp",
    "source_row_hash",
    "transaction_fingerprint",
]
