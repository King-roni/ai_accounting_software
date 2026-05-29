# Tool: matching.confirm_match

**Namespace:** matching  
**WRITES_RUN_STATE:** No  
**WRITES_AUDIT:** Yes  
**Idempotent:** No  
**Mobile:** No

---

## Purpose

Confirms a proposed match between a bank statement line and a transaction. Transitions the `match_proposals` row from `PROPOSED` to `CONFIRMED`, links the `bank_statement_lines` row to the transaction via `transaction_id`, and stamps `transactions.matched_at`. Emits `MATCHING_CONFIRMED`.

This tool is also called internally by `matching.propose` when the auto-confirm path is triggered (`match_level = EXACT`, `proposed_by = 'system'`). In that case `confirmed_by` is the literal string `'system'`.

---

## Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `match_proposal_id` | uuid | Yes | FK to `match_proposals.id`. The proposal to confirm. |
| `confirmed_by` | text | Yes | `org_member_id` UUID of the reviewer performing the confirmation, or `'system'` when called from the auto-confirm path. |

---

## Steps

### 1. Load proposal

Fetch the `match_proposals` row for `match_proposal_id`. If not found, return `ERR_PROPOSAL_NOT_FOUND`.

Check `match_proposals.status`. If status is not `PROPOSED`, return the appropriate error:
- `status = 'CONFIRMED'` or `status = 'AUTO_CONFIRMED'` → `ERR_ALREADY_CONFIRMED`
- `status = 'REJECTED'` → `ERR_PROPOSAL_REJECTED`
- `status = 'SUPERSEDED'` → `ERR_PROPOSAL_SUPERSEDED`

### 2. Validate confirmer permission

If `confirmed_by != 'system'`:
- Look up the `org_member_id` in `org_members` for the `business_entity_id` of the proposal's transaction.
- Verify the member holds the `review_queue:write` permission. If not, return `ERR_INSUFFICIENT_PERMISSION`.

System-path calls (`confirmed_by = 'system'`) bypass the permission check. The caller (`matching.propose`) is responsible for ensuring the auto-confirm conditions are met.

### 3. Re-validate match target state

Reload the `bank_statement_lines` row for the proposal's `bank_statement_line_id`. If `transaction_id IS NOT NULL` and not equal to the proposal's `transaction_id`, another confirmation raced ahead. Return `ERR_LINE_ALREADY_MATCHED`.

Reload the `transactions` row for the proposal's `transaction_id`. If `matched_at IS NOT NULL`, return `ERR_TRANSACTION_ALREADY_MATCHED`.

These re-checks are necessary because proposals may be confirmed concurrently. The database UPDATE in step 4 uses a conditional WHERE clause as the final guard.

### 4. Update match_proposals

```sql
UPDATE match_proposals
SET
  status        = CASE
                    WHEN $confirmed_by = 'system' THEN 'AUTO_CONFIRMED'
                    ELSE 'CONFIRMED'
                  END,
  confirmed_by  = $confirmed_by,
  confirmed_at  = now()
WHERE id = $match_proposal_id
  AND status = 'PROPOSED';
```

If 0 rows updated (race condition), return `ERR_CONCURRENT_MODIFICATION`.

### 5. Update bank_statement_lines

```sql
UPDATE bank_statement_lines
SET transaction_id = <proposal.transaction_id>
WHERE id = <proposal.bank_statement_line_id>
  AND transaction_id IS NULL;
```

If 0 rows updated, return `ERR_LINE_ALREADY_MATCHED`.

### 6. Update transactions

```sql
UPDATE transactions
SET matched_at = now()
WHERE id = <proposal.transaction_id>
  AND matched_at IS NULL;
```

If 0 rows updated, return `ERR_TRANSACTION_ALREADY_MATCHED`.

### 7. Supersede competing proposals

Any other `match_proposals` rows for the same `bank_statement_line_id` or `transaction_id` that remain in `PROPOSED` status must be set to `SUPERSEDED`:

```sql
UPDATE match_proposals
SET status = 'SUPERSEDED'
WHERE (
    bank_statement_line_id = <proposal.bank_statement_line_id>
    OR transaction_id = <proposal.transaction_id>
  )
  AND id <> $match_proposal_id
  AND status = 'PROPOSED';
```

### 8. Emit audit event

Emit `MATCHING_CONFIRMED` with payload:
```json
{
  "proposal_id": "<uuid>",
  "bank_statement_line_id": "<uuid>",
  "transaction_id": "<uuid>",
  "business_entity_id": "<uuid>",
  "confirmed_by": "<uuid|system>",
  "confirmed_at": "<timestamptz>",
  "match_level": "<enum>",
  "match_score": <numeric>
}
```

Audit event note: `MATCHING_CONFIRMED` is not yet in the taxonomy as of this writing. `MATCHING_USER_CONFIRMED` (line 498 of `audit_event_taxonomy.md`) covers the human-reviewer path. The canonical event for this tool should be added as `MATCHING_CONFIRMED` covering both paths. Clarify with the taxonomy owner before production deployment.

---

## Error paths

| Error code | Condition |
|---|---|
| `ERR_PROPOSAL_NOT_FOUND` | No `match_proposals` row for `match_proposal_id` |
| `ERR_ALREADY_CONFIRMED` | Proposal status is already `CONFIRMED` or `AUTO_CONFIRMED` |
| `ERR_PROPOSAL_REJECTED` | Proposal has been rejected and cannot be confirmed |
| `ERR_PROPOSAL_SUPERSEDED` | Proposal was superseded by another confirmation |
| `ERR_INSUFFICIENT_PERMISSION` | `confirmed_by` member lacks `review_queue:write` |
| `ERR_LINE_ALREADY_MATCHED` | Line's `transaction_id` already set to a different transaction |
| `ERR_TRANSACTION_ALREADY_MATCHED` | Transaction's `matched_at` already set |
| `ERR_CONCURRENT_MODIFICATION` | Another process confirmed or rejected the proposal between load and update |

Steps 4 through 7 are wrapped in a single database transaction. Any failure in steps 5–7 rolls back the status update in step 4, leaving the proposal in its original `PROPOSED` state.

---

## Mobile

This tool is not available on mobile clients. Match confirmations require reviewer-level access and are performed from the desktop review queue. Any invocation from a mobile client returns HTTP 405 `MOBILE_WRITE_REJECTED`. Read access to confirmation state is available on mobile via the review queue read endpoints.

---

## Related Documents

- `match_proposal_schema.md` — table updated by this tool
- `bank_statement_line_schema.md` — `transaction_id` set by this tool
- `transactions_schema.md` — `matched_at` set by this tool
- `tool_matching_propose.md` — calls this tool on the auto-confirm path
- `tool_match_reject.md` — counterpart for rejecting proposals
- `matching_policy.md` — match lifecycle rules
- `org_member_schema.md` — permission check source
- `audit_event_taxonomy.md` — MATCHING_USER_CONFIRMED and MATCHING_AUTO_CONFIRMED definitions
