"""Minimal, dependency-free PDF/1.4 writer (Courier, paginated text).

Produces a genuinely valid, openable PDF without pulling in reportlab. Not a
general-purpose PDF library — just enough for tabular/summary report output.
Output is byte-stable for identical input (no embedded timestamps).
"""
from __future__ import annotations

from typing import Iterable, Sequence

_PAGE_W, _PAGE_H = 595, 842  # A4 in points
_MARGIN_X = 40
_TOP_Y = 802
_FONT_SIZE = 9
_LEADING = 12
_LINES_PER_PAGE = 62
_WRAP = 110  # chars per line at Courier 9pt within the A4 text box


def _escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def _wrap_line(line: str) -> list[str]:
    line = line.replace("\t", "    ").rstrip("\r\n")
    if line == "":
        return [""]
    chunks: list[str] = []
    while line:
        chunks.append(line[:_WRAP])
        line = line[_WRAP:]
    return chunks


def _paginate(lines: Sequence[str]) -> list[list[str]]:
    flat: list[str] = []
    for raw in lines:
        flat.extend(_wrap_line(raw))
    pages = [flat[i:i + _LINES_PER_PAGE] for i in range(0, len(flat), _LINES_PER_PAGE)]
    return pages or [[""]]


def _content_stream(page_lines: Sequence[str]) -> bytes:
    parts = ["BT", f"/F1 {_FONT_SIZE} Tf", f"{_MARGIN_X} {_TOP_Y} Td", f"{_LEADING} TL"]
    for idx, line in enumerate(page_lines):
        if idx:
            parts.append("T*")
        parts.append(f"({_escape(line)}) Tj")
    parts.append("ET")
    return "\n".join(parts).encode("latin-1", "replace")


def render_pdf(title: str, lines: Iterable[str]) -> bytes:
    """Render a title + lines into a paginated A4 PDF (bytes)."""
    header = [title, "=" * min(max(len(title), 1), _WRAP), ""]
    pages = _paginate(header + list(lines))
    n_pages = len(pages)

    font_obj = 3
    first_page_obj = 4
    page_obj_nums = [first_page_obj + 2 * i for i in range(n_pages)]
    content_obj_nums = [first_page_obj + 2 * i + 1 for i in range(n_pages)]

    parts: list[bytes] = [b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"]
    offsets: dict[int, int] = {}

    def emit(num: int, payload: bytes) -> None:
        offsets[num] = sum(len(p) for p in parts)
        parts.append(f"{num} 0 obj\n".encode() + payload + b"\nendobj\n")

    kids = " ".join(f"{p} 0 R" for p in page_obj_nums)
    emit(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    emit(2, f"<< /Type /Pages /Kids [{kids}] /Count {n_pages} >>".encode())
    emit(font_obj, b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>")
    for i, page in enumerate(pages):
        stream = _content_stream(page)
        emit(
            page_obj_nums[i],
            (
                f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {_PAGE_W} {_PAGE_H}] "
                f"/Resources << /Font << /F1 {font_obj} 0 R >> >> "
                f"/Contents {content_obj_nums[i]} 0 R >>"
            ).encode(),
        )
        emit(
            content_obj_nums[i],
            f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream",
        )

    xref_pos = sum(len(p) for p in parts)
    max_obj = max(offsets)
    xref = [f"xref\n0 {max_obj + 1}\n", "0000000000 65535 f \n"]
    for num in range(1, max_obj + 1):
        xref.append(f"{offsets[num]:010d} 00000 n \n")
    parts.append("".join(xref).encode())
    parts.append(
        f"trailer\n<< /Size {max_obj + 1} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF".encode()
    )
    return b"".join(parts)
