"""R7.1 serializers: CSV/JSON, the dependency-free PDF + XLSX writers, ZIP."""
from __future__ import annotations

import io
import json
import zipfile

from cyprus_bookkeeping_api.exports import serializers as S
from cyprus_bookkeeping_api.exports.pdf import render_pdf
from cyprus_bookkeeping_api.exports.xlsx import render_xlsx


def test_csv_quotes_commas_and_keeps_header():
    rows = [{"a": 1, "b": "x"}, {"a": 2, "b": "y,z"}]
    text = S.to_csv(["a", "b"], rows).decode()
    assert text.splitlines()[0] == "a,b"
    assert '"y,z"' in text


def test_csv_serializes_nested_value_as_json():
    text = S.to_csv(["a"], [{"a": {"k": 1}}]).decode()
    assert '"k": 1' in text.replace('""', '"')


def test_json_bytes_is_parseable():
    assert json.loads(S.to_json_bytes({"x": 1, "y": [1, 2]})) == {"x": 1, "y": [1, 2]}


def test_xlsx_is_a_valid_zip_with_required_parts():
    data = render_xlsx(["Name", "Amount"], [["Costa", 42.5], ["AWS", 213.77]])
    zf = zipfile.ZipFile(io.BytesIO(data))
    names = set(zf.namelist())
    assert {"[Content_Types].xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml"} <= names
    sheet = zf.read("xl/worksheets/sheet1.xml").decode()
    assert "Costa" in sheet and "<v>42.5</v>" in sheet


def test_xlsx_is_byte_stable():
    assert render_xlsx(["A"], [["x"]]) == render_xlsx(["A"], [["x"]])


def test_pdf_has_valid_skeleton():
    data = render_pdf("Title", ["line one", "line two"])
    assert data.startswith(b"%PDF-1.4")
    assert data.rstrip().endswith(b"%%EOF")
    assert b"/Type /Catalog" in data
    assert b"startxref" in data


def test_pdf_paginates_long_input():
    data = render_pdf("T", [f"row {i}" for i in range(200)])
    assert data.count(b"/Type /Page /") >= 3  # ~206 lines / 62 per page


def test_pdf_escapes_parens_and_backslash():
    data = render_pdf("T", ["has (paren) and \\ slash"])
    assert b"\\(paren\\)" in data and b"\\\\ slash" in data


def test_pdf_is_byte_stable():
    assert render_pdf("T", ["a", "b"]) == render_pdf("T", ["a", "b"])


def test_render_zip_roundtrips():
    data = S.render_zip([("a.txt", b"hello"), ("b.json", b"{}")])
    zf = zipfile.ZipFile(io.BytesIO(data))
    assert zf.read("a.txt") == b"hello" and zf.read("b.json") == b"{}"


def test_table_lines_render_values():
    lines = S.table_lines(["supplier", "total"], [{"supplier": "Costa", "total": 42.5}])
    assert lines[0].startswith("supplier")
    assert any("Costa" in line for line in lines)


def test_summary_lines_flatten_scalars_and_subtables():
    lines = S.summary_lines({"net": 793.74, "by_month": [{"month": "2026-05", "net": 1}]})
    assert any("net: 793.74" in line for line in lines)
    assert any("month" in line for line in lines)
