# system_principal_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 05 — Security & Audit, 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The contract for identifying the "actor" on event-triggered workflow runs, watchdog actions, scheduled retries, and other engine-initiated mutations where no human user is involved. Defines the SYSTEM principal kind, how it differs from the USER principal in manual triggers, how it appears in audit events, and how it interacts with RLS + permission checks.

This policy is the companion to `manual_trigger_api_policy` (which covers USER-initiated runs) and `principal_context_schema` (BOOK-181, which defines the snapshot shape both kinds share).

---

## The two principal kinds

Per `principal_context_schema` (BOOK-181), every action in the engine has exactly one principal kind:

| Kind | Captured on | Example |
| --- | --- | --- |
| `USER` | Manual trigger, user action on review issue, user-initiated state transition | Owner clicks "Start OUT run for April"; Bookkeeper resolves a review issue |
| `SYSTEM` | Event-triggered run, watchdog stall recovery, schedule retry, crash-recovery sweep | Statement-upload event triggers an OUT_MONTHLY run; watchdog auto-resumes a stalled run |

The `audit.audit_events.actor_kind` column carries the discriminator. The `audit_events_actor_kind_chk` constraint enforces XOR — USER+actor_user_id is non-null XOR SYSTEM+actor_system is non-null.

## SYSTEM principal anatomy

For SYSTEM actions, the engine populates the `actor_system` jsonb column with:

```ts
{
  system_kind: SystemKind,                          // closed enum below
  triggered_by_event_id: uuid | null,               // the audit_log event_id that triggered this action
  triggered_by_event_type: text | null,             // e.g., "STATEMENT_UPLOAD_COMPLETED"
  upstream_actor: jsonb | null,                     // who/what *caused* the event (e.g., the user who uploaded the statement)
  worker_id: text | null,                           // the process-id / pod-id that performed the action
  policy_ref: text | null                           // e.g., "crash_recovery_policy" — which policy authorised the action
}
```

`upstream_actor` is the key transparency mechanism. When a statement upload event fires an OUT_MONTHLY run, the run's `actor_system.upstream_actor` carries the user who uploaded the statement. The chain `human → audit event → engine action` is reconstructable end-to-end via `workflow_run_audit_trail_reconstruction` (BOOK-249).

## SystemKind enum (closed)

```sql
CREATE TYPE system_kind_enum AS ENUM (
  'TRIGGER_ENGINE',           -- event-triggered workflow runs per event_subscription_pipeline_integration
  'WATCHDOG',                 -- stall detection + auto-resume per resumability_policy
  'CRASH_RECOVERY',           -- fleet-level recovery sweep per crash_recovery_policy
  'RETRY_SCHEDULER',          -- backoff retries per retry_policy
  'GATE_FORCER',              -- side-phase loop forced-gate per gate_throws_semantics_policy
  'ESTIMATOR',                -- estimated_completion recompute per estimated_completion_heuristic_policy
  'AUDIT_INTEGRITY',          -- hash chain repair / re-verification per archive_tamper_detection_policy
  'BACKGROUND_GC'             -- TTL cleanup of bulk_preview_tokens, session_progress, etc.
);
```

