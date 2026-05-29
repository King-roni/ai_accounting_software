# Tool: classification.apply

**Block:** Classification  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`classification.apply` writes the accepted classification decision back to a transaction. It is called either by the auto-approval path (when AI confidence exceeds the configured threshold) or by the review queue path (when a human reviewer has selected or overridden a category). In both cases this tool is the single write path for classification decisions — nothing else writes `category_id` directly to a transaction in the CLASSIFICATION phase.

When the human overrides an AI suggestion, the tool additionally writes an entry to `classification_override_log` and triggers vendor memory update so the override is learned for future transactions.

---

## Tool Signature

**Name:** `classification.apply`  
**Namespace:** `classification`  
**Action:** `apply`

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `run_id` | UUID | Yes | FK to `workflow_runs(id)`. Run must be RUNNING in phase CLASSIFICATION. |
| `transaction_id` | UUID | Yes | FK to `transactions(id)`. Transaction must be in the CLASSIFICATION phase and not yet classified. |
| `category_id` | UUID | Yes | FK to `chart_of_accounts(id)`. The accepted category. Must be active and belong to the transaction's `business_id`. |
| `confidence_source` | string enum | Yes | `'AI'`, `'RULE'`, or `'MANUAL'`. |
| `override_reason` | TEXT | Conditional | Required when `confidence_source = 'MANUAL'`. Max 500 characters. |

### Outputs

| Field | Type | Description |
|---|---|---|
| `transaction` | object | Updated transaction record snapshot: `id`, `category_id`, `confidence_source`, `classification_at`. |
| `override_log_id` | UUID or null | ID of the `classification_override_log` row created. `null` when `confidence_source != 'MANUAL'`. |
| `vendor_memory_updated` | boolean | `true` if a vendor memory write was triggered. |
| `was_noop` | boolean | `true` if the same `category_id` was already applied (idempotent re-apply). |

---

## Preconditions

1. Run phase must be `CLASSIFICATION` and run status must be `RUNNING`.
2. Transaction must have `phase = 'CLASSIFICATION'` and `category_id IS NULL` (or already equal to the incoming `category_id` — see idempotency).
3. `category_id` must reference an active row in `chart_of_accounts` scoped to the transaction's `business_id`.
4. If `confidence_source = 'MANUAL'`, `override_reason` must be non-empty after trimming whitespace.

Violation of preconditions 1 or 2 returns a BLOCKING error and writes nothing.

---

## Classification Write

```sql
UPDATE transactions
SET    category_id         = :category_id,
       confidence_source   = :confidence_source,
       classification_at   = now(),
       phase               = 'CLASSIFIED'
WHERE  id     = :transaction_id
  AND  run_id = :run_id;
```

The phase transition from `CLASSIFICATION` to `CLASSIFIED` is performed atomically in the same statement to prevent a race condition where two callers attempt to classify the same transaction.

---

## Override Log

When `confidence_source = 'MANUAL'`, an entry is written to `classification_override_log`:

```sql
INSERT INTO classification_override_log (
  id,
  run_id,
  transaction_id,
  original_category_id,
  applied_category_id,
  override_reason,
  overridden_by,
  overridden_at
) VALUES (
  gen_uuid_v7(),
  :run_id,
  :transaction_id,
  :prior_ai_suggestion_category_id,
  :category_id,
  :override_reason,
  :current_user_id,
  now()
);
```

`original_category_id` is the AI-suggested category stored on the transaction prior to this call. If no AI suggestion was present (the transaction was never sent to AI classification), `original_category_id` is `NULL`.

Reference: `classification_override_log_schema.md`.

---

## Vendor Memory Update

A vendor memory write is triggered after the transaction write whenever `confidence_source = 'MANUAL'`. The write is fire-and-forget (async); it does not block the tool response.

The signal sent to vendor memory:

```jsonc
{
  "business_id":   "<uuid>",
  "vendor_name":   "<transaction.counterparty_name>",
  "category_id":   "<applied category_id>",
  "signal_weight": 1.0
}
```

