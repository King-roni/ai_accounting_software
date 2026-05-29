# Tool: matching.reject_match

**Block:** Matching  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`matching.reject_match` explicitly rejects a proposed match between a transaction and an invoice. A rejection documents why a proposed match is not acceptable and releases the transaction so that a better match can be proposed or the transaction can be routed to the review queue.

Rejection is reversible within the same run (before finalization). The rejected proposal record is retained for audit purposes; it is not deleted.

When `exception_documented = true`, the rejection also creates a `matching_exception` record that serves as the permanent evidence that the mismatch was reviewed and intentionally accepted as an exception.

---

## Tool Signature

**Name:** `matching.reject_match`  
**Namespace:** `matching`  
**Action:** `reject_match`

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `run_id` | UUID | Yes | FK to `workflow_runs(id)`. Run must be RUNNING in the MATCHING phase. |
| `match_proposal_id` | UUID | Yes | FK to `match_proposals(id)`. Must be in status `PROPOSED` or `AUTO_CONFIRMED`. |
| `rejection_reason` | TEXT | Yes | Human-readable explanation. Min 10 characters, max 1,000 characters. Stored verbatim. |
| `exception_documented` | boolean | Yes | If `true`, creates a `matching_exception` record. See Exception Documentation below. |
| `documentation_note` | TEXT | Conditional | Required when `exception_documented = true`. Max 2,000 characters. Stored on the exception record. |

### Outputs

| Field | Type | Description |
|---|---|---|
| `match_proposal` | object | Updated proposal snapshot: `id`, `status`, `rejected_at`, `rejected_by`. |
| `matching_exception_id` | UUID or null | ID of the `matching_exception` row created. `null` when `exception_documented = false`. |
| `transaction_released` | boolean | `true` if the transaction was released for re-matching. |
| `review_issue_id` | UUID or null | ID of the review issue opened when no other candidate exists. |

---

## Preconditions

1. Run must be in phase MATCHING and status RUNNING.
2. `match_proposal_id` must reference a proposal with status `PROPOSED` or `AUTO_CONFIRMED` belonging to the specified `run_id`.
3. `rejection_reason` must be non-empty after trim.
4. If `exception_documented = true`, `documentation_note` must be non-empty after trim.

---

## State Changes

### Match Proposal Update

```sql
UPDATE match_proposals
SET    status          = 'REJECTED',
       rejection_reason = :rejection_reason,
       rejected_at     = now(),
       rejected_by     = :current_user_id
WHERE  id     = :match_proposal_id
  AND  run_id = :run_id
  AND  status IN ('PROPOSED', 'AUTO_CONFIRMED');
```

The `status` column transitions to `REJECTED`. No other proposal is superseded by this operation.

### Transaction Release

After the proposal is rejected, the linked transaction is released for re-matching:

```sql
UPDATE transactions
SET    match_status = 'UNMATCHED',
       current_match_proposal_id = NULL
WHERE  id = :transaction_id;
```

`transaction_released` in the output is `true` when this update affects exactly one row.

### Re-matching Attempt

After release, the matching engine is signalled to attempt a new proposal for this transaction within the current run. If a new candidate is found, a new `match_proposals` row is created with status `PROPOSED`. If no candidate exists, the transaction advances to the review queue (see below).

---

## Exception Documentation

When `exception_documented = true`, a `matching_exception` row is created:

```sql
INSERT INTO matching_exceptions (
  id,
  run_id,
  transaction_id,
  invoice_id,
  exception_type,
  documentation_note,
  documented_by,
  documented_at
) VALUES (
  gen_uuid_v7(),
  :run_id,
  :transaction_id,
  :invoice_id_from_proposal,
  'EXCEPTION_DOCUMENTED',
  :documentation_note,
  :current_user_id,
  now()
);
```

An exception record means: "this mismatch was reviewed by a human, the match was deliberately rejected, and the reason is documented." It satisfies audit requirements where a transaction cannot be matched to any invoice and the business intentionally proceeds without a match.

Reference: `matching_exception_schema.md`, `out_exception_documented_policy.md`.

