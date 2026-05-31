"""Revolut / generic CSV statement parser (B07·P02).

Tolerant header-driven CSV parser: it resolves the date / amount / currency /
description / reference / counterparty columns by header alias (so it handles
Revolut business + personal exports and most generic bank CSVs), and derives the
direction from the amount sign (or split paid-in/paid-out columns). It does not
type or hash anything — that is ``ingestion.normalize``'s job.
"""
from __future__ import annotations

import csv
import io
from collections.abc import Sequence

from cyprus_bookkeeping_api.parsers import ParsedRow, ParsedStatement

# Header aliases (lowercased, stripped) → canonical field.
_DATE_ALIASES = (
    "date completed (utc)", "completed date", "date completed", "completed date (utc)",
    "date started (utc)", "started date", "date started",
    "transaction date", "value date", "booking date", "date",
)
_AMOUNT_ALIASES = ("amount", "amount (eur)", "value", "transaction amount")
_PAID_IN_ALIASES = ("paid in", "money in", "credit", "paid in (eur)")
_PAID_OUT_ALIASES = ("paid out", "money out", "debit", "paid out (eur)")
_CURRENCY_ALIASES = ("currency", "ccy", "currency code")
_DESCRIPTION_ALIASES = ("description", "details", "narrative", "reference", "type", "name")
_REFERENCE_ALIASES = ("reference", "ref", "payment reference")
_COUNTERPARTY_ALIASES = ("counterparty", "beneficiary", "payee", "merchant", "name", "to/from")


def _find(headers: Sequence[str], aliases: Sequence[str]) -> str | None:
    norm = {h.strip().lower(): h for h in headers}
    for alias in aliases:
        if alias in norm:
            return norm[alias]
    return None


def _clean(value: str | None) -> str:
    return (value or "").strip()


def _looks_negative(amount_text: str) -> bool:
    t = amount_text.strip()
    return t.startswith("-") or (t.startswith("(") and t.endswith(")"))


def parse(data: bytes) -> ParsedStatement:
    """Parse statement bytes into provider-native rows + warnings."""
    if not data or not data.strip():
        return ParsedStatement(error_category="EMPTY_FILE", error_message="file is empty")

    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        try:
            text = data.decode("latin-1")
        except UnicodeDecodeError:
            return ParsedStatement(
                error_category="UNREADABLE_ENCODING", error_message="could not decode bytes"
            )

    try:
        reader = csv.reader(io.StringIO(text))
        table = [row for row in reader if any(_clean(c) for c in row)]
    except csv.Error as exc:
        return ParsedStatement(error_category="MALFORMED_CSV", error_message=str(exc)[:500])
    if not table:
        return ParsedStatement(error_category="EMPTY_FILE", error_message="no rows")

    headers = [_clean(h) for h in table[0]]
    date_col = _find(headers, _DATE_ALIASES)
    amount_col = _find(headers, _AMOUNT_ALIASES)
    paid_in_col = _find(headers, _PAID_IN_ALIASES)
    paid_out_col = _find(headers, _PAID_OUT_ALIASES)
    if date_col is None or (amount_col is None and not (paid_in_col or paid_out_col)):
        return ParsedStatement(
            error_category="MISSING_HEADERS",
            error_message=f"need a date column and an amount column; headers={headers}",
        )

    currency_col = _find(headers, _CURRENCY_ALIASES)
    description_col = _find(headers, _DESCRIPTION_ALIASES)
    reference_col = _find(headers, _REFERENCE_ALIASES)
    counterparty_col = _find(headers, _COUNTERPARTY_ALIASES)

    rows: list[ParsedRow] = []
    warnings: list[dict[str, object]] = []
    for index, raw in enumerate(table[1:], start=0):
        native = {headers[i]: _clean(raw[i]) for i in range(min(len(headers), len(raw)))}
        date_text = _clean(native.get(date_col))
        amount_text, direction = _resolve_amount(native, amount_col, paid_in_col, paid_out_col)
        if not date_text or not amount_text:
            warnings.append({"row_index": index, "message": "missing date or amount; row skipped"})
            continue
        rows.append(
            ParsedRow(
                source_row_index=index,
                provider_native=native,
                date_text=date_text,
                amount_text=amount_text,
                currency=_clean(native.get(currency_col)) if currency_col else "",
                direction_hint=direction,
                description_text=(_clean(native.get(description_col)) or None) if description_col else None,
                reference_text=(_clean(native.get(reference_col)) or None) if reference_col else None,
                counterparty_text=(_clean(native.get(counterparty_col)) or None) if counterparty_col else None,
            )
        )

    if not rows:
        return ParsedStatement(
            rows=[], warnings=warnings,
            error_category="MALFORMED_CSV",
            error_message="no usable rows after the header",
        )
    return ParsedStatement(rows=rows, warnings=warnings)


def _resolve_amount(
    native: dict[str, str], amount_col: str | None,
    paid_in_col: str | None, paid_out_col: str | None,
) -> tuple[str, str]:
    """Return (amount_text, direction_hint). amount_text keeps the source sign."""
    if amount_col is not None:
        amount_text = _clean(native.get(amount_col))
        if not amount_text:
            return "", "UNKNOWN"
        return amount_text, "OUT" if _looks_negative(amount_text) else "IN"
    paid_in = _clean(native.get(paid_in_col)) if paid_in_col else ""
    paid_out = _clean(native.get(paid_out_col)) if paid_out_col else ""
    if paid_out:
        return (paid_out if _looks_negative(paid_out) else f"-{paid_out}"), "OUT"
    if paid_in:
        return paid_in, "IN"
    return "", "UNKNOWN"
