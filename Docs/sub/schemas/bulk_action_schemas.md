# Bulk Action Schemas

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

Request and response schemas for the three bulk operation surfaces on review queue items: bulk resolve, bulk snooze, and bulk reassign. Each surface follows a mandatory two-phase preview-then-commit pattern. This sub-doc owns the wire shapes; the per-issue resolution mechanics are defined in `resolution_action_payload_schema` and applied per-issue within the bulk path.

---

## 1. Shared constraints (apply to all three bulk actions)

- **Business isolation:** all `review_issue_id` values in a single request must belong to the same `business_id`. Cross-business bulk operations are rejected with HTTP 422 `BULK_ACTION_CROSS_BUSINESS_REJECTED`.
- **Maximum batch size:** 50 items per request. Requests with more than 50 `review_issue_id` values are rejected with HTTP 422 `BULK_ACTION_LIMIT_EXCEEDED` before any preview is generated.
- **Mixed severity:** bulk operations across issues of mixed severity are permitted, subject to per-action severity restrictions documented below.
- **Mobile rejection:** all three bulk action endpoints are listed in `mobile_write_rejection_endpoints`. Mobile clients receive HTTP 405 `MOBILE_WRITE_REJECTED`. Read access to the review queue remains available on mobile.
- **Idempotency:** re-submitting the same `bulk_action_id` within 24 hours returns the original response without re-processing. The deduplication key is the `bulk_action_id` field supplied by the caller in the commit request.
- **Permission surface:** `REVIEW_QUEUE_RESOLVE` is required for bulk resolve and bulk snooze; `REVIEW_ASSIGN` is required for bulk reassign. The gate is checked once per call.

---

## 2. Two-phase flow (preview then commit)

All three bulk actions share the same two-phase structure:

**Phase 1 — Preview:** the caller submits the issue ID list and action parameters. The server validates eligibility and returns a `confirmation_token` plus a summary of which issues will be affected and which will be skipped. No writes occur.

**Phase 2 — Commit:** the caller submits the `confirmation_token` along with the action parameters. The server applies the action per eligible issue and returns the full `BulkActionResponse`. The token is single-use and expires after 5 minutes.

If new issues are created that match the filter between preview and commit, they are NOT included in the commit — the commit is bound to the exact ID set resolved at preview time (stale-filter protection).

---

## 3. Bulk resolve

### 3.1 Preview request

```typescript
interface BulkResolvePreviewRequest {
  action: 'bulk_resolve';
  business_id: string;                // UUID v7
  review_issue_ids: string[];         // UUID v7[]; max 50
  // Permitted resolution_action values for bulk:
  // 'mark_resolved' | 'confirm_match' | 'accept_classification' |
  // 'mark_as_no_invoice_available' | 'dismiss_with_reason'
  resolution_action: ResolutionAction;
  action_params: BulkResolveActionParams;
  bulk_action_reason: string;         // min 5 characters
}
```

### 3.2 Preview response

```typescript
interface BulkActionPreviewResponse {
  confirmation_token: string;         // single-use; expires 5 minutes
  eligible_count: number;
  eligible_issue_ids: string[];
  ineligible_count: number;
  ineligible_items: Array<{
    review_issue_id: string;
    reason: 'ACTION_NOT_ALLOWED_FOR_ISSUE_TYPE' | 'SEVERITY_RESTRICTION'
          | 'ISSUE_ALREADY_CLOSED' | 'PERMISSION_DENIED_FOR_ACTION'
          | 'CROSS_BUSINESS_MISMATCH';
  }>;
}
```

### 3.3 Commit request

```typescript
interface BulkResolveCommitRequest {
  action: 'bulk_resolve';
  business_id: string;
  review_issue_ids: string[];
  resolution_action: ResolutionAction;
  action_params: BulkResolveActionParams;
  bulk_action_reason: string;
  confirmation_token: string;         // from preview
  bulk_action_id: string;             // UUID v7; idempotency key
}
```

### 3.4 Validation rules for bulk resolve

- `dismiss_with_reason` on a `BLOCKING` issue is skipped per the dismissal matrix in `resolution_action_payload_schema`.
- `confirm_match` requires the issue to have an associated `match_record_id` resolvable from the issue's subject; issues without one are added to the `rejected` list with `ACTION_NOT_ALLOWED_FOR_ISSUE_TYPE`.
- `mark_as_no_invoice_available` is restricted to OUT-side issues; IN-side issues are rejected.
- Per-issue `allowed_resolution_actions` from `issue_type_registry` is checked; actions not in the list are skipped.

---

## 4. Bulk snooze

### 4.1 Preview request

```typescript
interface BulkSnoozePreviewRequest {
  action: 'bulk_snooze';
  business_id: string;
  review_issue_ids: string[];         // max 50
  snooze_reason: string;              // min 5 characters; applied to every eligible issue
  snooze_until_run_id?: string | null; // null = indefinite; only permitted for LOW severity
  bulk_action_reason: string;         // min 5 characters
}
```

### 4.2 Bulk snooze validation rules

