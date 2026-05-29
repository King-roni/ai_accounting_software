# Resolution Action Payload Schema

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

Per-action JSON payload shapes for all 13 resolution actions in the `resolution_action_enum` vocabulary. Each entry specifies the action name, applicable issue groups, required permission surface, exact payload schema, and key constraints. All write actions are rejected on mobile clients per the Stage 1 mobile-write-rejection policy (`mobile_write_rejection_endpoints`). Payloads are stored in `review_issues.resolution_action_payload` (JSONB) and in the per-action `review_resolution_actions` table after a successful resolution.

---

## Shared constraints (apply to all 13 actions)

- **Authentication:** the caller's session must be authenticated with a non-expired token per Block 02 Phase 06.
- **Permission surface check:** `auth.canPerform(actor, surface, business_id)` must return `true` before any payload is validated.
- **Mobile rejection:** HTTP 405 is returned for all write actions when `client_form_factor = MOBILE`. The action endpoint is listed in `mobile_write_rejection_endpoints`.
- **Issue status:** actions may only be applied to issues with `status = OPEN` (or `SNOOZED` for `snooze` and `reassign`). Applying to a closed issue is a no-op and emits `REVIEW_RESOLUTION_REJECTED_NOOP`.
- **Idempotency key:** callers should supply a `idempotency_key` (UUID v7, client-generated) in the request envelope. Duplicate keys within 24h return the prior result without re-applying.

---

## The 13 action payload schemas

### 1. `mark_resolved`

**Applicable groups:** All 5 issue groups
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Sets `review_issues.status = RESOLVED`.

```typescript
interface MarkResolvedPayload {
  issue_id: string;        // UUID v7 — the review_issues.review_issue_id
  resolution_note?: string; // Optional free-text; stored in review_issues.resolution_note
}
```

Constraints: `issue_id` must resolve to an `OPEN` issue in the actor's business. No minimum note length.

---

### 2. `confirm_match`

**Applicable groups:** `Needs Confirmation`, `Possible Wrong Match`
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Transitions `match_records.match_status = MATCHED_CONFIRMED`; emits `MATCHING_USER_CONFIRMED`.

```typescript
interface ConfirmMatchPayload {
  match_record_id: string; // UUID v7 — the match_records row to confirm
  resolution_note?: string;
}
```

Constraints: `match_record_id` must belong to the same `business_id` and the same `workflow_run_id` as the issue. The match record must not already be in a terminal status (`MATCHED_CONFIRMED`, `REJECTED_MATCH`).

---

### 3. `reject_match`

**Applicable groups:** `Possible Wrong Match`, `Needs Confirmation`
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Transitions `match_records.match_status = REJECTED_MATCH`; writes rejection memory (Block 10 Phase 06). The `(transaction_id, document_id)` pair will never be re-suggested in future runs. Emits `MATCHING_USER_REJECTED`.

```typescript
interface RejectMatchPayload {
  match_record_id: string;    // UUID v7
  rejection_reason: string;   // Required — minimum 5 characters
  resolution_note?: string;
}
```

Constraints: `rejection_reason` is mandatory and stored in `match_rejection_memory.reason`. Minimum 5 characters enforced server-side.

---

### 4. `reclassify_transaction`

**Applicable groups:** `Needs Confirmation`, `Possible Wrong Match`
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Updates `transactions.transaction_type`; replays Block 11 ledger preparation for the affected entry; if the new type changes the workflow filter membership (OUT vs IN), Block 12/13 filter re-runs. Emits `CLASSIFICATION_USER_RECLASSIFIED`.

```typescript
interface ReclassifyTransactionPayload {
  transaction_id: string;       // UUID v7
  new_transaction_type: TransactionType; // value from transaction_type_enum
  resolution_note?: string;
}
```

Constraints: `new_transaction_type` must differ from the current value. The transaction must belong to the issue's `workflow_run_id`. Reclassification to `UNKNOWN` is blocked (would immediately re-raise a `BLOCKING` issue).

---

### 5. `accept_classification`

