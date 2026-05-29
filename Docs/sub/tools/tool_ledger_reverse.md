# Tool: ledger.reverse_entry

**Block:** Ledger
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`ledger.reverse_entry` creates a mirror reversal entry for an incorrectly posted ledger entry. It is used to correct posting errors without deleting historical records. The original entry is preserved and marked as reversed; a new entry with the opposite debit/credit direction and identical amount and account is posted as the reversal. The net effect on the ledger is zero.

This tool is the only permitted mechanism for correcting a posted ledger entry. Direct deletion or in-place modification of `ledger_entries` rows is not allowed at any layer. Unauthorized mutation of posted entries constitutes a ledger tamper event and triggers `tamper_detection_forensic_runbook.md`.

## Tool Identity

| Property | Value |
|---|---|
| Tool name | `ledger.reverse_entry` |
| Namespace | `ledger` |
| Action | `reverse_entry` |
| Side effects | WRITES_RUN_STATE, WRITES_AUDIT |
| Step-up required | Yes — MFA step-up token required |
| Minimum role | `ORG_OWNER` or `ADMIN` |
| Mobile | Yes — see Mobile section |

## Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `ledger_entry_id` | UUID | Yes | PK of the `ledger_entries` row to reverse. |
| `reversal_reason` | TEXT | Yes | Human-readable explanation for the reversal. Minimum 10 characters. Stored on the reversal entry and in the audit event. |
| `step_up_token` | UUID | Yes | Step-up MFA token issued by `tool_step_up_request.md`. Must be valid and unexpired. |
| `run_id` | UUID | Yes | The workflow run context. The run must be in `RUNNING` or `REVIEW_HOLD` status. |
| `business_id` | UUID | Yes | Tenant scope. Must match the `business_id` on the target ledger entry. |

## Preconditions

The tool validates all of the following before creating any database rows. If any precondition fails, the tool returns an error and makes no changes.

### 1. Entry Exists and Is Not Already Reversed

```sql
SELECT id, entry_type, amount, currency, amount_eur, account_id,
       run_id, transaction_id, invoice_id, reversed
FROM ledger_entries
WHERE id = :ledger_entry_id
  AND business_id = :business_id;
```

- If no row is found: error `ENTRY_NOT_FOUND`.
- If `reversed = true`: error `ENTRY_ALREADY_REVERSED`. Double-reversal is handled differently — see Idempotency section.

### 2. Period Is OPEN

The period associated with the entry must not be locked:

```sql
SELECT pl.id
FROM period_locks pl
JOIN ledger_entries le ON le.run_id IN (
  SELECT id FROM workflow_runs WHERE period_id = pl.period_id
)
WHERE le.id = :ledger_entry_id
  AND pl.status = 'LOCKED';
```

If the period is `LOCKED`: error `PERIOD_LOCKED`. Reversals in locked periods require the period to be reopened via `tool_period_lock.md` (which itself requires ADMIN role and audit documentation).

### 3. Run Status Is Valid

The `run_id` must be in `RUNNING` or `REVIEW_HOLD` status:

```sql
SELECT run_status FROM workflow_runs
WHERE id = :run_id AND business_id = :business_id;
```

If status is not `RUNNING` or `REVIEW_HOLD`: error `INVALID_RUN_STATUS`.

### 4. Caller Role

The caller must have role `ORG_OWNER` or `ADMIN` in the business's org membership. Evaluated via `can_perform_helper`:

```sql
SELECT can_perform(:user_id, :business_id, 'REVERSE_LEDGER_ENTRY');
```

If the permission check fails: error `INSUFFICIENT_PERMISSIONS` (severity HIGH, audit event emitted).

### 5. Step-Up Token Valid

The `step_up_token` must be a valid, unexpired token issued to the calling user within the current session. Validated against `step_up_token_schema.md`. Expired or already-consumed tokens return `STEP_UP_REQUIRED`.

## Behaviour

After all preconditions pass, the tool executes the following as a single database transaction:

### Step 1: Create Reversal Entry

```sql
INSERT INTO ledger_entries (
  id, run_id, business_id, period_id, account_id,
  entry_type, amount, currency, amount_eur, fx_rate, fx_rate_date,
  transaction_id, invoice_id,
  description, posted_at, posted_by,
  reversal_of, created_at
) VALUES (
  gen_uuid_v7(),
  :run_id,
  :business_id,
  -- period_id copied from original entry
  :original.period_id,
  :original.account_id,
  -- Mirror the entry_type: DEBIT → CREDIT, CREDIT → DEBIT
  CASE WHEN :original.entry_type = 'DEBIT' THEN 'CREDIT' ELSE 'DEBIT' END,
  :original.amount,
  :original.currency,
  :original.amount_eur,
  :original.fx_rate,
  :original.fx_rate_date,
  :original.transaction_id,
  :original.invoice_id,
  'REVERSAL: ' || :reversal_reason,
  now(),
  'SYSTEM',
  :ledger_entry_id,  -- FK back to original
  now()
);
```