- **`BLOCKING` severity is a hard block:** if any issue in the request has `severity = BLOCKING`, the entire bulk snooze request is rejected with HTTP 422 `BULK_SNOOZE_BLOCKED_CONTAINS_BLOCKING` before a confirmation token is issued. This differs from bulk resolve where per-issue skipping is used — for snooze, a `BLOCKING` issue in the set is treated as a request-level error.
- **`HIGH` severity:** `HIGH` issues are included in the preview as eligible only if their `carry_forward_count` is 0 (first snooze). Issues with `carry_forward_count >= 1` are added to `ineligible_items` with `SEVERITY_RESTRICTION`.
- **Indefinite snooze (`snooze_until_run_id = null`):** issues with `severity != LOW` are added to `ineligible_items` with `INDEFINITE_SNOOZE_NOT_PERMITTED`.
- Snooze is not in the 13-value `resolution_action_enum`; it is a parallel surface. The `bulk_snooze` endpoint is registered separately from `bulk_resolve`.

---

## 5. Bulk reassign

### 5.1 Preview request

```typescript
interface BulkReassignPreviewRequest {
  action: 'bulk_reassign';
  business_id: string;
  review_issue_ids: string[];         // max 50

  // Must hold an active role on the business
  assignee_user_id: string;           // UUID v7

  // Mandatory for bulk reassign
  bulk_action_reason: string;         // min 5 characters
}
```

### 5.2 Bulk reassign validation rules

- `assignee_user_id` must be an active member of the `business_id` at commit time. Stale membership is detected at commit time, not preview time.
- Reassignment to self is permitted for all issues; it emits a warning flag in the audit payload per-issue.
- `REVIEW_ASSIGN` permission surface is required; `REVIEW_QUEUE_RESOLVE` alone is not sufficient.
- Mixed-severity reassignment is unrestricted — all severity levels may be reassigned.

---

## 6. Shared commit response

All three bulk actions return the same response shape after commit:

```typescript
interface BulkActionResponse {
  bulk_action_id: string;             // echoed from request
  accepted: string[];                 // UUID v7[] — issues successfully acted on
  rejected: Array<{
    review_issue_id: string;
    reason: 'ACTION_NOT_ALLOWED_FOR_ISSUE_TYPE' | 'SEVERITY_RESTRICTION'
          | 'ISSUE_ALREADY_CLOSED' | 'PERMISSION_DENIED_FOR_ACTION'
          | 'CONFIRMATION_TOKEN_EXPIRED' | 'CONFIRMATION_TOKEN_ALREADY_USED'
          | 'INDEFINITE_SNOOZE_NOT_PERMITTED' | 'ASSIGNEE_NOT_ACTIVE_MEMBER';
  }>;
  total_requested: number;
  total_accepted: number;
  total_rejected: number;
  committed_at: string;               // ISO 8601 timestamptz
}
```

**Partial success:** commit succeeds for eligible issues even when some are rejected. The caller sees the per-issue result in `rejected`.

**Atomicity:** not transactional across issues. Each issue's resolution is its own atomic unit per the Stage 1 decision in Block 14 Phase 05. Failure of one issue does not roll back others.

---

## 7. Audit events

| Event | Severity | When |
|---|---|---|
| `REVIEW_ISSUE_BULK_ACTION_COMPLETED` | MEDIUM | One event per commit call; payload includes `bulk_action_id`, `action`, `total_accepted`, `total_rejected`, `business_id` |

Per-issue events (`REVIEW_ISSUE_RESOLVED`, `REVIEW_ISSUE_SNOOZED`, `REVIEW_ISSUE_REASSIGNED`) are emitted individually for each accepted issue via the standard per-action paths. The bulk-level event is an aggregate event for tracking the bulk operation as a unit. The `bulk_action_id` in the per-issue event payloads links each per-issue event back to the bulk operation.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for `bulk_action_id`; canonical JSON for response payloads
- `resolution_action_payload_schema` — per-action payload shapes applied per-issue within the bulk path; dismissal severity matrix
- `review_issue_card_schema` — `issue_type_registry.allowed_resolution_actions` checked per issue
- `severity_enum` — closed 4-value set; per-severity snooze and dismiss restrictions
- `snooze_carry_forward_schema` — `carry_forward_count` check for `HIGH` severity bulk snooze eligibility
- `mobile_write_rejection_endpoints` — all three bulk action endpoints listed as mobile-rejected write surfaces
- `audit_log_policies` — `REVIEW_ISSUE_BULK_ACTION_COMPLETED` event naming; `REVIEW` domain
- `audit_event_taxonomy` — `REVIEW` domain canonical events
- `permission_matrix` — `REVIEW_QUEUE_RESOLVE` and `REVIEW_ASSIGN` surfaces
- Block 14 Phase 05 — bulk actions architecture; atomicity decision; confirmation-token mechanism
- Block 14 Phase 07 — snooze mechanics referenced by bulk snooze
- Block 03 Phase 05 — gate re-evaluation triggered after bulk resolution