---

## Review Queue Escalation

If after the re-matching attempt no new candidate is found, the transaction is escalated:

```sql
-- via tool_review_queue_create_issue.md
{
  "issue_type":     "MATCHING_EXCEPTION",
  "severity":       "HIGH",
  "run_id":         "<run_id>",
  "transaction_id": "<transaction_id>",
  "context":        {
    "rejected_proposal_id": "<match_proposal_id>",
    "rejection_reason":     "<rejection_reason>",
    "exception_documented": false
  }
}
```

If `exception_documented = true`, the issue severity is lowered to `MEDIUM` because the mismatch is already documented.

---

## Reverting a Rejection

A REJECTED match proposal can be reversed within the same run (before finalization) by calling `matching.propose` again for the same transaction and invoice pair. The old REJECTED proposal record is updated to status `SUPERSEDED`; a new proposal is created with status `PROPOSED`.

After finalization, rejected proposals are immutable. The only path forward post-finalization is a period amendment run.

---

## Audit Events

| Event | Severity | Emitted when |
|---|---|---|
| `MATCHING_MATCH_REJECTED` | LOW | Proposal rejected, no exception |
| `MATCHING_MATCH_REJECTED` | MEDIUM | Proposal rejected with `exception_documented = true` |

Payload:

```jsonc
{
  "run_id":                 "<uuid>",
  "match_proposal_id":      "<uuid>",
  "transaction_id":         "<uuid>",
  "invoice_id":             "<uuid or null>",
  "rejection_reason":       "Invoice amount includes VAT; bank transaction is net.",
  "exception_documented":   true,
  "matching_exception_id":  "<uuid>",
  "rejected_by":            "<user_id>"
}
```

---

## Error Handling

| Condition | Error code | Severity |
|---|---|---|
| Run not in MATCHING phase | `RUN_WRONG_PHASE` | BLOCKING |
| Proposal not found or wrong run | `PROPOSAL_NOT_FOUND` | BLOCKING |
| Proposal already REJECTED or SUPERSEDED | `PROPOSAL_ALREADY_RESOLVED` | BLOCKING |
| Proposal already CONFIRMED | `PROPOSAL_CONFIRMED` — use unconfirm path first | HIGH |
| `rejection_reason` too short | `REJECTION_REASON_TOO_SHORT` | BLOCKING |
| `documentation_note` missing when required | `DOCUMENTATION_NOTE_REQUIRED` | BLOCKING |

---

## Mobile

`matching.reject_match` is classified as `WRITES_RUN_STATE | WRITES_AUDIT`.

On mobile clients:

- The rejection form is presented as a modal sheet on the match proposal card. It contains a free-text field for `rejection_reason` and a toggle for "Document as exception" which reveals the `documentation_note` field.
- Minimum character validation for `rejection_reason` (10 chars) and `documentation_note` (20 chars) is enforced client-side on mobile before submission, in addition to server-side validation.
- After a successful rejection the match proposal card transitions to a "Rejected" state inline. If the re-matching attempt produces a new candidate, the new proposal card appears below within the same session without a full list reload.
- If the re-matching attempt produces no candidate and a review issue is opened, a HIGH priority banner appears in the mobile review queue tab with a deep link to the escalated transaction.
- Step-up authentication is required on mobile for `exception_documented = true` rejections when `business_settings.require_step_up_for_exception_documentation = true`. The mobile client must obtain a step-up token via `auth.step_up_request` before submitting the form.

---

## Related Documents

- `tool_match_propose.md` — creates the proposals that this tool rejects
- `tool_match_confirm.md` — confirms a proposal (alternative to rejection)
- `match_proposal_schema.md` — DDL for `match_proposals` table
- `matching_exception_schema.md` — DDL for `matching_exceptions` table
- `out_exception_documented_policy.md` — policy governing exception documentation
- `matching_policy.md` — overall matching lifecycle policy
- `tool_review_queue_create_issue.md` — review issue creation called internally
- `emit_audit_api.md` — audit emission API
