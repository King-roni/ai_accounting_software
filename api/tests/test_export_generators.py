"""R7.1 generators: each catalogue kind renders its composed data per format.

Composer RPCs that return a list are scripted as callables (the FakeGateway
treats a bare list as a pop-left queue), so the generator sees the whole array.
"""
from __future__ import annotations

import io
import json
import zipfile

import pytest

from cyprus_bookkeeping_api.exports.generators import (
    GenContext,
    UnsupportedExport,
    generate,
)


def _const(value):
    return lambda _params: value


def _ctx(gw, kind, fmt, *, ps="2026-05-01", pe="2026-05-31"):
    return GenContext(
        gateway=gw, export_id="e1", business_id="b1", organization_id="o1",
        export_kind=kind, fmt=fmt, period_start=ps, period_end=pe,
    )


_TX = [
    {"id": "t1", "amount": -42.5, "direction": "OUT", "transaction_date": "2026-05-02"},
    {"id": "t2", "amount": 1800, "direction": "IN", "transaction_date": "2026-05-04"},
]


def test_transactions_csv(gw):
    gw.script("_compose_transactions_json", _const(_TX))
    art = generate(_ctx(gw, "transaction_report", "CSV"))
    text = art.data.decode()
    assert art.fmt == "CSV" and "direction" in text and "t1" in text and "t2" in text


def test_transactions_xlsx(gw):
    gw.script("_compose_transactions_json", _const(_TX))
    art = generate(_ctx(gw, "transaction_report", "XLSX"))
    assert "xl/worksheets/sheet1.xml" in zipfile.ZipFile(io.BytesIO(art.data)).namelist()


def test_expense_keeps_only_outflows(gw):
    gw.script("_compose_transactions_json", _const(_TX))
    text = generate(_ctx(gw, "expense_report", "CSV")).data.decode()
    assert "t1" in text and "t2" not in text


def test_income_keeps_only_inflows(gw):
    gw.script("_compose_transactions_json", _const(_TX))
    text = generate(_ctx(gw, "income_report", "CSV")).data.decode()
    assert "t2" in text and "t1" not in text


def test_supplier_overview_csv(gw):
    gw.script("_compose_supplier_overview_json", _const(
        [{"supplier": "Costa", "transaction_count": 1, "total_outflow_eur": 42.5}]))
    assert "Costa" in generate(_ctx(gw, "supplier_overview", "CSV")).data.decode()


def test_invoice_match_csv(gw):
    gw.script("_compose_matches_json", _const([{"id": "m1", "match_level": "EXACT"}]))
    assert "m1" in generate(_ctx(gw, "invoice_match_report", "CSV")).data.decode()


def test_missing_evidence_csv(gw):
    gw.script("_compose_evidence_index_json", _const(
        [{"document_id": "d1", "original_filename": "x.pdf"}]))
    assert "x.pdf" in generate(_ctx(gw, "missing_evidence_report", "CSV")).data.decode()


def test_client_outstanding_pdf(gw):
    gw.script("_compose_client_outstanding_json", _const(
        [{"client": "Aphrodite", "outstanding_eur": 3570}]))
    art = generate(_ctx(gw, "client_outstanding_report", "PDF", ps=None, pe=None))
    assert art.fmt == "PDF" and art.data.startswith(b"%PDF") and b"Aphrodite" in art.data


def test_cashflow_overview_pdf(gw):
    gw.script("_compose_cashflow_summary_json", _const(
        {"net_eur": 793.74, "inflow_eur": 2340, "by_month": [{"month": "2026-05", "net_eur": 793.74}]}))
    art = generate(_ctx(gw, "cashflow_overview", "PDF"))
    assert art.fmt == "PDF" and art.data.startswith(b"%PDF")


def test_pnl_overview_pdf(gw):
    gw.script("_compose_pnl_summary_json", _const(
        {"net_profit_eur": 793.74, "basis": "cash", "by_type": []}))
    assert generate(_ctx(gw, "profit_loss_overview", "PDF")).data.startswith(b"%PDF")


def test_vat_report_json_passthrough(gw):
    gw.script("_compose_vat_summary_json", _const([{"box": "1", "value": 100}]))
    art = generate(_ctx(gw, "vat_preparation_report", "JSON"))
    assert json.loads(art.data) == [{"box": "1", "value": 100}]


def test_vat_report_pdf_handles_empty(gw):
    gw.script("_compose_vat_summary_json", _const([]))
    art = generate(_ctx(gw, "vat_preparation_report", "PDF"))
    assert art.data.startswith(b"%PDF")


def test_vies_xml(gw):
    gw.script("_compose_vies_export_csv",
              _const("counterparty_country,counterparty_vat_number,value_basis_eur\nCY,CY123,1000\n"))
    text = generate(_ctx(gw, "vies_export_file", "XML")).data.decode()
    assert "<vies_submission" in text
    assert "<counterparty_country>CY</counterparty_country>" in text
    assert "<value_basis_eur>1000</value_basis_eur>" in text


def _script_empty_components(gw):
    for fn in (
        "_compose_transactions_json", "_compose_matches_json",
        "_compose_supplier_overview_json", "_compose_evidence_index_json",
        "_compose_vat_summary_json", "_compose_ledger_entries_json",
    ):
        gw.script(fn, _const([]))


def test_accountant_pack_zip_has_manifest(gw):
    _script_empty_components(gw)
    art = generate(_ctx(gw, "accountant_export_pack", "ZIP"))
    names = zipfile.ZipFile(io.BytesIO(art.data)).namelist()
    assert "manifest.json" in names and "transactions.csv" in names
    assert art.component_count == len(names)


def test_finalized_archive_zip(gw):
    _script_empty_components(gw)
    art = generate(_ctx(gw, "finalized_archive_package", "ZIP"))
    assert "transactions.csv" in zipfile.ZipFile(io.BytesIO(art.data)).namelist()


def test_unknown_kind_raises(gw):
    with pytest.raises(UnsupportedExport):
        generate(_ctx(gw, "no_such_report", "CSV"))


def test_unsupported_format_raises(gw):
    gw.script("_compose_transactions_json", _const([]))
    with pytest.raises(UnsupportedExport):
        generate(_ctx(gw, "transaction_report", "XML"))