### Step 2: Mark Original Entry as Reversed

```sql
UPDATE ledger_entries
SET reversed = true,
    reversed_at = now(),
    reversed_by = :caller_user_id,
    reversal_reason = :reversal_reason
WHERE id = :ledger_entry_id;
```

### Step 3: Trigger Reconciliation Check

After posting the reversal, `ledger.reconcile` is invoked for the affected `run_id` to confirm that the double-entry constraint is maintained. If reconciliation fails, the database transaction is rolled back and error `RECONCILIATION_FAILED` is returned.

### Step 4: Emit Audit Event

`LEDGER_ENTRY_REVERSED` (MEDIUM) is emitted with:
- `original_entry_id`
- `reversal_entry_id`
- `reversal_reason`
- `run_id`
- `business_id`
- `caller_user_id`

## Outputs

```json
{
  "reversal_entry_id": "019501e7-...",
  "original_entry_id": "019501e6-...",
  "reversal_reason": "Duplicate posting of invoice INV-2026-0042",
  "reversed_at": "2026-05-17T10:30:00Z"
}
```

## Idempotency

The tool is designed to be safe to call multiple times, but the behaviour is explicit rather than silent:

- Calling `ledger.reverse_entry` on an entry that already has `reversed = true` returns error `ENTRY_ALREADY_REVERSED` rather than creating a second reversal. This prevents accidental double-reversal.
- If a genuine re-reversal is needed (i.e. reversing the reversal entry itself to restore the original posting), the caller must pass the `reversal_entry_id` as the `ledger_entry_id`. This creates a third entry that mirrors the original — the net effect is that the original posting is restored. This is a re-reversal, not a duplicate.
- Re-reversals require the same preconditions and step-up MFA as standard reversals.

The net accounting effect of a full reversal-and-re-reversal cycle is zero, which is correct.

## Adjustment Policy Cross-Reference

For cases where a ledger entry is not simply wrong but needs to be replaced with a corrected value (e.g. the amount was right but the account code was wrong), the pattern is:

1. Reverse the original entry with `ledger.reverse_entry`.
2. Post a new corrected entry with `tool_ledger_post.md`.

This two-step pattern is documented in `adjustment_policy.md`. Do not use `ledger.reverse_entry` alone when a replacement posting is also needed — the run will fail reconciliation if the reversal leaves a debit or credit orphaned.

## Audit Events

| Event | Severity | Description |
|---|---|---|
| `LEDGER_ENTRY_REVERSED` | MEDIUM | Emitted after successful reversal. Includes both entry IDs, reason, and caller. |
| `LEDGER_REVERSAL_PRECONDITION_FAILED` | HIGH | Emitted if a precondition check fails (e.g. insufficient permissions, locked period). Includes the failing precondition name. |

## Mobile Section

`ledger.reverse_entry` is available on the mobile client under the Ledger detail view for individual entries, but with additional friction to prevent accidental reversals.

**Mobile constraints:**
- The reversal action is not accessible from list views; the user must navigate to the individual ledger entry detail screen.
- On mobile, the step-up MFA flow triggers biometric authentication (Face ID / fingerprint) if available, or a TOTP prompt as fallback. The step-up token is issued and consumed within the same mobile session.
- The `reversal_reason` input is required before the MFA step is triggered — the form validates minimum 10 characters before presenting the biometric prompt.
- Success and failure states are shown as full-screen confirmations (not toasts) to ensure the user registers the outcome.
- Network interruption handling: if the mobile client submits the reversal and the network drops before a response is received, the client must NOT retry automatically. The user must manually verify whether the reversal was applied before attempting again, to avoid the double-call scenario described in Idempotency.
- The mobile endpoint returns `ENTRY_ALREADY_REVERSED` if the user retries a completed reversal, with a clear UI message: "This entry was already reversed."

## Related Documents

- `ledger_entry_schema.md` — DDL for `ledger_entries` including `reversed`, `reversed_at`, `reversal_of` columns
- `adjustment_policy.md` — when to reverse vs. when to post an adjustment
- `tool_ledger_post.md` — posting new entries (used after reversal to post corrections)
- `tool_ledger_reconcile.md` — double-entry reconciliation check
- `tool_period_lock.md` — period lock/unlock (prerequisite if period is locked)
- `tool_step_up_request.md` — step-up MFA token issuance
- `double_entry_validation_policy.md` — reconciliation constraints
- `tamper_detection_forensic_runbook.md` — response if unauthorized entry mutation is detected
- `ledger_imbalance_runbook.md` — handling reconciliation failures
- `emit_audit_api.md` — audit event emission
