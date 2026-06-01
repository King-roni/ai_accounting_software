"""Guard test — no public RPC may use the stale REQUIRE_STEP_UP vocabulary.

8 SECURITY DEFINER RPCs guarded with `v_perm_dec NOT IN ('ALLOW','STEP_UP')`,
which wrongly rejects the matrix's `REQUIRE_STEP_UP` decision. Migration
20260601000012 swept them; 20260601000014 added the
`list_stale_step_up_guard_functions()` sentinel. This asserts the sentinel
returns zero rows against the live DB, catching any NEW function that
reintroduces the stale 2-arg form.

Skipped when SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set (mirrors
test_rls_matrix_parity), so local runs without backend credentials don't fail
spuriously.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

import pytest

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

pytestmark = pytest.mark.skipif(
    not (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY),
    reason="SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY not set",
)


def _list_stale_guards() -> list[str]:
    """Call public.list_stale_step_up_guard_functions() via PostgREST RPC."""
    assert SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY
    url = f"{SUPABASE_URL.rstrip('/')}/rest/v1/rpc/list_stale_step_up_guard_functions"
    req = urllib.request.Request(
        url,
        data=b"{}",
        method="POST",
        headers={
            "apikey": SUPABASE_SERVICE_ROLE_KEY,
            "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:  # pragma: no cover
        pytest.skip(f"Cannot reach Supabase: {exc}")

    # RETURNS TABLE(function_name text) → PostgREST yields [{"function_name": ...}] or [].
    return [r["function_name"] if isinstance(r, dict) else r for r in rows]


def test_no_public_function_uses_stale_step_up_guard() -> None:
    stale = _list_stale_guards()
    assert stale == [], (
        "Public functions still guard with the stale `NOT IN ('ALLOW','STEP_UP')` "
        "form (missing 'REQUIRE_STEP_UP'); they will wrongly reject a REQUIRE_STEP_UP "
        f"matrix decision: {stale}"
    )
