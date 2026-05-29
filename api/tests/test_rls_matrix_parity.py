"""Block 02 Phase 05 — parity test: Postgres `permission_matrix` table must
match the application matrix from B02·P04.

Reads the mirror via the Supabase REST API using the service-role key (which
bypasses RLS) and asserts every (role, surface) cell equals the Python
source-of-truth. Skipped when SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are
not set so local runs without backend credentials don't fail spuriously.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

import pytest

from cyprus_bookkeeping_api.access import (
    PERMISSION_MATRIX,
    Decision,
    PermissionSurface,
    Role,
)

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

pytestmark = pytest.mark.skipif(
    not (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY),
    reason="SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY not set",
)


def _fetch_postgres_matrix() -> dict[tuple[Role, PermissionSurface], Decision]:
    """Read public.permission_matrix via PostgREST with the service-role key."""
    assert SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY
    url = f"{SUPABASE_URL.rstrip('/')}/rest/v1/permission_matrix?select=role,surface,decision"
    req = urllib.request.Request(
        url,
        headers={
            "apikey": SUPABASE_SERVICE_ROLE_KEY,
            "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:  # pragma: no cover
        pytest.skip(f"Cannot reach Supabase: {exc}")

    out: dict[tuple[Role, PermissionSurface], Decision] = {}
    for row in rows:
        role = Role(row["role"])
        surface = PermissionSurface(row["surface"])
        decision = Decision(row["decision"])
        out[(role, surface)] = decision
    return out


def test_postgres_mirror_matches_python_matrix() -> None:
    db_matrix = _fetch_postgres_matrix()

    expected_keys = set(PERMISSION_MATRIX.keys())
    actual_keys = set(db_matrix.keys())

    missing_in_db = expected_keys - actual_keys
    extra_in_db = actual_keys - expected_keys
    assert not missing_in_db, f"Postgres mirror missing cells: {sorted(missing_in_db)}"
    assert not extra_in_db, f"Postgres mirror has unexpected cells: {sorted(extra_in_db)}"

    mismatched: list[tuple[Role, PermissionSurface, Decision, Decision]] = []
    for key, py_decision in PERMISSION_MATRIX.items():
        db_decision = db_matrix[key]
        if db_decision is not py_decision:
            mismatched.append((key[0], key[1], py_decision, db_decision))
    assert not mismatched, (
        "Postgres mirror disagrees with Python matrix:\n"
        + "\n".join(
            f"  ({r.value}, {s.value}): Python={py.value} Postgres={db.value}"
            for r, s, py, db in mismatched
        )
    )


def test_postgres_mirror_has_exactly_90_rows() -> None:
    db_matrix = _fetch_postgres_matrix()
    assert len(db_matrix) == 90, f"expected 90 cells, got {len(db_matrix)}"