Each value pairs with a specific policy in the cross-references; the `policy_ref` jsonb field documents that linkage. Adding a new SystemKind is a closed-enum migration (per the project's "ALTER TYPE ADD VALUE deferred visibility" gotcha — split into two migrations when used in same migration).

## How event-triggered runs identify their actor

When a STATEMENT_UPLOAD_COMPLETED event triggers an OUT_MONTHLY + IN_MONTHLY pair (per phase doc B03·P09):

```ts
// Subscription handler runs:
const triggerEventRow = audit_log.find(event_id = $event_id);
const upstreamActor = triggerEventRow.actor_user_id !== null
  ? { kind: 'USER', user_id: triggerEventRow.actor_user_id }
  : triggerEventRow.actor_system;   // event was system-emitted (chain-of-systems case)

createWorkflowRun({
  ...,
  trigger_kind: 'EVENT',
  trigger_event_id: $event_id,
  principal_context_snapshot_json: {
    actor_kind: 'SYSTEM',
    actor_system: {
      system_kind: 'TRIGGER_ENGINE',
      triggered_by_event_id: $event_id,
      triggered_by_event_type: 'STATEMENT_UPLOAD_COMPLETED',
      upstream_actor: upstreamActor,            // the user who uploaded the statement
      worker_id: process.env.WORKER_ID,
      policy_ref: 'event_subscription_pipeline_integration'
    }
  }
});
```

The run's principal context is `SYSTEM`. The `upstream_actor` field carries the user. Subsequent phase actions executed by the engine inherit the SYSTEM principal but can resolve `upstream_actor` for visibility — for example, the Dashboard's "Run started by ..." label renders `upstream_actor.user_id`'s display name (NOT "System").

This is intentional: from a product-UX perspective the run was "started by Maria" (because Maria uploaded the statement). From an audit-trace perspective the engine started it (no human clicked "Start run"). Both perspectives are preserved.

## How this differs from USER principal in manual triggers

| Aspect | USER (manual trigger) | SYSTEM (event-triggered) |
| --- | --- | --- |
| `actor_kind` | `USER` | `SYSTEM` |
| `actor_user_id` | non-null | NULL |
| `actor_system` | NULL | populated |
| `auth.uid()` context | the user's session | NO session (engine runs without auth.uid) |
| RLS evaluation | Standard per-user RLS | SECURITY DEFINER bypass to `engine.runtime_role` |
| `can_perform` check | Required (returns ALLOW / DENY / REQUIRE_STEP_UP) | NOT invoked — SYSTEM is pre-authorised per policy_ref |
| Step-up requirement | May be required for sensitive actions | NEVER (no human to step up) |
| Dashboard label | "Started by Maria Smith" | "Started by Maria Smith (auto)" — uses upstream_actor for the name + "(auto)" suffix |
| Bug-report attribution | The user is the reporter | The system is the actor; upstream_actor identifies the human cause |

The key invariant: **SYSTEM actions never block on user input**. A watchdog cannot ask "are you sure?"; a crash-recovery cannot prompt for re-auth. SYSTEM is for actions the engine is authorised to perform autonomously by the policy at `policy_ref`.

## Authorisation — SYSTEM bypass conditions

SYSTEM actions DO NOT invoke `can_perform`. The authorisation comes from the originating policy:

- `event_subscription_pipeline_integration` authorises TRIGGER_ENGINE — but only for events the subscription is registered to handle.
- `resumability_policy` authorises WATCHDOG — but only on stalled runs that meet the 30-min criterion.
- `crash_recovery_policy` authorises CRASH_RECOVERY — but only during a worker-init sweep (in-process flag enforces).
- etc.

Each policy is the binding contract. A SYSTEM action with a `policy_ref` that doesn't match the action's authorisation contract is a CRITICAL ops alert — emits `SYSTEM_PRINCIPAL_POLICY_MISMATCH` (HIGH) and aborts the action.

CI lint enforces: every SYSTEM action site in code MUST set `policy_ref` to one of the registered policy names; missing or non-canonical values fail boot.

## RLS implications

The engine runs SYSTEM actions through SECURITY DEFINER RPCs that execute as `engine.runtime_role`. This role has BYPASSRLS = false BUT the RPC's body is trusted — it explicitly scopes every read/write by `business_id` from the action's context.

The `actor_system` jsonb is NOT consulted by RLS policies. RLS only knows USER vs SYSTEM via `actor_kind`. For SYSTEM, the RLS USING clauses defer to the calling RPC's explicit business_id scoping.

This means: a bug in a SYSTEM RPC that fails to scope by business_id could cross tenant boundaries. The CI lint requires every SYSTEM RPC to use the canonical `_scope_to_business(business_id)` helper that validates the parameter against `auth.business_ids_for_session()` (when relevant) or against the upstream event's business_id otherwise.

## Audit visibility — actor field discrimination

When rendering an audit-trail UI (Block 16 / Block 14):

```
IF actor_kind = USER:
  Render: "<user.display_name> · <user.email>"
ELSE IF actor_kind = SYSTEM:
  IF upstream_actor.kind = USER:
    Render: "<upstream_user.display_name> (via {system_kind})"
  ELSE:
    Render: "{system_kind}"  -- e.g., "Watchdog", "Crash Recovery"
```

The "(via {system_kind})" suffix is the visibility cue the user needs to understand "I didn't click anything but my upload caused this." Tooltip hovering on the suffix shows the full SystemKind + policy_ref.

`v_audit_feed_personalized` (B05·P03 + B02 per BOOK-241) uses this rendering to show users only events they caused — events with `upstream_actor.kind = USER && upstream_actor.user_id = me` are included in the user's personal feed.

## Audit shape for SYSTEM-initiated audit events

Every SYSTEM-initiated audit event includes:

```ts
{
  actor_kind: 'SYSTEM',
  actor_user_id: null,
  actor_system: {
    system_kind: '<one of 8 enum values>',
    triggered_by_event_id: uuid | null,
    triggered_by_event_type: text | null,
    upstream_actor: { kind, user_id?, ... } | null,
    worker_id: text,
    policy_ref: text
  },
  ...rest of standard audit payload
}
```

The audit emission helper `audit.emit_audit_as_system(...)` is a thin wrapper that prevents accidentally setting `actor_user_id` from a SYSTEM context. Direct emission with `actor_kind=SYSTEM` but `actor_user_id` non-null fails the `audit_events_actor_kind_chk` constraint.

## Audit policy ref drift detection

A daily ops job verifies that every SYSTEM-initiated event in the past 24h has a `policy_ref` value present in a closed registered set (kept in `system_principal_policy_registry` table maintained by Block 03 P09 boot logic). Drift fires `SYSTEM_PRINCIPAL_POLICY_REGISTRY_DRIFT` (HIGH) at the daily aggregate level.

This catches code that emits SYSTEM events with novel policy_refs that haven't been registered — typically a sign that a new SYSTEM action class needs to be added to the SystemKind enum + this policy.

## Cross-block contract

- **Block 02** owns `auth.business_ids_for_session()` + `can_perform`; SYSTEM bypasses can_perform but still reads the helper for explicit scoping checks.
- **Block 03 Phase 09** owns the trigger-engine SYSTEM kind initialisation.
- **Block 05 Phase 02** owns the audit-emission helpers; `audit.emit_audit_as_system` is canonical.
- **Block 05 Phase 03** owns the personal-feed projection that consumes `upstream_actor`.
- **Block 14** review-queue cards use the actor rendering rule for action attribution.
- **Block 16 dashboard** uses the "Started by X (auto)" rendering rule.

## Cross-references

- `principal_context_schema` (BOOK-181) — canonical principal_context_snapshot_json shape; this policy specialises the SYSTEM branch
- `manual_trigger_api_policy` — USER-branch companion
- `event_subscription_pipeline_integration` — TRIGGER_ENGINE authorisation contract
- `resumability_policy` — WATCHDOG authorisation
- `crash_recovery_policy` — CRASH_RECOVERY authorisation
- `retry_policy` — RETRY_SCHEDULER authorisation
- `gate_throws_semantics_policy` — GATE_FORCER authorisation
- `estimated_completion_heuristic_policy` — ESTIMATOR authorisation
- `archive_tamper_detection_policy` — AUDIT_INTEGRITY authorisation
- `workflow_run_audit_trail_reconstruction` (BOOK-249) — `upstream_actor` chain reconstruction
- `personal_audit_feed_policy` (BOOK-241) — personal feed consumes upstream_actor
- `audit_event_payload_schemas` (Stage-6 catalog) — `actor_system` field + `SYSTEM_PRINCIPAL_POLICY_*` events
- `audit_events_actor_kind_chk` — XOR constraint enforcing USER vs SYSTEM exclusivity
- Block 02 — RBAC + tenancy helpers
- Block 03 Phase 09 — host phase
- Block 05 Phase 02 / 03 — audit emission + personal feed
- Block 14 / 16 — actor rendering consumers
