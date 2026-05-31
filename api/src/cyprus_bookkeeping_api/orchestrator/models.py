"""Value objects + enum mirrors for the orchestrator.

Enum *labels* mirror the Postgres enums exactly (verified against the live DB):
  workflow_run_status_enum, phase_state_status_enum, gate_decision_enum,
  gate_kind_enum, tool_invocation_status_enum, workflow_type_enum.
The DB is the source of truth; these exist only for readable, typo-proof code.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class RunStatus(str, Enum):
    CREATED = "CREATED"
    RUNNING = "RUNNING"
    PAUSED = "PAUSED"
    REVIEW_HOLD = "REVIEW_HOLD"
    AWAITING_APPROVAL = "AWAITING_APPROVAL"
    FINALIZING = "FINALIZING"
    FINALIZED = "FINALIZED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"
    COMPENSATING = "COMPENSATING"
    ABORTED = "ABORTED"


TERMINAL_STATUSES: frozenset[str] = frozenset(
    {RunStatus.FINALIZED, RunStatus.ABORTED, RunStatus.FAILED, RunStatus.CANCELLED}
)
# Statuses the worker actively advances. Everything else (REVIEW_HOLD waiting on
# a human, AWAITING_APPROVAL waiting on user approval, PAUSED, terminal) is left
# alone — the worker never force-advances a run past a human gate.
DRIVABLE_STATUSES: frozenset[str] = frozenset({RunStatus.CREATED, RunStatus.RUNNING})


class GateDecision(str, Enum):
    ADVANCE = "ADVANCE"
    HOLD = "HOLD"
    ROUTE_TO_SIDE_PHASE = "ROUTE_TO_SIDE_PHASE"


class GateKind(str, Enum):
    ENTRY = "ENTRY"
    EXIT = "EXIT"


class ToolStatus(str, Enum):
    PENDING = "PENDING"
    SUCCESS = "SUCCESS"
    RETRY_PENDING = "RETRY_PENDING"
    FAILED = "FAILED"
    SKIPPED = "SKIPPED"


class OutcomeKind(str, Enum):
    COMPLETE = "COMPLETE"          # phase did its work; run exit gates then complete_phase
    SKIP = "SKIP"                  # optional phase intentionally skipped (then completed)
    HOLD = "HOLD"                  # phase must pause for a human → REVIEW_HOLD
    AWAIT_APPROVAL = "AWAIT_APPROVAL"  # sentinel: stop the loop, run → AWAITING_APPROVAL


# Phase whose arrival means "all automated work is done; wait for user approval".
FINALIZATION_PHASE = "FINALIZATION"


@dataclass(frozen=True)
class RunContext:
    """Immutable per-run context threaded through gate + phase evaluation."""

    run_id: str
    organization_id: str
    business_id: str
    workflow_type: str
    period_start: str | None
    period_end: str | None
    actor_user_id: str | None
    principal_snapshot: dict[str, Any]
    trigger_kind: str | None
    trigger_event_id: str | None


@dataclass(frozen=True)
class PhaseOutcome:
    """Result a phase handler returns to the engine."""

    kind: OutcomeKind
    reason: str | None = None
    detail: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def complete(cls, **detail: Any) -> "PhaseOutcome":
        return cls(OutcomeKind.COMPLETE, detail=detail)

    @classmethod
    def skip(cls, reason: str, **detail: Any) -> "PhaseOutcome":
        return cls(OutcomeKind.SKIP, reason=reason, detail=detail)

    @classmethod
    def hold(cls, reason: str, **detail: Any) -> "PhaseOutcome":
        return cls(OutcomeKind.HOLD, reason=reason, detail=detail)

    @classmethod
    def await_approval(cls, **detail: Any) -> "PhaseOutcome":
        return cls(OutcomeKind.AWAIT_APPROVAL, detail=detail)


@dataclass(frozen=True)
class GateResult:
    hold: bool
    gate_name: str | None = None
    reason: str | None = None


def first_row(value: Any) -> dict[str, Any] | None:
    """Normalise a PostgREST RPC result that may be a row dict or a 1-elem list."""
    if isinstance(value, list):
        return value[0] if value else None
    if isinstance(value, dict):
        return value
    return None
