"""VIES verification runner — validate clients' EU VAT numbers + cache results.

Polls ``clients_needing_vies_check`` (EU, format-valid, active, never-checked or
stale), calls the EU VIES service per (country, vat), and records the verdict via
``record_vies_check``. A VIES outage for a number is skipped (retried next pass),
never cached as invalid.
"""
from __future__ import annotations

import logging
from typing import Any

from cyprus_bookkeeping_api.config import Settings
from cyprus_bookkeeping_api.orchestrator.rpc import Gateway
from cyprus_bookkeeping_api.vies.client import ViesPort, ViesUnavailable, build_vies_client

logger = logging.getLogger(__name__)


def verify_pending_vies(
    gateway: Gateway, settings: Settings, *, vies: ViesPort | None = None
) -> dict[str, Any]:
    """Verify a bounded batch of clients' VAT numbers against EU VIES."""
    vies = vies or build_vies_client(settings)
    pending = gateway.rpc(
        "clients_needing_vies_check",
        {"p_limit": settings.worker_vies_batch_size, "p_recheck_days": settings.vies_recheck_days},
    ) or []

    checked: list[str] = []
    unavailable: list[str] = []

    for row in pending:
        country = row["country"]
        vat_number = row["vat_number"]
        key = f"{country}:{vat_number}"
        try:
            result = vies.check(country, vat_number)
        except ViesUnavailable:
            logger.warning("VIES unavailable for %s; will retry", key)
            unavailable.append(key)
            continue
        gateway.rpc(
            "record_vies_check",
            {
                "p_country": result.country,
                "p_vat_number": result.vat_number,
                "p_valid": result.valid,
                "p_registered_name": result.name,
                "p_registered_address": result.address,
                "p_request_identifier": result.request_identifier,
            },
        )
        checked.append(key)

    if checked or unavailable:
        logger.info("vies: checked=%d unavailable=%d", len(checked), len(unavailable))
    return {"checked": checked, "unavailable": unavailable}
