"""Golden-value tests for Block 04 Phase 01 hashing primitives.

The values pinned here are the cross-platform contract: the TypeScript
mirror and the Postgres helper MUST reproduce them byte-for-byte. If
this file's expectations change, the TS goldens script and the SQL
parity test MUST update together.
"""
from __future__ import annotations

import io
import re
import time

import pytest

from cyprus_bookkeeping_api.hashing import (
    archive_bundle_hash,
    canonical_json,
    default_dedup_key,
    hash_bytes,
    hash_chain_append,
    hash_file,
    hash_record,
    new_uuid,
    parse_uuid7_timestamp,
    source_row_hash,
    transaction_fingerprint,
)


# ---------- canonical_json ---------------------------------------------------


def test_canonical_json_sorts_keys() -> None:
    assert canonical_json({"b": 1, "a": 2}) == '{"a":2,"b":1}'


def test_canonical_json_recursive_sort() -> None:
    assert (
        canonical_json({"b": {"y": 1, "x": 2}, "a": [3, 2, 1]})
        == '{"a":[3,2,1],"b":{"x":2,"y":1}}'
    )


def test_canonical_json_preserves_array_order() -> None:
    assert canonical_json([3, 1, 2]) == "[3,1,2]"


def test_canonical_json_unicode_unescaped() -> None:
    # Non-ASCII characters survive verbatim — matches Node's
    # JSON.stringify default. This pins the cross-platform contract.
    assert canonical_json({"name": "Søren"}) == '{"name":"Søren"}'


def test_canonical_json_rejects_nan() -> None:
    with pytest.raises(ValueError):
        canonical_json({"x": float("nan")})


# ---------- hash_bytes / hash_file -------------------------------------------


def test_hash_bytes_golden_empty() -> None:
    # SHA-256 of empty bytes is the famous e3b0c... constant.
    assert (
        hash_bytes(b"")
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )


def test_hash_bytes_golden_abc() -> None:
    assert (
        hash_bytes(b"abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )


def test_hash_file_stream_chunked() -> None:
    # 200 KB of zeros — exercises the chunked-read path.
    data = b"\x00" * (200 * 1024)
    expected = hash_bytes(data)
    assert hash_file(io.BytesIO(data)) == expected


def test_hash_file_buffer_short_circuit() -> None:
    assert hash_file(b"abc") == hash_bytes(b"abc")


# ---------- hash_record ------------------------------------------------------


def test_hash_record_golden_simple() -> None:
    # canonical_json({"a":1,"b":2}) == '{"a":1,"b":2}'
    # sha256 of that string == 43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777
    assert (
        hash_record({"a": 1, "b": 2})
        == "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777"
    )


def test_hash_record_key_order_insensitive() -> None:
    assert hash_record({"b": 2, "a": 1}) == hash_record({"a": 1, "b": 2})


# ---------- hash_chain_append ------------------------------------------------


GENESIS_HASH = "0" * 64

# Cross-platform golden: the SQL hash_chain_append helper in migration
# 20260519000013 and the TS hashChainAppend in `web/src/lib/hashing/hash.ts`
# both produce this hex for the same input. Changing it is a breaking
# change to the audit-chain contract (B05·P02).
GENESIS_EVENT_CHAIN_HEAD = (
    "40c3929457af2429a2a701cd95aa3c28781f141f190bd4440f62334f30c512b5"
)


def test_hash_chain_append_genesis_event() -> None:
    # Pin the very first chain link for a known event.
    expected = hash_bytes(
        GENESIS_HASH.encode("utf-8")
        + b'{"event":"GENESIS","sequence":0}'
    )
    assert hash_chain_append(GENESIS_HASH, {"event": "GENESIS", "sequence": 0}) == expected


def test_hash_chain_append_cross_platform_golden() -> None:
    """Pin the literal hex that Postgres + TypeScript also produce."""
    assert (
        hash_chain_append(GENESIS_HASH, {"event": "GENESIS", "sequence": 0})
        == GENESIS_EVENT_CHAIN_HEAD
    )


def test_hash_chain_append_deterministic_across_calls() -> None:
    a = hash_chain_append(GENESIS_HASH, {"x": 1})
    b = hash_chain_append(GENESIS_HASH, {"x": 1})
    assert a == b


# ---------- domain helpers ---------------------------------------------------


def test_source_row_hash_string_and_dict_consistent() -> None:
    raw = '{"date":"2026-05-19","amount":"100.00"}'
    assert source_row_hash(raw) == hash_bytes(raw.encode("utf-8"))


def test_transaction_fingerprint_normalizes_description() -> None:
    a = transaction_fingerprint({
        "date": "2026-05-19", "amount": "100.00", "currency": "EUR",
        "description": "  ACME  Corp Payment ",
    })
    b = transaction_fingerprint({
        "date": "2026-05-19", "amount": "100.00", "currency": "EUR",
        "description": "acme corp payment",
    })
    assert a == b


def test_transaction_fingerprint_currency_case_insensitive() -> None:
    a = transaction_fingerprint({
        "date": "2026-05-19", "amount": "100.00", "currency": "eur",
        "description": "Lunch",
    })
    b = transaction_fingerprint({
        "date": "2026-05-19", "amount": "100.00", "currency": "EUR",
        "description": "Lunch",
    })
    assert a == b


def test_transaction_fingerprint_rejects_missing_fields() -> None:
    with pytest.raises(ValueError):
        transaction_fingerprint({"date": "2026-05-19", "amount": "1"})  # type: ignore[typeddict-item]


def test_archive_bundle_hash_round_trips() -> None:
    manifest = {"version": 1, "files": [{"name": "x.csv", "hash": "abc"}]}
    assert archive_bundle_hash(manifest) == hash_record(manifest)


def test_default_dedup_key_separates_tool_from_payload() -> None:
    # 'foo' + NUL + canonical_json({}) is different from
    # 'foo{}' + NUL + canonical_json({}). The NUL separator prevents
    # confusion-style collisions.
    a = default_dedup_key("foo", {})
    b = default_dedup_key("foo{}", {})
    assert a != b


def test_default_dedup_key_payload_order_insensitive() -> None:
    a = default_dedup_key("my_tool", {"a": 1, "b": 2})
    b = default_dedup_key("my_tool", {"b": 2, "a": 1})
    assert a == b


# ---------- UUID v7 ----------------------------------------------------------


def test_new_uuid_shape() -> None:
    u = new_uuid()
    assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", u), u


def test_new_uuid_sortable_in_insertion_order() -> None:
    samples = []
    for _ in range(50):
        samples.append(new_uuid())
        time.sleep(0.002)  # ensure ms tick
    assert samples == sorted(samples), "UUID v7 broke insertion-time sort"


def test_parse_uuid7_timestamp_recovers_ms() -> None:
    before_ms = int(time.time() * 1000)
    u = new_uuid()
    after_ms = int(time.time() * 1000)
    parsed = parse_uuid7_timestamp(u)
    assert before_ms <= parsed <= after_ms
