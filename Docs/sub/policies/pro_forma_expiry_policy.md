# pro_forma_expiry_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Lifecycle rules for pro-forma invoices, specifically expiry, extension, and conversion. This policy is the normative source for the expiry sub-machine defined in `invoice_lifecycle_policy` and the `pro_forma_expires_at` field in `invoice_schema`. It binds the daily background job, the extension API, the conversion tool, and the audit events.

---

## Scope

Pro-forma invoices (`PRO_FORMA` type in `invoice_type_enum`) use the `PRO-YYYY-NNNN` sequence. They follow a restricted lifecycle sub-machine: they can be sent, extended once, converted to a `TAX_INVOICE`, or expired without conversion. This policy governs the expiry half of that sub-machine. Conversion rules are owned by `invoice_lifecycle_policy`.

The rules in this policy apply to all pro-forma invoices regardless of whether they were created manually or via a recurring template.

---

## Default expiry period

Pro-forma invoices expire 30 calendar days after their `issued_date` by default. The expiry timestamp is stored in `invoices.pro_forma_expires_at` at creation time:

```
pro_forma_expires_at = issued_date + INTERVAL '30 days'
```

The default is configurable per client via `clients.pro_forma_expiry_days` (Stage 2 field; MVP uses the system default of 30 days for all clients). Per recurring invoice templates, the `recurring_invoice_templates.pro_forma_expiry_days` column overrides the default.

The `pro_forma_expires_at` column is nullable in `invoice_schema` with `CHECK (pro_forma_expires_at IS NULL OR invoice_type = 'PRO_FORMA')`. For `TAX_INVOICE` and `CREDIT_NOTE` rows, the column is always null.

---

## Expiry enforcement

Expiry is enforced application-side by a daily background job. There are no database triggers for expiry — triggers would couple expiry to arbitrary transaction timing and make the audit trail harder to reason about. The background job is registered with the Block 03 Phase 09 scheduler.

### Job behaviour

The daily integrity job (`in_workflow.expire_pro_formas_daily`) runs at 02:00 UTC each day and executes the following scan:

```sql
SELECT invoice_id
FROM invoices
WHERE invoice_type = 'PRO_FORMA'
  AND pro_forma_expires_at <= now()
  AND status NOT IN ('FINALIZED', 'EXPIRED_UNCONVERTED', 'CREDITED', 'WRITTEN_OFF');
```

For each matching row, the job calls `in_workflow.expire_pro_forma` which:
1. Transitions `status` to `EXPIRED_UNCONVERTED` (terminal).
2. Sets `status_changed_at = now()` and `status_changed_by = NULL` (system-initiated).
3. Emits `PRO_FORMA_EXPIRED` (LOW).

The transition is atomic per invoice row. A failure on any individual row is logged and the job continues to the next row; a compensation pass runs at the next job execution for any rows that did not transition.

### Expiry-soon notification

Three calendar days before `pro_forma_expires_at`, the job (`in_workflow.notify_pro_forma_expiry_soon`) emits `INVOICE_PRO_FORMA_EXPIRING_SOON` (LOW). This event is consumed by Block 16's notification dispatcher to send an in-app or email reminder to the business owner.

The 3-day look-ahead query:

```sql
SELECT invoice_id
FROM invoices
WHERE invoice_type = 'PRO_FORMA'
  AND pro_forma_expires_at BETWEEN now() AND now() + INTERVAL '3 days'
  AND status = 'SENT';
```

`INVOICE_PRO_FORMA_EXPIRING_SOON` may be emitted on multiple consecutive days if the invoice remains unconverted. Downstream notification deduplication (Block 16) is responsible for suppressing repeat notifications if the business has already been notified within the same 3-day window.

---

## Conversion to tax invoice

A `PRO_FORMA` invoice in `SENT` status may be converted to a `TAX_INVOICE` via `in_workflow.convert_pro_forma_to_tax_invoice`. On conversion:

1. A new `invoices` row is created with `invoice_type = 'TAX_INVOICE'`, copying `client_id`, `lines_payload`, `currency`, `vat_treatment`, and amount fields from the pro-forma.
2. The new `TAX_INVOICE` starts in `DRAFT` and a fresh `INV-YYYY-NNNN` number is allocated at its `DRAFT → SENT` transition.
3. The source `PRO_FORMA` row transitions to `status = EXPIRED_UNCONVERTED` with `status_changed_by = <requesting_user_id>`. This is terminal for the pro-forma row.
4. Audit event `INVOICE_PRO_FORMA_CONVERTED_TO_TAX` is emitted (domain `INVOICE`).

An expired pro-forma (status `EXPIRED_UNCONVERTED`) cannot be converted. A new pro-forma or direct tax invoice must be created for the same client. The conversion tool (`in_workflow.convert_pro_forma_to_tax_invoice`) rejects conversion attempts on expired pro-formas with a structured error before any state change.

---

## Manual extension

A `PRO_FORMA` invoice in `SENT` status may be manually extended once by a user with Owner or Admin role. The extension sets a new `pro_forma_expires_at` beyond the original value.

### Extension rules

1. **One extension per pro-forma.** The extension flag is tracked via the `pro_forma_extended` boolean column on the `invoices` table (Stage 2 addition; in MVP, the extension count is derived from the audit log). Once a pro-forma has been extended, subsequent extension attempts are rejected with a structured error.

