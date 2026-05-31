"""Resolve the actor user id the engine passes to actor-bound RPCs.

``transition_run`` requires ``p_actor_user_id NOT NULL`` even for auto
transitions (start / await_approval_auto) — it has no permission check but
emits the audit row as USER. So the engine must supply *some* real public.users
id. Resolution order:

  1. ``workflow_runs.started_by``            — present on MANUAL runs.
  2. ``principal_snapshot.actor_user_id``    — set by the event-consume path
     when the uploader is known.
  3. ``settings.worker_system_actor_user_id``— configured fallback for pure
     SYSTEM event runs with no human in the loop.

Phase-engine RPCs (enter_phase / complete_phase / record_tool_invocation) emit
SYSTEM audit and take no actor, so they are unaffected.
"""
from __future__ import annotations

from typing import Any

from cyprus_bookkeeping_api.config import Settings


class ActorResolutionError(RuntimeError):
    """No actor user id could be resolved for a run that needs a status change."""


def resolve_actor(run: dict[str, Any], settings: Settings) -> str | None:
    started_by = run.get("started_by")
    if started_by:
        return str(started_by)

    snapshot = run.get("principal_snapshot") or {}
    if isinstance(snapshot, dict):
        actor = snapshot.get("actor_user_id")
        if actor:
            return str(actor)

    fallback = (settings.worker_system_actor_user_id or "").strip()
    if fallback:
        return fallback

    return None


def require_actor(run: dict[str, Any], settings: Settings) -> str:
    actor = resolve_actor(run, settings)
    if not actor:
        raise ActorResolutionError(
            f"run {run.get('id')} has no started_by / principal actor and "
            "worker_system_actor_user_id is unset; cannot perform status change"
        )
    return actor
