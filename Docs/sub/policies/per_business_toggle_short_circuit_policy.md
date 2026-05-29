# per_business_toggle_short_circuit_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The behaviour when OUT_MONTHLY or IN_MONTHLY is disabled in `business_workflow_config`. Per `business_workflow_config_schema`: businesses can toggle workflow types on/off per-business. This policy pins what "disabled" means — short-circuit at the filter stage, audit recording, and behavior of in-flight runs when the toggle changes.

---

## Toggle scope

The two toggles are independent:

- `business_workflow_config.out_monthly_enabled` (boolean, default true)
- `business_workflow_config.in_monthly_enabled` (boolean, default true)

A business with both disabled is unusual — it suggests an entirely external accounting workflow. A business with only IN disabled is more common (e.g., a contractor who only books expenses through this product, invoicing handled separately).

## Short-circuit point

When `out_monthly_enabled = false`:

1. `STATEMENT_UPLOAD_COMPLETED` event still fires per `tool_upload_pipeline_api`
2. The trigger engine per `event_subscription_pipeline_integration` still observes the event
3. The OUT_MONTHLY subscription handler queries `business_workflow_config.out_monthly_enabled`
4. If disabled: subscription writes `trigger_events_processed.outcome = BUSINESS_DISABLED` and skips run creation
5. No OUT_MONTHLY workflow_run is created

Symmetric for IN_MONTHLY.

The short-circuit happens at the trigger-engine level — never at the filter level (the filter only runs inside an existing workflow run; if no run was created, the filter is never invoked).

## In-flight run behavior

If a toggle is flipped from enabled → disabled while a run is in flight:

- The in-flight run **completes** under its starting principal context (per Stage 1 role-change propagation rule, which extends to config changes via the snapshot pattern)
- Per `workflow_run_schema`'s `principal_context_snapshot_json` and `effective_phase_sequence_json`: the run's behavior is fixed at start
- The toggle change applies to NEW runs only

If a toggle is flipped from disabled → enabled mid-period:

- Future statement uploads will trigger OUT_MONTHLY (or IN_MONTHLY) per the new toggle state
- Past statement uploads that were skipped are NOT retroactively processed without operator action
- Per `analytics_refresh_runbook`: operator can manually retrigger via `engine.manual_trigger`

## Audit event shape

```ts
emitAudit("WORKFLOW_TRIGGER_SHORT_CIRCUITED", {
  business_id,
  workflow_type: "OUT_MONTHLY" | "IN_MONTHLY",
  triggering_event_id,
  triggering_event_type: "STATEMENT_UPLOAD_COMPLETED",
  toggle_reason: "BUSINESS_DISABLED",
  toggle_state_at_evaluation: {
    out_monthly_enabled: false,
    in_monthly_enabled: true
  }
});
```

The audit captures the full toggle state at evaluation time so investigations can reconstruct which toggle blocked the run.

## Behavior of paired runs

Per Stage 1: "OUT/IN trigger order: when a single statement upload triggers both, they run in parallel after the shared INGESTION and CLASSIFICATION phases."

The toggle interaction:

| out_monthly_enabled | in_monthly_enabled | Effect |
| --- | --- | --- |
| true | true | Both runs created; paired_run_id linked |
| true | false | Only OUT_MONTHLY created; paired_run_id null |
| false | true | Only IN_MONTHLY created; paired_run_id null |
| false | false | No runs created; INGESTION not triggered either |

When only one side is enabled, the shared phases (INGESTION, CLASSIFICATION) still run — they're triggered by the single workflow run that was created. Shared-phase results are then consumed only by that single side.

## Toggle-change audit

When a user changes a toggle:

```ts
emitAudit("BUSINESS_WORKFLOW_CONFIG_TOGGLED", {
  business_id,
  changed_by_user_id,
  toggle_field: "out_monthly_enabled",
  old_value: true,
  new_value: false,
  reason: "..."                                    // optional user-supplied
});
```

Per `permission_matrix`: `BUSINESS_SETTINGS_EDIT` surface required (Owner / Admin). Mobile rejection per `mobile_write_rejection_endpoints`.

## Investigation surface

Operators can query the trigger_events_processed table per `trigger_events_processed_schema` to see which events were short-circuited:

```sql
SELECT business_id, event_type, outcome, event_observed_at, skipped_reason
FROM trigger_events_processed
WHERE business_id = $business_id
  AND outcome = 'BUSINESS_DISABLED'
  AND event_observed_at >= now() - INTERVAL '30 days'
ORDER BY event_observed_at DESC;
```

The query surfaces missed processing opportunities so operators can decide whether to manually re-trigger via `engine.manual_trigger`.

## Toggle UI

Per `step_up_validity_window_policy` Section "Per-surface overrides": toggling a workflow type may optionally be step-up-required per per-business preference. Default in MVP: no step-up required (Owner/Admin permission already gates this).

## Toggle override audit events

When a toggle is explicitly overridden — meaning set to a value that differs from the platform default (`true`) — the `BUSINESS_WORKFLOW_CONFIG_TOGGLED` event is supplemented with an `override_context` field:

```ts
emitAudit("BUSINESS_WORKFLOW_CONFIG_TOGGLED", {
  business_id,
  changed_by_user_id,
  toggle_field: "out_monthly_enabled",
  old_value: true,
  new_value: false,
  override_context: "OPERATOR_DISABLED",          // "OPERATOR_DISABLED" | "OPERATOR_REENABLED"
  reason: "..."                                    // required when override_context is set
});
```

The `override_context` field distinguishes a routine toggle from a deliberate override. Investigations querying the audit log can filter on this field to identify businesses with non-default configurations.

## Rollback semantics

Undoing a toggle change is a new toggle change — there is no "undo" endpoint. The operator sets the toggle back to the desired value via the same `BUSINESS_SETTINGS_EDIT` surface path. A second `BUSINESS_WORKFLOW_CONFIG_TOGGLED` event is emitted reflecting the reversal.

Workflows that were skipped during the disabled period are NOT automatically retriggerred on rollback. Per the investigation surface section above, operators must use `engine.manual_trigger` to retrigger any runs for statement uploads that were short-circuited during the disabled window.

## Cross-references

- `business_workflow_config_schema` (Block 03) — toggle column declarations
- `trigger_events_processed_schema` — short-circuit recording
- `workflow_run_schema` — principal_context_snapshot, effective_phase_sequence_json
- `audit_log_policies` — `WORKFLOW_*` event family
- `permission_matrix` — BUSINESS_SETTINGS_EDIT surface
- `mobile_write_rejection_endpoints` — settings is desktop-only
- `filter_rerun_semantics_policy` — sibling policy (filter behavior)
- Block 03 Phase 02 — workflow type registry & per-business config
- Block 03 Phase 09 — event-driven workflow trigger
- Block 12 Phase 02 — OUT_MONTHLY workflow type definition
- Block 13 Phase 07 — IN_MONTHLY workflow type definition
