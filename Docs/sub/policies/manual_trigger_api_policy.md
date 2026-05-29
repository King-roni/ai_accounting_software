# manual_trigger_api_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

The HTTP API contract for manually starting workflow runs — the endpoint, request/response schemas, validation order, error codes, rate limiting, and audit. Together with `event_subscription_pipeline_integration` (event-triggered runs) this policy covers the complete set of ways a workflow run can begin in MVP.

The endpoint lives in front of Block 03 Phase 09's manual-trigger handler; this policy pins the contract that Block 16 (dashboard run-start button), Block 12 (OUT workflow re-runs), Block 13 (IN workflow re-runs + adjustments), and external integrations all bind to.

---

## Endpoint signature

```
POST /api/v1/workflow-runs
Content-Type: application/json
Authorization: Bearer <session-token>
```

The endpoint sits behind Supabase Edge Functions per the project's "no direct PostgREST mutations" convention. The Edge Function validates, then dispatches to `engine.manual_trigger_run(input jsonb) RETURNS uuid` (SECURITY DEFINER, runs as `engine.runtime_role`).

## Request schema

```json
{
  "business_id": "uuid",                         // required
  "workflow_type": "OUT_MONTHLY | IN_MONTHLY | OUT_ADJUSTMENT | IN_ADJUSTMENT",
  "period_start": "YYYY-MM-DD",                  // required; first day of the VAT period
  "period_end": "YYYY-MM-DD",                    // required; last day of the VAT period
  "parent_run_id": "uuid | null",                // required for *_ADJUSTMENT; null for monthly
  "trigger_label": "string | null",              // optional; ≤200 chars human-readable rationale ("Reprocess after vendor rule update")
  "client_idempotency_token": "uuid | null"      // optional; per §idempotency below
}
```

Validation rules:
- `business_id` — must reference an existing `business_entities.id` that the caller can access (RLS).
- `workflow_type` — must be a registered type per `workflow_type_phase_optionality`.
- `period_start <= period_end` and both must fall within the configured tenancy retention window (per `data_layer_conventions_policy`).
- `parent_run_id` — MUST be NULL for monthly types; MUST be non-NULL for adjustment types (deeper validation per `out_adjustment_policies` / `in_adjustment_policies` happens in Block 03 Phase 11).
- `trigger_label` — free text, PII-redacted by the audit layer before logging.

Unknown JSON fields are rejected (strict mode) to catch client-side bugs early.

## Response schema

### 201 Created (success)

```json
{
  "run_id": "uuid",                              // the workflow_runs.id of the new row
  "run_sequence_id": "string",                   // human-readable seq (e.g., "2026-04-OUT-042")
  "run_status": "CREATED",                       // initial state per workflow_state_enum
  "current_phase_name": null,                    // not yet entered any phase
  "estimated_completion": "timestamptz | null",  // per estimated_completion_heuristic_policy
  "self_url": "/api/v1/workflow-runs/<uuid>"
}
```

The Edge Function returns immediately after `engine.manual_trigger_run` commits — the first `advanceRun` is enqueued for the trigger engine (per `phase_execution_loop_policy`) and the response does NOT wait for any phase to execute. Clients poll the self-URL or subscribe via Realtime (per `engine_run_progress_api_policy`) for state changes.

### 4xx / 5xx (error)

```json
{
  "error_code": "string",                        // canonical engine code from §error-codes
  "error_message": "string",                     // human-readable, EN/EL per locale
  "details": { ... }                             // optional context object per error_code
}
```

## Validation order

The Edge Function validates in this exact order to produce deterministic error codes:

1. **AUTH** — Bearer token verifies + identifies `auth.uid()`.
2. **REQUEST_SHAPE** — JSON parses + matches the request schema; unknown fields rejected.
3. **PERMISSION** — `can_perform(auth.uid(), 'WORKFLOW_RUN', 'TRIGGER', { business_id, workflow_type })` returns ALLOW or REQUIRE_STEP_UP. DENY returns `PERMISSION_DENIED`.
4. **TENANCY** — `business_id` is in `auth.business_ids_for_session()`.
5. **TYPE_REGISTERED** — `workflow_type` is registered.
6. **PARENT_VALIDATION** — for adjustment types, parent_run_id resolves to a FINALIZED run of the correct type within 6-year window. Delegated to Phase 11 routine.
7. **CONCURRENCY** — per `shared_phase_coordination_policy` + Phase 10: no active (non-terminal) run exists for `(business_id, workflow_type)`. Returns `CONCURRENT_RUN_BLOCKING`.
8. **RATE_LIMIT** — per §rate-limiting; returns `RATE_LIMIT_EXCEEDED`.
9. **IDEMPOTENCY** — if `client_idempotency_token` provided, dedupe against the past 24h of triggers for the same business; returns the prior run_id if hit.
10. **CREATE** — call `transitionRun(null → CREATED)` (per B03·P04). The row is inserted with `trigger_kind = MANUAL`, `triggered_by_user_id = auth.uid()`, principal context snapshot per `principal_context_schema`.
11. **ENQUEUE** — the trigger engine receives the new run for first-advance; returns 201.

Errors at any step short-circuit the remaining steps. The audit event captures which step failed.

## Error codes

| HTTP | error_code | Trigger | Caller action |
| --- | --- | --- | --- |
| `401` | `UNAUTHENTICATED` | Missing / invalid Bearer | Sign in |
| `400` | `INVALID_REQUEST_SHAPE` | JSON parse / schema mismatch / unknown field | Fix client |
| `403` | `PERMISSION_DENIED` | can_perform = DENY | Contact Owner |
| `403` | `STEP_UP_REQUIRED` | can_perform = REQUIRE_STEP_UP | Initiate step-up per `step_up_token_policy` |
| `404` | `BUSINESS_NOT_VISIBLE` | business_id not in caller's session | Verify business |
| `400` | `WORKFLOW_TYPE_UNKNOWN` | type not in registry | Update client |
| `400` | `INVALID_PERIOD_RANGE` | end < start or out of retention window | Fix dates |
| `400` | `PARENT_RUN_REQUIRED` | adjustment without parent_run_id | Provide parent |
| `400` | `PARENT_RUN_INVALID` | parent missing / not FINALIZED / wrong type / out of window | See `parent_run_validation_policy` |
| `409` | `CONCURRENT_RUN_BLOCKING` | Active run exists for (business, type) | Wait or cancel existing run |
| `429` | `RATE_LIMIT_EXCEEDED` | Per §rate-limiting | Retry-After header populated |
| `500` | `INTERNAL_ERROR` | Unexpected engine failure | Retry; if persistent, contact support |

`details` payload is populated per error_code (e.g., `CONCURRENT_RUN_BLOCKING` returns `{ blocking_run_id, blocking_run_status }`).

The `error_code` set is closed; adding a new code is a versioned API change (bump `/api/v1` → `/api/v2`).

## Rate limiting

Two layers:

| Layer | Quota | Window | Headers |
| --- | --- | --- | --- |
| Per user | 10 manual triggers | rolling 60 s | `X-RateLimit-User-Remaining`, `X-RateLimit-User-Reset` |
| Per business | 50 manual triggers | rolling 60 s | `X-RateLimit-Business-Remaining`, `X-RateLimit-Business-Reset` |

When either is exceeded, returns `429 RATE_LIMIT_EXCEEDED` with `Retry-After` set to the lower of the two reset windows.

The buckets live in Postgres (`manual_trigger_rate_limit_buckets` table; refilled lazily on each request); NOT in a separate Redis instance. The 10/60s + 50/60s ceilings are generous for normal use — they catch script-bot misuse, not legitimate operator activity.

