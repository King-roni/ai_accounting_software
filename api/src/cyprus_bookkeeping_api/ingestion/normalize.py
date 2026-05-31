"""Normalize a provider-native parsed row into a typed, hashed transaction.

Turns the raw text fields into: an ISO date, an absolute decimal amount + an
IN/OUT direction (the DB signs it OUT-negative on insert), a cleaned
description, and the two canonical dedup keys (``source_row_hash`` over the full
native row, ``transaction_fingerprint`` over date/amount/currency/description).
Hashing uses the system's canonical helpers so dedup matches the rest of B07.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation

from cyprus_bookkeeping_api.hashing.domain import source_row_hash, transaction_fingerprint
from cyprus_bookkeeping_api.parsers import ParsedRow

_DATE_FORMATS = (
    "%Y-%m-%d", "%Y/%m/%d", "%d/%m/%Y", "%d-%m-%Y", "%d.%m.%Y",
    "%d %b %Y", "%d %B %Y", "%m/%d/%Y",
)


class NormalizationError(ValueError):
    """Raised when a parsed row cannot be normalized (bad date/amount)."""


@dataclass(frozen=True)
class NormalizedRow:
    transaction_date: str  # ISO YYYY-MM-DD
    amount: Decimal  # absolute (>= 0); direction carries the sign
    currency: str
    direction: str  # IN / OUT
    normalized_description: str
    source_row_hash: str
    transaction_fingerprint: str
    counterparty_name: str | None
    reference: str | None


def _parse_date(text: str) -> str:
    raw = text.strip()
    head = raw[:10]
    for candidate in (raw, head):
        try:
            return datetime.fromisoformat(candidate).date().isoformat()
        except ValueError:
            pass
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(raw, fmt).date().isoformat()
        except ValueError:
            continue
    raise NormalizationError(f"unparseable date: {text!r}")


def _parse_amount(text: str) -> Decimal:
    raw = text.strip()
    negative = raw.startswith("(") and raw.endswith(")")
    cleaned = re.sub(r"[^0-9.,\-]", "", raw.strip("()"))
    # Strip thousands separators: if both separators present, the last is decimal.
    if "," in cleaned and "." in cleaned:
        if cleaned.rfind(",") > cleaned.rfind("."):
            cleaned = cleaned.replace(".", "").replace(",", ".")
        else:
            cleaned = cleaned.replace(",", "")
    elif "," in cleaned:
        # lone comma: decimal separator if it looks like cents, else thousands
        cleaned = cleaned.replace(",", ".") if re.search(r",\d{1,2}$", cleaned) else cleaned.replace(",", "")
    try:
        value = Decimal(cleaned)
    except (InvalidOperation, ValueError) as exc:
        raise NormalizationError(f"unparseable amount: {text!r}") from exc
    if negative:
        value = -value
    return value


def normalize(row: ParsedRow, *, default_currency: str = "EUR") -> NormalizedRow:
    iso_date = _parse_date(row.date_text)
    signed = _parse_amount(row.amount_text)
    if signed < 0 or row.direction_hint == "OUT":
        direction = "OUT"
    else:
        direction = "IN"
    amount = signed.copy_abs()
    amount_canonical = f"{amount:.2f}"

    currency = (row.currency or default_currency).strip().upper() or default_currency
    description = re.sub(r"\s+", " ", (row.description_text or "").strip())

    fingerprint = transaction_fingerprint(
        {
            "date": iso_date,
            "amount": amount_canonical,
            "currency": currency,
            "description": description,
        }
    )
    return NormalizedRow(
        transaction_date=iso_date,
        amount=amount,
        currency=currency,
        direction=direction,
        normalized_description=description or "(no description)",
        source_row_hash=source_row_hash(row.provider_native),
        transaction_fingerprint=fingerprint,
        counterparty_name=row.counterparty_text,
        reference=row.reference_text,
    )