**Applicable groups:** `Needs Confirmation`
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Sets `transactions.classification_status = CONFIRMED`. Emits `CLASSIFICATION_USER_CONFIRMED`. Vendor memory increments per Block 08 Phase 03.

```typescript
interface AcceptClassificationPayload {
  transaction_id: string; // UUID v7
  resolution_note?: string;
}
```

Constraints: transaction's current `classification_status` must be `NEEDS_CONFIRMATION`.

---

### 6. `mark_as_no_invoice_available`

**Applicable groups:** `Missing Documents` — OUT-side only
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Invokes Block 12 Phase 06's exception path; sets `transactions.effective_match_status = EXCEPTION_DOCUMENTED`. Emits `OUT_WORKFLOW_DOCUMENT_EXCEPTION_RECORDED`. This action is excluded from the `allowed_resolution_actions` of any IN-side issue type.

```typescript
interface MarkNoInvoiceAvailablePayload {
  transaction_id: string; // UUID v7
  reason: string;         // Required — minimum 10 characters
  resolution_note?: string;
}
```

Constraints: `reason` is mandatory (minimum 10 characters). The transaction's effective direction must be `OUT`. Accountants cannot invoke this action (per `resolution_action_enum` role matrix — reassign back to Bookkeeper first).

---

### 7. `propose_alternative_match`

**Applicable groups:** `Possible Wrong Match`
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Combines a reject-old + confirm-new in a single atomic transaction. Writes rejection memory for the old pair. Emits `MATCHING_USER_ALTERNATIVE_PROPOSED`.

```typescript
interface ProposeAlternativeMatchPayload {
  transaction_id: string;          // UUID v7 — the transaction
  reject_match_record_id: string;  // UUID v7 — match to reject
  confirm_match_record_id: string; // UUID v7 — match to confirm instead
  rejection_reason: string;        // Required — minimum 5 characters
  resolution_note?: string;
}
```

Constraints: `reject_match_record_id` and `confirm_match_record_id` must belong to the same `business_id`. Both match records must reference the same `transaction_id`.

---

### 8. `snooze`

**Applicable groups:** All (severity must be `LOW` or `MEDIUM` only — `HIGH` and `BLOCKING` cannot be snoozed)
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Sets `review_issues.status = SNOOZED`; carries the issue forward to the next run. Auto-clears if severity escalates on rescan. Emits `REVIEW_ISSUE_SNOOZED`.

```typescript
interface SnoozePayload {
  issue_id: string;      // UUID v7
  snooze_reason: string; // Required — minimum 5 characters
}
```

Constraints: `severity` of the target issue must be `LOW` or `MEDIUM` at time of action. `HIGH` and `BLOCKING` issues are rejected with `REVIEW_RESOLUTION_REJECTED_SNOOZE_BLOCKED`. Accountants may only snooze `LOW`-severity issues; Bookkeeper and above may snooze `MEDIUM` as well (per `severity_enum` snooze eligibility table).

---

### 9. `reassign`

**Applicable groups:** All 5 issue groups
**Permission surface:** `REVIEW_ASSIGN`
**Effect:** Sets `review_issues.assigned_to_user_id`; notifies assignee via `transactional_email_service_integration`. Emits `REVIEW_ISSUE_REASSIGNED`.

```typescript
interface ReassignPayload {
  issue_id: string;          // UUID v7
  assignee_user_id: string;  // UUID v7 — must hold an active role on the business
  resolution_note?: string;
}
```

Constraints: `assignee_user_id` must be an active member of the same `business_id`. Reassignment to self is permitted but emits a warning flag in the audit payload. `REVIEW_ASSIGN` surface is Owner/Admin only per `permission_matrix`.

---

### 10. `dismiss_with_reason`

**Applicable groups:** All (severity-restricted — `BLOCKING` cannot be dismissed by any role)
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Sets `review_issues.status = DISMISSED`. The issue is treated as a documented exception by downstream gates. Emits `REVIEW_ISSUE_DISMISSED` with `severity`, `reason`, `actor_role`, and `step_up_token_id` (for `HIGH` dismissals).

