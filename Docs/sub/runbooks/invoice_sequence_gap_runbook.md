# Runbook: Invoice Number Sequence Gap Investigation
**Category:** Runbooks · Block 13 — IN Workflow + Invoice Generator
**Last updated:** 2026-05-17

---

## Background

The Cyprus Tax Department requires sequential invoice numbering without gaps. A gap — for
example `INV-2025-0042` followed directly by `INV-2025-0044` with no `INV-2025-0043` — is a
compliance deficiency. When a gap is confirmed, it must be documented with the reason and
retained for audit purposes. This runbook covers detection, root-cause analysis, documentation,
and escalation.

---

## Detection

Gaps are surfaced through two mechanisms:

1. **Automated check:** The gap detection job queries `invoice_sequences` and cross-references
   `last_used_number` against the `invoices` table on a nightly schedule. Gaps are written to
   the `invoice_sequence_gaps` monitoring table and a review issue is opened.

2. **Manual observation:** An accountant notices a missing number while reviewing invoices or
   during a client audit.

To confirm a gap manually:

```sql
-- Generate expected sequence and find missing numbers
WITH expected AS (
  SELECT generate_series(
    (SELECT MIN(sequence_number) FROM invoices
     WHERE series = '<series>' AND invoice_date >= '<period_start>'
       AND invoice_date <= '<period_end>'),
    (SELECT MAX(sequence_number) FROM invoices
     WHERE series = '<series>' AND invoice_date >= '<period_start>'
       AND invoice_date <= '<period_end>')
  ) AS seq_num
)
SELECT e.seq_num AS missing_number
FROM expected e
LEFT JOIN invoices i ON i.sequence_number = e.seq_num AND i.series = '<series>'
WHERE i.id IS NULL;
```

Note all missing sequence numbers before proceeding.

---

## Step 1 — Confirm the Gap

Verify the missing number does not exist in any invoice status, including `VOID`:

```sql
SELECT id, invoice_number, status, created_at, workflow_run_id
FROM invoices
WHERE series          = '<series>'
  AND sequence_number = <missing_number>;
```

If this query returns a row, there is no gap — the number is present in the database. The
detection logic may have used incorrect bounds. Re-evaluate the detection query and close.

If the query returns zero rows, the gap is confirmed. Proceed to root-cause analysis.

---

## Step 2 — Check VOID Invoices

`VOID` invoices retain their assigned sequence numbers. The gap detection query should include
`VOID` invoices, but confirm explicitly:

```sql
SELECT id, invoice_number, status, voided_at, void_reason
FROM invoices
WHERE series          = '<series>'
  AND sequence_number = <missing_number>
  AND status          = 'VOID';
```

If a `VOID` invoice holds the number, the gap is explained: the invoice was created and then
voided before being sent. The sequence number is legitimately consumed. Document this in
`decisions_log.md` and close the investigation. The VOID invoice itself satisfies the audit
requirement — it is retained in the system.

---

## Step 3 — Check Failed or Cancelled IN Workflow Runs

An IN workflow run that fails or is cancelled after the invoice generation phase (phase 2) may
have allocated a sequence number without completing the invoice row commit.

```sql
SELECT
  wr.id           AS run_id,
  wr.run_status,
  wr.failed_at,
  wr.cancelled_at,
  wr.last_phase_completed,
  wr.failure_reason
FROM workflow_runs wr
WHERE wr.business_entity_id = '<entity_id>'
  AND wr.workflow_type       = 'IN'
  AND wr.run_status          IN ('FAILED', 'CANCELLED')
  AND wr.created_at          BETWEEN '<period_start>' AND '<period_end>'
ORDER BY wr.created_at;
```

Cross-reference the `run_id` against `invoice_sequence_allocations` (if the table exists) or
against the run's event log to determine if a sequence number was allocated during that run.

If a match is found: the gap is caused by a failed allocation with no committed invoice row.
Proceed to Documentation.

---

## Step 4 — Check DRAFT Invoices Created and Then Deleted

If the system permits deleting `DRAFT` invoices (see `in_run_abort_policy.md`), a sequence
number may be consumed when the `DRAFT` is created and then lost when the draft is hard-deleted
before reaching `SENT` status.

```sql
SELECT id, invoice_number, sequence_number, status, deleted_at
FROM invoices
WHERE series          = '<series>'
  AND sequence_number = <missing_number>
  AND deleted_at      IS NOT NULL;
```

If a soft-deleted row exists, this is the cause. Document and close.

---

## Documentation

When the gap is confirmed and the cause is identified (failed allocation, hard-deleted draft, or
failed run), the gap must be documented in `decisions_log.md` with the following fields:

| Field | Value |
|---|---|
| `missing_invoice_number` | e.g. `INV-2025-0043` |
| `series` | e.g. `INV-2025` |
| `confirmed_cause` | One of: `FAILED_RUN_ALLOCATION`, `DRAFT_DELETED`, `VOID_INVOICE` |
| `run_id` | The `workflow_run_id` of the causative run (if applicable) |
| `date_investigated` | ISO 8601 date |
| `investigated_by` | `user_id` of the accountant |
| `audit_note` | Free-text explanation for the Cyprus Tax Department |

This documentation satisfies the Cyprus Tax Department audit requirement for explained sequence
gaps. Retain the entry for the full 7-year retention period.

---

## Escalation

If the gap cannot be explained by any of the above causes (no VOID invoice, no failed/cancelled
run, no deleted draft, no known database event), escalate to engineering for forensic review.
Do not document an unverified cause in `decisions_log.md`. Open a `MEDIUM` severity incident
with:

- The missing invoice number(s)
- The series and date range
- The results of all queries above (no matching rows in any check)
- The business entity ID and the period investigated

Engineering must review the database transaction logs and event store to identify whether a
sequence allocation event was emitted without a corresponding invoice commit.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `IN_WORKFLOW_SEQUENCE_GAP_DETECTED` | MEDIUM | Nightly gap detection job finds a gap |
| `IN_WORKFLOW_SEQUENCE_GAP_DOCUMENTED` | LOW | Gap documented in decisions_log |
| `IN_WORKFLOW_SEQUENCE_GAP_ESCALATED` | HIGH | Gap cause unknown, escalated to engineering |

---

## Cross-References

- `invoice_schema.md`
- `invoice_numbering_sequence_policy.md`
- `invoice_sequence_schema.md`
- `in_run_abort_policy.md`
- `decisions_log.md`
