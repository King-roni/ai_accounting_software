"""EU VIES VAT validation (R7.6).

Replaces format-only VAT validation with real EU VIES lookups against the public
REST service (no key). The worker verifies clients' EU VAT numbers and caches the
verdict (``vies_checks``); client management + the reverse-charge/VIES ledger flag
read the cache.
"""
from cyprus_bookkeeping_api.vies.client import (
    ViesClient,
    ViesPort,
    ViesResult,
    ViesUnavailable,
    build_vies_client,
)

__all__ = ["ViesClient", "ViesPort", "ViesResult", "ViesUnavailable", "build_vies_client"]
