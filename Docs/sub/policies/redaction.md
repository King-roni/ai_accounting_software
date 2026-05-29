# Redaction Policy

**Category:** Policies · Block 05 — Security & Audit
**Status:** Active
**Last updated:** 2026-05-17

---

## 1. Definition

Redaction is the irreversible replacement of PII and sensitive field values with the fixed token `[REDACTED]` directly in the database. The replacement is a destructive, unrecoverable write — no original value is retained in any live table after the operation completes.

Redaction occurs in two modes:

- **At-write redaction** — applied during inbound data ingestion, before the value is persisted (governed by `redaction_at_write_policy.md`).
- **On-demand redaction** — applied to already-stored rows, triggered by one of the conditions listed in section 4.

---

## 2. Scope — Fields Subject to Redaction

Field eligibility is defined in `redaction_field_map.md`. The primary categories are:

### 2.1 Counterparty PII

Fields on counterparty records where the counterparty is a natural person (non-business entity):

| Table | Field |
|---|---|
| `counterparties` | `full_name` |
| `counterparties` | `address_line_1`, `address_line_2`, `city`, `postal_code` |
| `counterparties` | `vat_number` (non-business only) |
| `counterparties` | `email`, `phone` |

Business counterparties (counterparty_type = `BUSINESS`) are exempt from name and VAT redaction — those fields are public commercial identifiers.

### 2.2 Bank Statement Raw Description Text

The raw unparsed description field on bank statement rows:

| Table | Field |
|---|---|
| `bank_statement_rows` | `raw_description` |

The canonical parsed fields (`amount`, `value_date`, `counterparty_iban`, `canonical_reference`) are never redacted — they are required for ledger continuity.

### 2.3 Document Metadata Personal Names

Fields containing personal names in document metadata that are not required for accounting:

| Table | Field |
|---|---|
| `document_metadata` | `uploaded_by_display_name` (where not a member of the business) |
| `document_metadata` | `signatory_name` (on non-accounting documents) |

---

## 3. What Is Never Redacted

The following data is permanently exempt from redaction regardless of trigger:

- **`audit_log` rows** — the audit log is append-only and tamper-evident. No field in any `audit_log` row may be modified after insertion. Redaction requests that would require modifying audit log rows are rejected silently; the original audit log entry is preserved.
- **`ledger_entries` rows** — financial records are required under Cyprus Tax Department retention rules. Amount, account codes, period, and transaction references are never redacted.
- **Invoice numbers** — `invoices.invoice_number` is a legal sequence number and is never redacted.
- **Invoice and credit note amounts** — `invoices.total_amount`, `invoices.vat_amount`, and equivalent credit note fields are never redacted.
- **Business entity identifiers** — `business_entities.id`, `.registration_number`, `.vat_number` are never redacted.

---

## 4. Redaction Triggers

Redaction is initiated by exactly three triggers:

### 4.1 GDPR Erasure Request

A data subject submits a right-to-erasure request via the in-app form or directly to the Data Controller. The DPO reviews the request, confirms the data subject identity, and issues an erasure order through the admin panel. The erasure order specifies the subject's counterparty ID(s) and/or user ID.

### 4.2 Business Account Deactivation — Post-Retention Window

When a business account is deactivated and the operational retention window defined in `data_retention_policy.md` has elapsed, a scheduled job triggers on-demand redaction of all PII fields belonging to that business. The retention window is not bypassed — redaction does not occur at deactivation time but only after the window closes.

### 4.3 Explicit ADMIN Action with Step-Up Auth

An ADMIN user may manually trigger redaction of a specific row or field set via the admin panel. The action requires a step-up authentication challenge (`auth.request_step_up` with `purpose = OWNERSHIP_TRANSFER` or an explicit `REDACTION_ADMIN` purpose where configured). The triggering admin's `user_id` is recorded in `redaction_records`.

---

## 5. Redaction Record

Every on-demand redaction operation produces one or more rows in the `redaction_records` table. Schema:

```sql
CREATE TABLE redaction_records (
  id               uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  table_name       text        NOT NULL,
  row_id           uuid        NOT NULL,
  field_path       text        NOT NULL,
  redacted_at      timestamptz NOT NULL DEFAULT now(),
  redacted_by_user_id uuid     REFERENCES users(id),
  redaction_trigger text       NOT NULL
    CHECK (redaction_trigger IN ('GDPR_ERASURE', 'ACCOUNT_DEACTIVATION', 'ADMIN_MANUAL')),
  business_id      uuid        REFERENCES business_entities(id)
);
```

`field_path` uses dot notation (e.g. `counterparties.full_name`). One row is written per field per redacted record.

---

## 6. Post-Redaction Re-ingestion Guard

`redaction_at_write_policy.md` specifies that if raw source data matching a redacted counterparty identifier is re-ingested (e.g. a bank statement re-upload containing the same IBAN), the at-write redaction rules apply immediately. The pipeline never restores a previously redacted field. This is enforced by a `redacted_identifiers` blocklist table keyed on `business_id + canonical_identifier`.

---

## 7. Verification Pass

After every on-demand redaction operation, the system executes a verification pass:

1. Re-reads every targeted field from the database.
2. Asserts each field value equals `[REDACTED]`.
3. If any field does not match:
   - Logs `SECURITY_REDACTION_INCOMPLETE` (HIGH) to the audit log, including `table_name`, `row_id`, and `field_path`.
   - Marks the `redaction_records` row as `status = 'INCOMPLETE'`.
   - Triggers an alert to the security notification channel.

The operation is not retried automatically — manual intervention is required to resolve an incomplete redaction.

---

## 8. Document Files

Raw document files stored in the Processing or Archive zones that contain PII subject to an erasure order are handled as follows:

1. The document redaction service generates a redacted PDF/image with the relevant content masked.
2. The redacted version replaces the original at the same storage path.
3. The original file bytes are deleted from object storage immediately after the replacement is confirmed.
4. The `document_metadata.file_hash` field is updated to reflect the redacted file's hash.
5. A `redaction_records` row is written for each affected document with `field_path = 'document_files.raw_bytes'`.

---

## 9. Audit Events

| Event | Severity | Description |
|---|---|---|
| `SECURITY_REDACTION_APPLIED` | MEDIUM | One or more fields were successfully redacted in a row. Emitted once per row, not per field. |
| `SECURITY_REDACTION_INCOMPLETE` | HIGH | Verification pass detected a field that was not successfully redacted. |

---

## 10. Cross-references

- `redaction_at_write_policy.md` — at-write redaction rules for inbound data
- `redaction_field_map.md` — complete enumeration of redactable fields by table
- `data_retention_policy.md` — retention windows that govern deactivation-triggered redaction
- `audit_log_policies.md` — why audit log rows are exempt from redaction
- `redaction_policies.md` — parent policy document (overview)
