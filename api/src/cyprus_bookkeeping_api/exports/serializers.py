"""Format serializers + the :class:`Artifact` the worker uploads.

CSV/JSON/XML via stdlib; XLSX/PDF via the dependency-free writers in this
package; ZIP via stdlib with deterministic timestamps. Text tables (for PDF)
and a key/value summary renderer live here too.
"""
from __future__ import annotations

import csv
import io
import json
import zipfile
from dataclasses import dataclass
from typing import Any, Sequence

from cyprus_bookkeeping_api.exports.pdf import render_pdf
from cyprus_bookkeeping_api.exports.xlsx import render_xlsx

__all__ = [
    "Artifact",
    "render_pdf",
    "columns_from_rows",
    "to_csv",
    "to_json_bytes",
    "to_xlsx",
    "render_zip",
    "table_lines",
    "summary_lines",
]

_CONTENT_TYPES = {
    "CSV": "text/csv; charset=utf-8",
    "XLSX": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "PDF": "application/pdf",
    "JSON": "application/json; charset=utf-8",
    "XML": "application/xml; charset=utf-8",
    "ZIP": "application/zip",
}
_EXTENSIONS = {"CSV": "csv", "XLSX": "xlsx", "PDF": "pdf", "JSON": "json", "XML": "xml", "ZIP": "zip"}
_ZIP_DATE = (1980, 1, 1, 0, 0, 0)
_MAX_COL_WIDTH = 40


@dataclass(frozen=True)
class Artifact:
    """A generated export file ready for upload."""

    data: bytes
    fmt: str
    component_count: int = 0  # set for ZIP bundles (accountant pack)

    @property
    def extension(self) -> str:
        return _EXTENSIONS[self.fmt]

    @property
    def content_type(self) -> str:
        return _CONTENT_TYPES[self.fmt]


def columns_from_rows(rows: Sequence[dict[str, Any]]) -> list[str]:
    """Stable union of keys across the row dicts, in first-seen order."""
    cols: list[str] = []
    for row in rows:
        for key in row:
            if key not in cols:
                cols.append(key)
    return cols


def _scalar(value: Any) -> Any:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, default=str)
    return value


def _text(value: Any) -> str:
    scalar = _scalar(value)
    return scalar if isinstance(scalar, str) else str(scalar)


def to_csv(columns: Sequence[str], rows: Sequence[dict[str, Any]]) -> bytes:
    sio = io.StringIO()
    writer = csv.writer(sio, lineterminator="\n")
    writer.writerow(list(columns))
    for row in rows:
        writer.writerow([_scalar(row.get(c)) for c in columns])
    return sio.getvalue().encode("utf-8")


def to_json_bytes(obj: Any) -> bytes:
    return json.dumps(obj, indent=2, ensure_ascii=False, default=str).encode("utf-8")


def to_xlsx(columns: Sequence[str], rows: Sequence[dict[str, Any]]) -> bytes:
    return render_xlsx(columns, [[_scalar(row.get(c)) for c in columns] for row in rows])


def render_zip(components: Sequence[tuple[str, bytes]]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, payload in components:
            info = zipfile.ZipInfo(name, date_time=_ZIP_DATE)
            zf.writestr(info, payload)
    return buf.getvalue()


def table_lines(columns: Sequence[str], rows: Sequence[dict[str, Any]]) -> list[str]:
    """Fixed-width monospaced text table (for PDF rendering)."""
    str_rows = [[_text(row.get(c)) for c in columns] for row in rows]
    widths = [min(len(str(c)), _MAX_COL_WIDTH) for c in columns]
    for sr in str_rows:
        for i, val in enumerate(sr):
            widths[i] = min(max(widths[i], len(val)), _MAX_COL_WIDTH)

    def fmt(values: Sequence[str]) -> str:
        return "  ".join(str(v)[: widths[i]].ljust(widths[i]) for i, v in enumerate(values))

    lines = [fmt([str(c) for c in columns]), fmt(["-" * w for w in widths])]
    lines.extend(fmt(sr) for sr in str_rows)
    return lines


def summary_lines(obj: dict[str, Any]) -> list[str]:
    """Flatten a summary dict to text lines (nested tables/dicts indented)."""
    lines: list[str] = []
    for key, value in obj.items():
        if isinstance(value, list):
            lines.append(f"{key}:")
            if value and all(isinstance(v, dict) for v in value):
                cols = columns_from_rows(value)
                lines.extend("  " + line for line in table_lines(cols, value))
            else:
                lines.extend(f"  - {_text(v)}" for v in value)
            lines.append("")
        elif isinstance(value, dict):
            lines.append(f"{key}:")
            lines.extend("  " + line for line in summary_lines(value))
        else:
            lines.append(f"{key}: {_text(value)}")
    return lines
