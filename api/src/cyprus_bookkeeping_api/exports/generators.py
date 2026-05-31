"""Export generators — map a catalogue kind + format to a rendered artifact.

Each generator pulls composed data from the DB (the ``_compose_*`` helpers, the
single source of truth for report data) and serializes it to the requested
format. The worker stays a pure serializer: no business logic lives here beyond
selecting the composer and shaping its output.
"""
from __future__ import annotations

import csv
import io
from dataclasses import dataclass
from typing import Any, Callable
from xml.sax.saxutils import escape

from cyprus_bookkeeping_api.exports import serializers as S
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway


class UnsupportedExport(RuntimeError):
    """Raised for an unknown export kind or an unrenderable (kind, format)."""


@dataclass
class GenContext:
    gateway: Gateway
    export_id: str
    business_id: str
    organization_id: str
    export_kind: str
    fmt: str
    period_start: str | None
    period_end: str | None

    @property
    def period_label(self) -> str:
        if self.period_start and self.period_end:
            return f"Period: {self.period_start} -> {self.period_end}"
        return "Scope: all-time"


def _period_params(ctx: GenContext) -> dict[str, Any]:
    return {
        "p_business_id": ctx.business_id,
        "p_period_start": ctx.period_start,
        "p_period_end": ctx.period_end,
    }


def _rows(ctx: GenContext, fn: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    data = ctx.gateway.rpc(fn, params if params is not None else _period_params(ctx))
    return list(data or [])


def _tabular(ctx: GenContext, rows: list[dict[str, Any]], title: str) -> S.Artifact:
    columns = S.columns_from_rows(rows)
    if ctx.fmt == "CSV":
        return S.Artifact(S.to_csv(columns, rows), "CSV")
    if ctx.fmt == "XLSX":
        return S.Artifact(S.to_xlsx(columns, rows), "XLSX")
    if ctx.fmt == "JSON":
        return S.Artifact(S.to_json_bytes(rows), "JSON")
    if ctx.fmt == "PDF":
        body = S.table_lines(columns, rows) if rows else ["(no rows for this scope)"]
        return S.Artifact(S.render_pdf(title, [ctx.period_label, ""] + body), "PDF")
    raise UnsupportedExport(f"{ctx.export_kind}:{ctx.fmt}")


def _summary(ctx: GenContext, obj: dict[str, Any], title: str) -> S.Artifact:
    if ctx.fmt == "JSON":
        return S.Artifact(S.to_json_bytes(obj), "JSON")
    if ctx.fmt == "PDF":
        return S.Artifact(S.render_pdf(title, S.summary_lines(obj)), "PDF")
    raise UnsupportedExport(f"{ctx.export_kind}:{ctx.fmt}")


def _vies_xml(ctx: GenContext) -> S.Artifact:
    text = ctx.gateway.rpc("_compose_vies_export_csv", _period_params(ctx)) or ""
    reader = list(csv.reader(io.StringIO(text)))
    header = reader[0] if reader else []
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<vies_submission business_id="{escape(ctx.business_id)}" '
        f'period_start="{escape(ctx.period_start or "")}" '
        f'period_end="{escape(ctx.period_end or "")}">',
    ]
    for data_row in reader[1:]:
        out.append("  <line>")
        for col, value in zip(header, data_row):
            tag = escape(col.strip())
            out.append(f"    <{tag}>{escape(value)}</{tag}>")
        out.append("  </line>")
    out.append("</vies_submission>")
    return S.Artifact("\n".join(out).encode("utf-8"), "XML")


def _bundle(ctx: GenContext, components: list[tuple[str, bytes]]) -> S.Artifact:
    return S.Artifact(S.render_zip(components), "ZIP", component_count=len(components))


def _period_bundle_components(ctx: GenContext) -> list[tuple[str, bytes]]:
    """CSV/JSON components shared by the ZIP bundles, from period composers."""
    transactions = _rows(ctx, "_compose_transactions_json")
    matches = _rows(ctx, "_compose_matches_json")
    suppliers = _rows(ctx, "_compose_supplier_overview_json")
    evidence = _rows(ctx, "_compose_evidence_index_json")
    vat = ctx.gateway.rpc("_compose_vat_summary_json", _period_params(ctx)) or []
    ledger = ctx.gateway.rpc("_compose_ledger_entries_json", _period_params(ctx)) or []
    return [
        ("transactions.csv", S.to_csv(S.columns_from_rows(transactions), transactions)),
        ("matches.csv", S.to_csv(S.columns_from_rows(matches), matches)),
        ("supplier_overview.csv", S.to_csv(S.columns_from_rows(suppliers), suppliers)),
        ("evidence_index.csv", S.to_csv(S.columns_from_rows(evidence), evidence)),
        ("vat_summary.json", S.to_json_bytes(vat)),
        ("ledger_entries.json", S.to_json_bytes(ledger)),
    ]