Buckets are NOT shared with event-triggered runs — those go through `trigger_events_processed` dedup rather than rate limiting (events come from internal trusted sources and can't realistically flood).

## Idempotency

If the caller supplies `client_idempotency_token` (UUID v4 generated client-side):

1. The Edge Function looks up `manual_trigger_idempotency_keys` (table indexed on (business_id, client_idempotency_token)) for the past 24 h.
2. Hit: returns the original 201 response (same `run_id`); does NOT create a new run.
3. Miss: proceeds with validation; on successful CREATE, records (business_id, token, run_id, created_at).

Idempotency tokens are scoped per (business_id, token); two businesses can use the same token concurrently. Token reuse across the 24 h window is fine — the first request's result is returned on every replay.

Clients SHOULD send a client_idempotency_token on every trigger to make their integration crash-safe. Without one, a client crash after the request was sent but before the response was received could double-trigger a run (the concurrency check in step 7 catches the second one with `CONCURRENT_RUN_BLOCKING`, but the user sees an error rather than a clean success replay).

## Audit emission

```ts
emitAudit("WORKFLOW_RUN_TRIGGERED_MANUAL", {
  workflow_run_id,
  business_id,
  workflow_type,
  period_start, period_end,
  parent_run_id: uuid | null,
  triggered_by_user_id,
  client_idempotency_token: uuid | null,
  trigger_label_redacted: text | null,
  triggered_at
});
```

Severity `LOW`. Domain `WORKFLOW`.

On rejection (any error path):

```ts
emitAudit("WORKFLOW_RUN_TRIGGER_REJECTED", {
  business_id,
  workflow_type,
  attempted_by_user_id,
  error_code,
  rejection_step: text,                          // one of "AUTH" / "PERMISSION" / "CONCURRENCY" / etc.
  rejected_at
});
```

Severity `LOW` for caller-side errors (4xx); `MEDIUM` for `INTERNAL_ERROR`. The audit captures the rejection EVEN when authentication failed — the actor_user_id is NULL but the rejection is recorded so brute-force / probing patterns surface in operational dashboards.

## Mobile considerations

Mobile clients CAN trigger manual runs (this is a workflow-orchestration write but not an operational ledger write; per `mobile_write_rejection_endpoints` policy this surface is mobile-allowed). The request shape and rate limits are identical between desktop and mobile.

## Cross-block contract

- **Block 02 Phase 04** owns `can_perform`; the WORKFLOW_RUN / TRIGGER surface needs registration in `permission_matrix`.
- **Block 03 Phase 04** `transitionRun` is invoked for null → CREATED.
- **Block 03 Phase 06** `engine.advanceRun` is enqueued post-CREATE.
- **Block 03 Phase 10** concurrency check (step 7).
- **Block 03 Phase 11** parent-run validation (step 6) for adjustment types.
- **Block 05 Phase 02** audit emission for both success and rejection events.
- **Block 16 dashboard** consumes this endpoint; "Start run" button POSTs here.

## Cross-references

- `event_subscription_pipeline_integration` — the other ingress (event-triggered)
- `trigger_events_processed_schema` — distinguishes manual vs event in run metadata
- `system_principal_policy` — companion policy covering event-trigger actor identification (this policy is the user-trigger companion)
- `workflow_state_enum` — CREATED status produced
- `phase_execution_loop_policy` — first advanceRun enqueued post-CREATE
- `engine_run_progress_api_policy` — Realtime channel for state updates after trigger
- `estimated_completion_heuristic_policy` — provides initial estimate in response
- `shared_phase_coordination_policy` — concurrency check at step 7
- `principal_context_schema` (BOOK-181) — snapshot captured at CREATE
- `step_up_token_policy` — STEP_UP_REQUIRED 403 path
- `out_adjustment_policies` / `in_adjustment_policies` — parent validation rules referenced by step 6
- `mobile_write_rejection_endpoints` — mobile-allowed flag rationale
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_RUN_TRIGGERED_MANUAL` + `_REJECTED` payloads
- Block 02 — RBAC + permission_matrix
- Block 03 Phase 04 / 06 / 09 / 10 / 11
- Block 16 — dashboard consumer
