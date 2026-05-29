# Invoice Draft Staleness Policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

**Purpose.** Define when a DRAFT invoice is considered stale, how the system detects it, what the accountant can do about it, and the conditions under which auto-voiding applies. This policy governs the background detection job, the review issue it raises, the snooze and resolution paths, and the optional auto-archive path controlled by a per-business config flag.

---

## Staleness threshold

A DRAFT invoice is stale when both of the following are true simultaneously:

1. `invoices.status = 'DRAFT'`
2. `invoices.created_at < now() - INTERVAL '30 days'`

The 30-calendar-day window is measured from `created_at`, not from the last amendment. Amending a DRAFT invoice (updating line items, due date, or any other field) does not reset the staleness clock; only issuing or voiding the invoice clears stale status.

Invoices in any status other than `DRAFT` are never evaluated by this policy.

---

## Detection

A background job (`engine.detect_stale_drafts`) runs daily at 02:00 UTC. On each run it executes:

```sql
SELECT id
FROM   invoices
WHERE  status = 'DRAFT'
  AND  created_at < now() - INTERVAL '30 days'
  AND  business_id = ANY(active_business_ids())
  AND  NOT EXISTS (
         SELECT 1
         FROM   review_issues ri
         WHERE  ri.subject_id = invoices.id
           AND  ri.issue_type = 'INVOICE_DRAFT_STALE'
           AND  ri.status NOT IN ('RESOLVED', 'DISMISSED')
       );
```

The `NOT EXISTS` subquery prevents duplicate issue creation: if an active stale issue already exists for the invoice, the job skips it. This makes the job idempotent on repeated runs.

For each qualifying row, the job calls `review_queue.create_issue` with:

```json
{
  "issue_type": "INVOICE_DRAFT_STALE",
  "subject_id": "<invoice_id>",
  "subject_type": "INVOICE",
  "severity": "LOW",
  "issue_group": "INVOICE_REVIEW",
  "context": {
    "invoice_number": null,
    "client_id": "<client_id>",
    "created_at": "<iso8601>",
    "days_stale": "<integer>"
  }
}
```

Note: DRAFT invoices have no allocated invoice number (`invoice_number = null`). The `context.days_stale` field is computed as `EXTRACT(DAY FROM now() - created_at)` at detection time.

**Audit event emitted:** `INVOICE_DRAFT_STALE_DETECTED` (LOW) — one event per invoice per detection cycle.

---

## Review issue properties

| Property | Value |
|---|---|
| `issue_type` | `INVOICE_DRAFT_STALE` |
| `issue_group` | `INVOICE_REVIEW` |
| Severity | LOW |
| Auto-resolve eligible | Yes — resolved automatically if the invoice transitions to `SENT` or `VOIDED` while the issue is open |
| Snoozeable | Yes — accountant may snooze to defer the notification |
| Bulk-resolvable | Yes — LOW severity; not excluded from `BULK_RESOLVE` |

The invoice itself remains in `DRAFT` when the review issue is raised. The system does NOT auto-archive or auto-void the invoice solely on the basis of staleness detection. The accountant must act explicitly.

---

## Accountant options

Three explicit actions are available from the review queue card for a `INVOICE_DRAFT_STALE` issue:

### Option 1 — Issue the invoice

The accountant completes the invoice (adds or confirms line items, verifies the due date, and confirms the client) and calls `in_workflow.issue_invoice`. The invoice transitions from `DRAFT` to `SENT`. The review issue is auto-resolved on the `status` transition. `INVOICE_SENT` is emitted.

### Option 2 — Void the invoice

The accountant determines the invoice is no longer needed and calls `in_workflow.void_invoice` with `void_reason = 'STALE_MANUALLY_VOIDED'`. The invoice transitions to `VOIDED`. The review issue is auto-resolved on the `status` transition. `INVOICE_VOIDED` is emitted.

### Option 3 — Snooze the review issue

The accountant defers the notification by snoozing the issue per `snooze_carry_forward_policy`. The invoice remains in `DRAFT`; the issue is marked `SNOOZED` until the snooze window expires or the data record changes. `REVIEW_QUEUE_ISSUE_SNOOZED` is emitted. The staleness detection job will not re-raise the issue while an active snooze is in effect.

---

## Auto-archive path (optional)

Auto-voiding activates only when both conditions are met:

1. The business configuration has `auto_archive_stale_drafts = true` (default: `false`).
2. The invoice has been in `DRAFT` status for more than **90 calendar days** without being issued, voided, or actioned.

The 90-day clock is measured from `created_at`, consistent with the 30-day detection threshold (the auto-void fires 60 days after the initial stale detection, not 90 days after the last action).

When both conditions are met, the background job transitions the invoice to `VOIDED` with:

```json
{
  "void_reason": "STALE_AUTO_VOIDED",
  "voided_by": "SYSTEM",
  "voided_at": "<iso8601>"
}
```

Any open `INVOICE_DRAFT_STALE` review issue is auto-resolved on the void transition.

**Audit event emitted:** `INVOICE_STALE_AUTO_VOIDED` (LOW) — one event per auto-voided invoice. Payload includes `invoice_id`, `business_id`, `created_at`, `days_stale`, `auto_archive_config_flag`.

### Business config precedence

`auto_archive_stale_drafts` is a per-business flag in `business_workflow_configs`. Platform admin may set a global default; individual businesses override it. The flag is surfaced in the business settings UI. Changing the flag does not retroactively alter invoices already past 90 days — the next daily job run applies the new flag value.

---

## Audit events

| Event | Severity | Emitted by |
|---|---|---|
| `INVOICE_DRAFT_STALE_DETECTED` | LOW | `engine.detect_stale_drafts` background job |
| `INVOICE_STALE_AUTO_VOIDED` | LOW | `engine.detect_stale_drafts` background job (auto-archive path only) |

Both events are scoped to the business chain of the audit log.

---

## Interaction with snooze carry-forward

When a stale draft issue is snoozed and the IN_MONTHLY run for the next period begins, `review_queue.unsnooze_at_run_start` evaluates carry-forward rules per `snooze_carry_forward_policy`. A `INVOICE_DRAFT_STALE` issue carried forward into a new run increments `carry_forward_count`. If `carry_forward_count` reaches the escalation threshold, severity escalates from LOW to MEDIUM and the snooze is cleared per the escalation rule.

---

## Cross-references

- `invoice_lifecycle_ui_spec.md` — UI state transitions and accountant action surfaces for DRAFT invoices
- `review_queue_rescan_on_resolution_policy.md` — auto-resolution trigger when invoice status changes
- `snooze_carry_forward_policy.md` — snooze mechanics, carry-forward escalation thresholds
