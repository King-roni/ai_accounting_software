# Review Queue Bulk Action Policy

**Category:** Policies · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

**Purpose.** Define the constraints, atomicity guarantees, and preview mechanics for bulk operations on review queue issues. This policy is binding for `review_queue.execute_bulk_action` and its callers. It governs which action types are permitted, the batch size cap, the mandatory preview step, the handling of BLOCKING-severity issues, and the mobile write restriction.

---

## Permitted bulk actions

Three bulk operations are supported. No other bulk operations exist.

| Bulk action | Tool call | Description |
|---|---|---|
| `BULK_RESOLVE` | `review_queue.execute_bulk_action` | Mark all issues in the batch as RESOLVED |
| `BULK_SNOOZE` | `review_queue.execute_bulk_action` | Snooze all issues in the batch until a specified date |
| `BULK_ASSIGN` | `review_queue.execute_bulk_action` | Reassign all issues in the batch to a specified user |

`BULK_DISMISS` does not exist. Individual dismissal is available per `review_queue.dismiss_issue` but there is no bulk path. This is intentional: dismissal is an irreversible action on potentially sensitive compliance issues and requires individual accountant judgement.

For `BULK_SNOOZE`, the `snooze_until` date is included in the preview token request and is part of the token's encoded payload; it cannot be changed between preview and execution.

For `BULK_ASSIGN`, the `assignee_user_id` is similarly encoded in the preview token.

---

## Maximum batch size

A single bulk action may target at most **100 issues**. Requests with more than 100 issue IDs in the batch are rejected immediately with error code `BULK_ACTION_LIMIT_EXCEEDED` before the preview token is issued. No partial processing occurs; the entire request is rejected.

The 100-issue limit applies to the issue IDs supplied by the caller, not to the number of issues ultimately modified (which may be fewer due to BLOCKING exclusions or concurrent resolution by another session).

---

## Token-based preview

Before a bulk action executes, the caller must obtain a **`bulk_preview_token`** via `review_queue.preview_bulk_action`. Execution without a valid token is rejected.

### Token issuance

```
POST /review-queue/bulk/preview
{
  "action": "BULK_RESOLVE" | "BULK_SNOOZE" | "BULK_ASSIGN",
  "issue_ids": ["<uuid>", ...],          // 1–100 IDs
  "snooze_until": "<iso8601_date>",      // required for BULK_SNOOZE
  "assignee_user_id": "<uuid>"           // required for BULK_ASSIGN
}
```

Response includes:
- `bulk_preview_token` — opaque token (UUID v4, not v7; it is a security token) encoding the action, issue IDs, and action-specific parameters
- `expires_at` — 15 minutes from issuance
- `affected_issue_count` — count of non-BLOCKING issues that will be acted upon
- `blocking_issue_count` — count of BLOCKING-severity issues in the batch (excluded from execution)
- `severity_breakdown` — `{ "LOW": n, "MEDIUM": n, "HIGH": n, "BLOCKING": n }`
- `blocking_issue_ids` — list of BLOCKING-severity issue IDs in the batch (so the caller can surface them to the accountant for individual resolution)

**Audit event:** `REVIEW_QUEUE_BULK_ACTION_PREVIEW_ISSUED` (LOW) — emitted on successful token issuance. Payload: `token_id` (UUID v7 PK of the `bulk_preview_tokens` row — not the token value itself), `action`, `issue_count`, `blocking_issue_count`, `issued_by_user_id`, `expires_at`.

The token is a single-use credential. Once consumed by a successful `execute_bulk_action` call, it cannot be reused. Expired tokens return `BULK_PREVIEW_TOKEN_EXPIRED`.

### Preview behaviour for BLOCKING issues

If the batch contains any BLOCKING-severity issues:
- `BULK_RESOLVE`: rejected entirely — `BULK_ACTION_INCLUDES_BLOCKING` error. The caller must remove BLOCKING issues from the batch and re-request a preview token.
- `BULK_SNOOZE`: BLOCKING-severity issues are excluded silently from the snooze action. The token encodes which issues will be snoozed (non-BLOCKING only). The preview response lists the excluded BLOCKING issues.
- `BULK_ASSIGN`: BLOCKING-severity issues are included in assignment. Assignment does not change the status or severity of an issue; it only changes the responsible accountant.