```typescript
interface DismissWithReasonPayload {
  issue_id: string;         // UUID v7
  resolution_note: string;  // Required for ALL dismissals — minimum 10 characters
}
```

Constraints (per `severity_enum` dismissal matrix):
- `BLOCKING` → rejected for all roles; emits `REVIEW_RESOLUTION_REJECTED_BLOCKING_DISMISSAL`.
- `HIGH` → Owner/Admin only; step-up token required.
- `MEDIUM` → Owner/Admin/Bookkeeper; no step-up.
- `LOW` → Owner/Admin/Bookkeeper/Accountant; no step-up.

---

### 11. `send_to_my_inbox`

**Applicable groups:** All 5 issue groups
**Permission surface:** `REVIEW_QUEUE_RESOLVE` (Reviewer may also call this per `resolution_action_enum` matrix)
**Effect:** Posts a self-link to the actor's inbox. Issue status unchanged. Emits `REVIEW_ISSUE_SELF_LINKED`.

```typescript
interface SendToMyInboxPayload {
  issue_id: string; // UUID v7
}
```

Constraints: no status change; the issue remains `OPEN`. This action is additive and does not count toward resolution.

---

### 12. `add_note`

**Applicable groups:** All 5 issue groups
**Permission surface:** `REVIEW_QUEUE_RESOLVE`
**Effect:** Appends to `review_issues.resolution_note`. Issue status unchanged. Emits `REVIEW_NOTE_ADDED`.

```typescript
interface AddNotePayload {
  issue_id: string; // UUID v7
  note: string;     // Required — minimum 3 characters; appended to existing note
}
```

Constraints: no status change. Notes are append-only in the audit log (the current `resolution_note` column stores the latest snapshot; the full history is recoverable from audit events).

---

### 13. `request_regenerate_card`

**Applicable groups:** All 5 issue groups
**Permission surface:** `REVIEW_REGENERATE`
**Effect:** Re-runs `generateAndPersistCardContent` (Block 14 Phase 03) for the issue; updates `card_payload_json`, `card_content_generated_at`, `card_content_tier_used`, `card_content_fallback_applied`. Emits `REVIEW_CARD_REGENERATED`. `REVIEW_REGENERATE` surface is Owner/Admin only per `permission_matrix`.

```typescript
interface RegenerateCardContentPayload {
  issue_id: string; // UUID v7
}
```

Constraints: Owner/Admin only. The regeneration call goes through the AI gateway (Block 06) with the issue's current subject data. If the AI gateway is unavailable, the fallback template applies and `card_content_fallback_applied = true`.

---

## Mobile rejection policy

All 13 actions are listed in `mobile_write_rejection_endpoints` as write-intent surfaces. Mobile clients attempting any resolution action receive HTTP 405 `MOBILE_WRITE_REJECTED` with an `MOBILE_WRITE_REJECTED` audit event. Read access to the review queue (browsing, drill-down) remains available on mobile.

---

## Cross-references
- `data_layer_conventions_policy` — UUID v7 idempotency keys; canonical JSON for `resolution_action_payload` JSONB storage
- `resolution_action_enum` — canonical 13-value vocabulary; role × action eligibility matrix
- `issue_group_enum` — per-action applicable groups
- `severity_enum` — `snooze` and `dismiss_with_reason` severity eligibility constraints
- `permission_matrix` — `REVIEW_QUEUE_RESOLVE`, `REVIEW_ASSIGN`, `REVIEW_REGENERATE` surfaces
- `review_issues_schema` — target columns (`status`, `resolution_action_type`, `resolution_action_payload`, `assigned_to_user_id`, etc.)
- `mobile_write_rejection_endpoints` — write-surface rejection list
- `audit_log_policies` — `REVIEW_*` event naming convention
- `audit_event_taxonomy` — `REVIEW` and `MATCHING` domain events emitted per action
- Block 14 Phase 04 — resolution actions architecture
- Block 10 Phase 06 — rejection memory written by `reject_match` and `propose_alternative_match`
- Block 12 Phase 06 — exception path invoked by `mark_as_no_invoice_available`