This calls `tool_vendor_memory_writeback.md` internally.

When `confidence_source = 'AI'` or `'RULE'`, vendor memory is NOT updated. Only human-confirmed decisions are fed back as learning signals to avoid reinforcing AI errors.

---

## Idempotency

Re-applying the same `category_id` to a transaction that is already in phase `CLASSIFIED` with the same `category_id`:

- Returns the existing transaction record unchanged.
- Sets `was_noop = true` in the response.
- Does NOT create a duplicate `classification_override_log` entry.
- Does NOT emit a duplicate audit event.
- Does NOT trigger a second vendor memory write.

Re-applying a DIFFERENT `category_id` to an already-classified transaction requires `confidence_source = 'MANUAL'` with a new `override_reason`. This replaces the prior classification and creates a new `classification_override_log` entry.

---

## Audit Events

| Event | Severity | Emitted when |
|---|---|---|
| `CLASSIFICATION_APPLIED` | LOW | Classification written; `was_noop = false` |
| `CLASSIFICATION_MANUAL_OVERRIDE_SET` | MEDIUM | `confidence_source = 'MANUAL'` and prior AI suggestion existed |

`CLASSIFICATION_APPLIED` payload:

```jsonc
{
  "run_id":            "<uuid>",
  "transaction_id":    "<uuid>",
  "category_id":       "<uuid>",
  "confidence_source": "AI",
  "classification_at": "2026-05-17T10:00:00Z"
}
```

`CLASSIFICATION_MANUAL_OVERRIDE_SET` payload extends the above with:

```jsonc
{
  "original_category_id": "<uuid or null>",
  "override_reason":      "Mapped to owner drawings, not operating expenses.",
  "override_log_id":      "<uuid>"
}
```

---

## Error Handling

| Condition | Error code | Severity |
|---|---|---|
| Run not in CLASSIFICATION phase | `RUN_WRONG_PHASE` | BLOCKING |
| Run not RUNNING | `RUN_NOT_RUNNING` | BLOCKING |
| Transaction not in CLASSIFICATION phase | `TRANSACTION_WRONG_PHASE` | BLOCKING |
| `category_id` not active or wrong business | `CATEGORY_INVALID` | BLOCKING |
| `override_reason` missing when MANUAL | `OVERRIDE_REASON_REQUIRED` | BLOCKING |
| Concurrent write detected (row locked) | `CONCURRENT_CLASSIFICATION` | HIGH — retry |

---

## Mobile

`classification.apply` is classified as `WRITES_RUN_STATE | WRITES_AUDIT`.

On mobile clients:

- The reviewer selects a category from a searchable dropdown in the review card UI. Submitting the form calls `classification.apply` with `confidence_source = 'MANUAL'` and the `override_reason` field (required, minimum 10 characters on mobile form validation — server enforces the actual non-empty rule).
- Auto-approval calls via the AI path do not surface on mobile in real time; results are batched and shown in the run progress card as classified-count increments.
- If a `CONCURRENT_CLASSIFICATION` error is returned, the mobile client refreshes the transaction card to show the already-applied classification and dismisses the form with an informational message.
- Step-up authentication is NOT required for `classification.apply` in the default configuration. If a business has enabled `require_step_up_for_manual_classification` in `business_settings`, a step-up token must be obtained via `auth.step_up_request` before calling this tool.

---

## Related Documents

- `tool_ai_classify.md` — produces AI suggestions consumed by this tool
- `tool_classification_run.md` — orchestrates the classification phase
- `classification_override_log_schema.md` — DDL for the override log
- `classification_output_schema.md` — classification result shape
- `tool_vendor_memory_writeback.md` — vendor memory write triggered by MANUAL source
- `chart_of_accounts_schema.md` — category FK target
- `transactions_schema.md` — transaction columns written by this tool
- `emit_audit_api.md` — audit emission API
- `classification_confidence_drop_runbook.md` — escalation path if override rate spikes