---

## Atomicity guarantee

The bulk action executes inside a single database transaction. All rows in the batch are updated, or none are. There is no partial success path.

Implementation:

```sql
BEGIN;
  -- Lock all target review_issues rows in deterministic order (by id ASC) to prevent deadlock
  SELECT id FROM review_issues WHERE id = ANY($issue_ids) ORDER BY id FOR UPDATE;
  -- Validate each row (status not already RESOLVED/DISMISSED, business_id matches session)
  -- Execute the bulk state transition
  UPDATE review_issues SET ... WHERE id = ANY($validated_ids);
  -- Emit single REVIEW_QUEUE_BULK_ACTION_COMPLETED audit event
COMMIT;
```

If any row fails validation (e.g., an issue was resolved by a concurrent session between preview and execution), the transaction rolls back entirely and the caller receives `BULK_ACTION_STALE_BATCH`. The caller must re-preview with the current issue state.

---

## BLOCKING severity exclusion

Issues with `severity = BLOCKING` cannot be bulk-resolved. The rationale: BLOCKING issues require individual accountant attention and may gate finalization; bulk-resolution could mask a data integrity problem that must be explicitly examined.

For `BULK_RESOLVE` specifically:
- If any issue in the batch has `severity = BLOCKING`, the preview step returns `BULK_ACTION_INCLUDES_BLOCKING` with `blocking_issue_ids` listed.
- No preview token is issued for a `BULK_RESOLVE` batch that contains BLOCKING issues.
- The caller must remove the BLOCKING issues from the batch and request a new preview.

Individual resolution of BLOCKING issues is available via `review_queue.resolve_issue`, which requires the accountant to supply a `resolution_note` (minimum 10 characters) for BLOCKING-severity issues.

---

## Mobile restriction

`BULK_RESOLVE` and `BULK_ASSIGN` are write actions. They are blocked on mobile clients per `mobile_write_rejection_endpoints.md`. Requests from a session with `client_form_factor = MOBILE` return `MOBILE_WRITE_REJECTED` (HTTP 403) and emit `MOBILE_WRITE_REJECTED` per Block 02's write-rejection policy.

`BULK_SNOOZE` is also a write action and is subject to the same mobile restriction.

The preview endpoint (`review_queue.preview_bulk_action`) is a read-proposer operation and is NOT blocked on mobile. Mobile clients can obtain a preview token; they cannot execute it.

---

## Audit events

| Event | Severity | Emitted when |
|---|---|---|
| `REVIEW_QUEUE_BULK_ACTION_PREVIEW_ISSUED` | LOW | Preview token is issued successfully |
| `REVIEW_QUEUE_BULK_ACTION_COMPLETED` | LOW | Bulk action executes successfully |
| `REVIEW_QUEUE_BULK_ACTION_REJECTED` | MEDIUM | Bulk action is rejected for any reason |

`REVIEW_QUEUE_BULK_ACTION_REJECTED` payload includes `rejection_reason` with one of:
- `BULK_ACTION_LIMIT_EXCEEDED`
- `BULK_ACTION_INCLUDES_BLOCKING`
- `BULK_PREVIEW_TOKEN_EXPIRED`
- `BULK_PREVIEW_TOKEN_INVALID`
- `BULK_ACTION_STALE_BATCH`
- `MOBILE_WRITE_REJECTED`

`REVIEW_QUEUE_BULK_ACTION_COMPLETED` payload:

```json
{
  "token_id": "<bulk_preview_tokens.id>",
  "action": "BULK_RESOLVE",
  "workflow_run_id": "<uuid>",
  "issues_acted_on_count": 42,
  "executed_by_user_id": "<uuid>",
  "executed_at": "<iso8601>"
}
```

---

## Cross-references

- `bulk_action_schemas.md` — `bulk_preview_tokens` table DDL, token encoding, expiry mechanics
- `issue_type_registry_schema.md` — severity enum definition; BLOCKING exclusion registry flag per issue type
- `snooze_carry_forward_policy.md` — snooze mechanics invoked by `BULK_SNOOZE`; carry-forward and escalation rules
- `mobile_write_rejection_endpoints.md` — full list of write surfaces blocked on mobile clients
