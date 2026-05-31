"""R7.2 Revolut/generic CSV parser."""
from __future__ import annotations

from cyprus_bookkeeping_api.parsers import revolut_csv

_REVOLUT = (
    "Date completed (UTC),Description,Amount,Currency,Reference\n"
    "2026-06-02 09:15:00,Costa Coffee,-4.50,EUR,REF1\n"
    "2026-06-03 12:00:00,Client Payment,1200.00,EUR,INV-1\n"
).encode("utf-8")


def test_parses_signed_amount_rows_with_direction():
    out = revolut_csv.parse(_REVOLUT)
    assert not out.failed and len(out.rows) == 2
    first, second = out.rows
    assert first.amount_text == "-4.50" and first.direction_hint == "OUT"
    assert first.description_text == "Costa Coffee" and first.currency == "EUR"
    assert second.direction_hint == "IN" and second.amount_text == "1200.00"
    assert second.source_row_index == 1


def test_paid_in_paid_out_columns():
    csv_bytes = (
        "Date,Description,Paid Out,Paid In,Currency\n"
        "2026-06-02,Rent,1200.00,,EUR\n"
        "2026-06-04,Sale,,540.00,EUR\n"
    ).encode("utf-8")
    out = revolut_csv.parse(csv_bytes)
    assert [r.direction_hint for r in out.rows] == ["OUT", "IN"]
    assert out.rows[0].amount_text.startswith("-")


def test_empty_file_flagged():
    out = revolut_csv.parse(b"   ")
    assert out.failed and out.error_category == "EMPTY_FILE"


def test_missing_amount_header_flagged():
    out = revolut_csv.parse(b"Date,Description\n2026-06-02,x\n")
    assert out.failed and out.error_category == "MISSING_HEADERS"


def test_rows_missing_required_fields_become_warnings():
    csv_bytes = (
        "Date,Description,Amount,Currency\n"
        "2026-06-02,Good,-4.50,EUR\n"
        ",Missing date,-1.00,EUR\n"
    ).encode("utf-8")
    out = revolut_csv.parse(csv_bytes)
    assert len(out.rows) == 1 and len(out.warnings) == 1


def test_utf8_bom_tolerated():
    out = revolut_csv.parse(b"\xef\xbb\xbfDate,Amount,Currency\n2026-06-02,-4.50,EUR\n")
    assert not out.failed and len(out.rows) == 1
