"""B05·P01 startup self-check.

Boot-time assertion that the security baseline is in place:

  * Every storage bucket the app uses is private + present (queried via the
    public.at_rest_encryption_status() RPC).
  * The pin map contains no placeholder fingerprints in production mode.
  * The configured Supabase Postgres + Storage project is in the EU region
    (Stage 1 decision — verified out-of-band; this self-check only documents
    the assertion).

Fail-fast on any deviation. The API should refuse to start if this returns
``ok=False``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any, Mapping

from .pinning import DEFAULT_PIN_MAP, PinSet, assert_no_placeholder


@dataclass
class BaselineCheckResult:
    ok: bool
    checks: list[dict[str, Any]] = field(default_factory=list)
    note: str = ""


def verify_security_baseline(
    *,
    db_status_fn: Any,
    pins: Mapping[str, PinSet] = DEFAULT_PIN_MAP,
    environment: str | None = None,
) -> BaselineCheckResult:
    """Run the boot-time security baseline check.

    Parameters
    ----------
    db_status_fn:
        Callable returning the JSONB result of
        ``public.at_rest_encryption_status()``. Inject the actual DB call from
        the caller so this module stays connection-free and unit-testable.
    pins:
        Pin map to validate. Defaults to the project's DEFAULT_PIN_MAP.
    environment:
        ``"production"`` requires no placeholder pins. Falls back to
        ``$APP_ENV`` then ``"development"``.
    """
    env = environment or os.environ.get("APP_ENV", "development")
    checks: list[dict[str, Any]] = []
    ok = True

    # ---- at-rest / bucket privacy ----------------------------------------
    try:
        db_status = db_status_fn()
    except Exception as exc:  # noqa: BLE001 — startup safety net
        checks.append(
            {"name": "at_rest_status_rpc", "ok": False, "error": str(exc)}
        )
        ok = False
    else:
        bucket_ok = bool(db_status.get("all_ok"))
        checks.append({"name": "at_rest_status_rpc", "ok": bucket_ok, "buckets": db_status.get("buckets")})
        if not bucket_ok:
            ok = False

    # ---- pin map sanity (no placeholders in prod) ------------------------
    if env == "production":
        try:
            assert_no_placeholder(pins, allow_in_dev=False)
            checks.append({"name": "pin_map_no_placeholders", "ok": True})
        except Exception as exc:  # noqa: BLE001
            checks.append({"name": "pin_map_no_placeholders", "ok": False, "error": str(exc)})
            ok = False
    else:
        checks.append(
            {
                "name": "pin_map_no_placeholders",
                "ok": True,
                "note": f"placeholders allowed in env={env!r}; only enforced in production",
            }
        )

    # ---- environment / region documentation -----------------------------
    checks.append(
        {
            "name": "platform_region",
            "ok": True,
            "note": "Supabase project region is EU per Stage 1; verified out-of-band.",
        }
    )

    return BaselineCheckResult(
        ok=ok,
        checks=checks,
        note=(
            "B05·P01 baseline: TLS 1.3 + HSTS enforced by hosting layer; "
            "SPKI pinning + no-plaintext enforced by SecureClient on outbound; "
            "at-rest encryption + bucket privacy verified by DB RPC."
        ),
    )
