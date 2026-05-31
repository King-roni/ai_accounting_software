"""Bank-statement parsers (B07·P02).

Each parser turns raw uploaded bytes into a :class:`ParsedStatement` — a list of
:class:`ParsedRow` (provider-native field text, untyped) plus any structural
warnings/errors. Normalization (typing dates/amounts, hashing) happens later in
``ingestion.normalize``; parsers only read the provider's layout.

The active parser for a (provider, file_format) is recorded in
``statement_parser_registry``; its ``parser_module_ref`` points here, e.g.
``cyprus_bookkeeping_api.parsers.revolut_csv:parse``.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class ParsedRow:
    """One provider-native statement row (all fields are raw text)."""

    source_row_index: int
    provider_native: dict[str, str]
    date_text: str
    amount_text: str
    currency: str
    direction_hint: str = "UNKNOWN"  # parsed_row_direction_hint_enum: IN/OUT/UNKNOWN
    description_text: str | None = None
    reference_text: str | None = None
    counterparty_text: str | None = None


@dataclass(frozen=True)
class ParsedStatement:
    """Result of parsing a statement file."""

    rows: list[ParsedRow] = field(default_factory=list)
    warnings: list[dict[str, object]] = field(default_factory=list)
    error_category: str | None = None  # statement_parse_error_category_enum or None
    error_message: str | None = None

    @property
    def failed(self) -> bool:
        return self.error_category is not None