# --- generators -----------------------------------------------------------

def _g_transactions(ctx: GenContext) -> S.Artifact:
    return _tabular(ctx, _rows(ctx, "_compose_transactions_json"), "Transaction report")


def _g_expense(ctx: GenContext) -> S.Artifact:
    rows = [r for r in _rows(ctx, "_compose_transactions_json") if r.get("direction") == "OUT"]
    return _tabular(ctx, rows, "Expense report")


def _g_income(ctx: GenContext) -> S.Artifact:
    rows = [r for r in _rows(ctx, "_compose_transactions_json") if r.get("direction") == "IN"]
    return _tabular(ctx, rows, "Income report")


def _g_supplier(ctx: GenContext) -> S.Artifact:
    return _tabular(ctx, _rows(ctx, "_compose_supplier_overview_json"), "Supplier overview")


def _g_invoice_match(ctx: GenContext) -> S.Artifact:
    return _tabular(ctx, _rows(ctx, "_compose_matches_json"), "Invoice match report")


def _g_missing_evidence(ctx: GenContext) -> S.Artifact:
    return _tabular(ctx, _rows(ctx, "_compose_evidence_index_json"), "Evidence index")


def _g_client_outstanding(ctx: GenContext) -> S.Artifact:
    rows = _rows(ctx, "_compose_client_outstanding_json", {"p_business_id": ctx.business_id})
    return _tabular(ctx, rows, "Client outstanding report")


def _g_cashflow(ctx: GenContext) -> S.Artifact:
    obj = ctx.gateway.rpc("_compose_cashflow_summary_json", _period_params(ctx)) or {}
    return _summary(ctx, obj, "Cashflow overview")


def _g_pnl(ctx: GenContext) -> S.Artifact:
    obj = ctx.gateway.rpc("_compose_pnl_summary_json", _period_params(ctx)) or {}
    return _summary(ctx, obj, "Profit / loss overview")


def _g_vat(ctx: GenContext) -> S.Artifact:
    data = ctx.gateway.rpc("_compose_vat_summary_json", _period_params(ctx)) or []
    if ctx.fmt == "JSON":
        return S.Artifact(S.to_json_bytes(data), "JSON")
    rows = list(data)
    body = S.table_lines(S.columns_from_rows(rows), rows) if rows else ["(no VAT lines for this period)"]
    return S.Artifact(S.render_pdf("VAT preparation report", [ctx.period_label, ""] + body), "PDF")


def _g_vies(ctx: GenContext) -> S.Artifact:
    return _vies_xml(ctx)


def _g_accountant_pack(ctx: GenContext) -> S.Artifact:
    components = _period_bundle_components(ctx)
    manifest = {
        "export_kind": ctx.export_kind,
        "business_id": ctx.business_id,
        "period_start": ctx.period_start,
        "period_end": ctx.period_end,
        "components": [name for name, _ in components],
    }
    components.append(("manifest.json", S.to_json_bytes(manifest)))
    return _bundle(ctx, components)


def _g_finalized_archive(ctx: GenContext) -> S.Artifact:
    return _bundle(ctx, _period_bundle_components(ctx))


_REGISTRY: dict[str, Callable[[GenContext], S.Artifact]] = {
    "transaction_report": _g_transactions,
    "expense_report": _g_expense,
    "income_report": _g_income,
    "supplier_overview": _g_supplier,
    "invoice_match_report": _g_invoice_match,
    "missing_evidence_report": _g_missing_evidence,
    "client_outstanding_report": _g_client_outstanding,
    "cashflow_overview": _g_cashflow,
    "profit_loss_overview": _g_pnl,
    "vat_preparation_report": _g_vat,
    "vies_export_file": _g_vies,
    "accountant_export_pack": _g_accountant_pack,
    "finalized_archive_package": _g_finalized_archive,
}


def generate(ctx: GenContext) -> S.Artifact:
    """Produce the artifact for one export, or raise :class:`UnsupportedExport`."""
    handler = _REGISTRY.get(ctx.export_kind)
    if handler is None:
        raise UnsupportedExport(ctx.export_kind)
    return handler(ctx)
