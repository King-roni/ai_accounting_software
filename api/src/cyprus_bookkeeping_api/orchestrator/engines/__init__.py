"""Deterministic per-phase decision engines (P0.1 layer 2).

Each module implements one phase's app-tier logic — the decisioning the DB
declares but does not execute — and exposes a handler that plugs into the
orchestrator phase registry. Built fully synced to the live DB + Block specs;
see Docs/engines/CLASSIFY_MATCH_ENGINE_CONTRACT.md.
"""
from __future__ import annotations

from cyprus_bookkeeping_api.orchestrator.engines.classification import (
    handle_classification,
)
from cyprus_bookkeeping_api.orchestrator.engines.income import handle_income_matching
from cyprus_bookkeeping_api.orchestrator.engines.ledger import (
    handle_ledger_preparation,
)
from cyprus_bookkeeping_api.orchestrator.engines.matching import handle_matching

__all__ = [
    "handle_classification",
    "handle_matching",
    "handle_ledger_preparation",
    "handle_income_matching",
]