2. **Extension deadline.** The new `pro_forma_expires_at` must satisfy both of the following:
   - `new_expires_at > now()` (extension cannot backdate or set to the past).
   - `new_expires_at <= original_issued_date + INTERVAL '60 days'` (the maximum lifetime of a pro-forma, including any extension, is 60 days from issue date). This cap is non-negotiable and is enforced in `in_workflow.extend_pro_forma` before the UPDATE.

3. **Permission.** Owner and Admin only. Bookkeeper, Accountant, Reviewer, and Read-only roles are denied. Any extension attempt from `client_form_factor = MOBILE` is rejected with `MOBILE_WRITE_REJECTED` before the permission check per `mobile_write_rejection_endpoints`.

4. **Audit event.** `INVOICE_PRO_FORMA_EXTENDED` (MEDIUM) is emitted with payload including `invoice_id`, `original_expires_at`, `new_expires_at`, `extended_by_user_id`, and `extended_at`. The MEDIUM severity reflects that an extension modifies a time-bound financial document.

---

## Cancellation

A `PRO_FORMA` invoice in `DRAFT` or `SENT` status may be cancelled by Owner or Admin via `in_workflow.cancel_pro_forma`. Cancellation:

1. Transitions `status` to `EXPIRED_UNCONVERTED` (the same terminal state used by both expiry and conversion-side termination). There is no separate `CANCELLED` status for pro-formas; the lifecycle converges on `EXPIRED_UNCONVERTED`.
2. Emits `INVOICE_PRO_FORMA_CANCELLED` (LOW).
3. Does NOT decrement the `PRO-YYYY-NNNN` sequence. Per `invoice_lifecycle_policy`, the `PRO` sequence is gap-free and monotonically increasing; cancelling a pro-forma does not release its allocated number. The number remains in the audit trail tied to the cancelled row.

### Mobile write rejection

Cancellation is a write operation. Any cancellation attempt from `client_form_factor = MOBILE` is rejected with `MOBILE_WRITE_REJECTED`. Reference: `mobile_write_rejection_endpoints.md`.

---

## Interaction with the finalization lock

A pro-forma invoice in `DRAFT` or `SENT` status at the time of Block 15's finalization lock is finalized as-is (status transitions to `FINALIZED` via `in_workflow.finalize_invoice`). A finalized pro-forma in `SENT` status cannot be converted, extended, or expired post-finalization — the `FINALIZED` status is terminal per `invoice_lifecycle_policy`. The daily expiry job excludes rows with `status = 'FINALIZED'`.

---

## Summary of pro-forma lifecycle states

| Status | Description | Terminal? |
| --- | --- | --- |
| `DRAFT` | Created but not yet sent | No |
| `SENT` | Sent to client; awaiting conversion, expiry, or cancellation | No |
| `EXPIRED_UNCONVERTED` | Reached `pro_forma_expires_at` without conversion; OR cancelled; OR source of a conversion | **Yes** |
| `FINALIZED` | Sealed by Block 15 lock sequence | **Yes** |

---

## Audit events summary

| Event | Domain | Severity | Trigger |
| --- | --- | --- | --- |
| `INVOICE_PRO_FORMA_EXPIRING_SOON` | INVOICE | LOW | Daily job; pro-forma expires within 3 days |
| `INVOICE_PRO_FORMA_EXPIRED` | INVOICE | LOW | Daily job transitions `status = EXPIRED_UNCONVERTED` |
| `INVOICE_PRO_FORMA_EXTENDED` | INVOICE | MEDIUM | Owner/Admin manually extends `pro_forma_expires_at` |
| `INVOICE_PRO_FORMA_CANCELLED` | INVOICE | LOW | Owner/Admin cancels a `DRAFT` or `SENT` pro-forma |

All events use the `INVOICE` domain per the `<DOMAIN>_<PAST_VERB>` convention from `audit_log_policies`. The domain allowlist for Block 13 includes `INVOICE`; there is no separate `PRO_FORMA` domain. The events follow the pattern `INVOICE_PRO_FORMA_<VERB>` where `PRO_FORMA_<VERB>` is the multi-word past verb phrase.

---

## Cross-references

- `invoice_schema` — `invoice_type_enum`, `invoice_status_enum`, `pro_forma_expires_at` column definition
- `invoice_lifecycle_policy` — PRO_FORMA sub-machine; `EXPIRED_UNCONVERTED` terminal state; gap-free sequence rule
- `audit_log_policies` — `INVOICE` domain; past-tense event naming; no separate `PRO_FORMA` domain
- `audit_event_taxonomy` — `INVOICE_PRO_FORMA_EXPIRING_SOON`, `INVOICE_PRO_FORMA_EXPIRED` (existing), `INVOICE_PRO_FORMA_EXTENDED`, `INVOICE_PRO_FORMA_CANCELLED` under INVOICE domain
- `data_layer_conventions_policy` — canonical JSON for audit payloads
- `mobile_write_rejection_endpoints` — mobile write rejection for extension and cancellation
- Block 13 Phase 05 — pro-forma expiry implementation; daily job registration; scheduler contract
- Block 03 Phase 09 — scheduler framework for the daily expiry job
- Block 16 — notification dispatcher consuming `INVOICE_PRO_FORMA_EXPIRING_SOON`
