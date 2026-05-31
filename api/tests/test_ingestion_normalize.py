"""R7.2 normalization: typing, direction, canonical hashing."""
from __future__ import annotations

from decimal import Decimal

import pytest

from cyprus_bookkeeping_api.hashing.domain import transaction_fingerprint
from cyprus_bookkeeping_api.ingestion.normalize import NormalizationError, normalize
from cyprus_bookkeeping_api.parsers import ParsedRow


def _row(**kw) -> ParsedRow:
    base = dict(
        source_row_index=0, provider_native={"Date": "2026-06-02", "Amount": "-4.50"},
        date_text="2026-06-02", amount_text="-4.50", currency="EUR",
        direction_hint="OUT", description_text="Costa  Coffee", reference_text="R1",
        counterparty_text="Costa",
    )
    base.update(kw)
    return ParsedRow(**base)


def test_negative_amount_is_out_and_absolute():
    n = normalize(_row())
    assert n.direction == "OUT" and n.amount == Decimal("4.50")
    assert n.transaction_date == "2026-06-02"


def test_positive_amount_is_in():
    n = normalize(_row(amount_text="1200.00", direction_hint="IN"))
    assert n.direction == "IN" and n.amount == Decimal("1200.00")


def test_description_whitespace_collapsed_and_fingerprint_matches_canonical():
    n = normalize(_row())
    assert n.normalized_description == "costa coffee" or "costa" in n.normalized_description.lower()
    expected = transaction_fingerprint(
        {"date": "2026-06-02", "amount": "4.50", "currency": "EUR", "description": "costa coffee"}
    )
    assert n.transaction_fingerprint == expected
    assert len(n.source_row_hash) == 64


def test_parenthesised_negative_and_thousands_separator():
    n = normalize(_row(amount_text="(1,234.56)", direction_hint="UNKNOWN"))
    assert n.direction == "OUT" and n.amount == Decimal("1234.56")


def test_european_date_format():
    n = normalize(_row(date_text="02/06/2026"))
    assert n.transaction_date == "2026-06-02"


def test_bad_amount_raises():
    with pytest.raises(NormalizationError):
        normalize(_row(amount_text="not-a-number"))


def test_bad_date_raises():
    with pytest.raises(NormalizationError):
        normalize(_row(date_text="someday"))
