# invoice_amendment_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Rules governing amendment of issued invoices. This policy is the normative source for all code paths that modify an existing invoice after creation. The `invoice_schema` defines the data model; `invoice_lifecycle_policy` defines the state machine. This policy governs the amendment semantics layered on top of those.

---

## 1. DRAFT invoice — free editing

A `DRAFT` invoice may be freely edited by Owner, Admin, or Bookkeeper. There is no restriction on the number of edits, nor on which fields may be changed. Line items may be added, removed, or modified. The sequence number has not yet been allocated (per `invoice_lifecycle_policy` Section "Number allocation at DRAFT exit"), so no audit trail of the number is created.

Edit operations on a `DRAFT` invoice emit `INVOICE_AMENDED` (severity `LOW`).

Bookkeepers may edit `DRAFT` invoices. They may not perform any amendment operation on a non-DRAFT (SENT or later) invoice. Role enforcement is at the application layer via the permission matrix (`permission_matrix`).

---

## 2. SENT invoice — void-and-reissue is the only amendment path

A SENT invoice (any invoice with `status` outside `DRAFT`) may not be amended by direct field update. Direct writes to field values on a SENT invoice row are forbidden. The state machine in `invoice_lifecycle_policy` does not define a field-update transition; any attempt to UPDATE a SENT invoice outside the defined lifecycle tools returns a structured error and emits `INVOICE_LIFECYCLE_TRANSITION_FAILED`.

The only supported amendment path for a SENT invoice is:

1. Void the original invoice via `in_workflow.void_invoice`.
2. Create a replacement invoice via `in_workflow.create_invoice` with the corrected data.
3. Issue the replacement via `in_workflow.send_invoice`.

---

## 3. Voiding a SENT invoice — rules

Voiding requires:

- **Role:** Owner or Admin. Bookkeeper role is denied. Accountant, Reviewer, and Read-only roles are denied.
- **Mandatory `void_reason`:** A non-empty text reason must be provided. Blank strings are rejected at the application layer.
- **Step-up MFA:** Not required for voiding alone. Step-up MFA is required only for finalization-period operations per `archive_step_up_policy`.
- **Period not finalized:** See Section 5 below.

When `in_workflow.void_invoice` is called:

1. The invoice `status` transitions to a voided terminal state (the credit note issuance handles the balance; the original invoice row's status is set appropriately per the credit note path in `invoice_lifecycle_policy`).
2. A credit note is automatically created: a new `invoices` row with `invoice_type = CREDIT_NOTE` and `against_invoice_id` referencing the voided invoice. The credit note represents the full original amount and offsets the original invoice's ledger entry.
3. The credit note is allocated a `CN-YYYY-NNNN` sequence number immediately at issuance (credit notes are never drafted; number allocation fires at creation per `invoice_lifecycle_policy`).
4. `INVOICE_VOIDED` (severity `MEDIUM`) is emitted.
5. `CREDIT_NOTE_ISSUED` is emitted when the credit note number is allocated.

The credit note amount is the full `total_amount` of the voided invoice. Partial-amount credit notes for amendment purposes are not supported via this path; the full void-and-reissue pattern is required.

---

## 4. Sequence number retirement after voiding

The original invoice's sequence number (`INV-YYYY-NNNN`) is retired. A gap in the `INV` sequence is expected and intentional — the void event is the audit trail that explains the gap. Operators, auditors, and regulators reviewing the sequence should cross-reference `INVOICE_VOIDED` in the audit log for any gap in the `INV` sequence.

No attempt is made to reuse or reallocate the retired sequence number. The Postgres sequence for the business-year pair (`inv_seq_<business_id>_<year>`) is monotonically increasing and non-rewindable.

`INVOICE_NUMBER_GAP_DETECTED` is emitted if the sequence integrity checker (Block 13 Phase 01) observes a gap during its periodic scan. This event is informational; the gap is expected when a void has occurred, and the checker cross-references the `INVOICE_VOIDED` events to distinguish expected gaps from unexpected ones.

---

## 5. Invoices in a FINALIZED period — IN_ADJUSTMENT required

An invoice for a finalized period cannot be voided or amended via `in_workflow.void_invoice`. The period finalization lock (Block 15) seals all invoice rows for the period. Any attempt to void a finalized invoice returns a structured error: "Period is finalized. Create an IN_ADJUSTMENT run to amend invoices for this period."

The `IN_ADJUSTMENT` run creates adjustment records that offset the original invoice's effect in the ledger without modifying the locked invoice row. Per `workflow_state_enum`, `IN_ADJUSTMENT` runs may coexist with subsequent monthly runs for the same business.

---

## 6. Replacement invoice numbering

The replacement invoice created after a void receives a new, independent `INV-YYYY-NNNN` sequence number at its first `DRAFT → SENT` transition. The replacement does not inherit the voided invoice's number and does not reference the voided invoice's number in its own number field.

The `against_invoice_id` on the credit note links the credit note to the original invoice; the replacement invoice is linked to neither the original nor the credit note at the schema level. Business logic and reporting layers may correlate them via the `void_reason` text and the `INVOICE_VOIDED` audit event's payload, which records both the original `invoice_id` and the `credit_note_id`.

---

## 7. DRAFT amendments — no sequence number consumed

Editing a `DRAFT` invoice (Section 1) does not consume a sequence number. Sequence numbers are allocated only at `DRAFT → SENT` transitions per `invoice_lifecycle_policy`. Deleting a `DRAFT` invoice also does not consume a number. There is no DELETE path on a non-`DRAFT` invoice.

---

## 8. Role restrictions summary

| Operation | Bookkeeper | Admin | Owner |
| --- | --- | --- | --- |
| Edit `DRAFT` invoice fields and line items | Permitted | Permitted | Permitted |
| Void a SENT invoice (`in_workflow.void_invoice`) | Denied | Permitted | Permitted |
| Create replacement after void | Permitted (creates DRAFT) | Permitted | Permitted |
| Void in finalized period | N/A (blocked system-wide) | N/A | N/A |

Accountant, Reviewer, and Read-only roles have no write access to invoice amendment paths.

---

## 9. Mobile client restriction

All amendment operations — including `DRAFT` edits, voiding, and replacement invoice creation — are rejected for sessions where `client_form_factor = MOBILE`. Any mutation attempt from a mobile client is rejected before the permission check with `MOBILE_WRITE_REJECTED` per `mobile_write_rejection_endpoints.md`. Mobile clients may read invoice records.

This applies equally to `DRAFT` edits (which are otherwise unrestricted for eligible roles). The restriction is form-factor based, not role based.

---

## 10. Ledger implications of voiding

When `in_workflow.void_invoice` is called, the credit note creation triggers a ledger lifecycle entry via `ledger.prepare_invoice_lifecycle_entries` (Block 11 Phase 07). This produces the offsetting ledger entry that reverses the income recognised on the original invoice.

The ledger tool is called synchronously within the same transaction that creates the credit note row. If the ledger tool fails, the entire transaction rolls back and the original invoice remains in its prior state with no void recorded.

---

## 11. Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `INVOICE_AMENDED` | LOW | Any field edit on a `DRAFT` invoice (all field mutations) |
| `INVOICE_VOIDED` | MEDIUM | `in_workflow.void_invoice` completes; original invoice transitions to voided state |
| `CREDIT_NOTE_CREATED` | LOW | Credit note row inserted as part of void |
| `CREDIT_NOTE_ISSUED` | LOW | Credit note `CN-YYYY-NNNN` number allocated |
| `INVOICE_NUMBER_GAP_DETECTED` | LOW | Periodic sequence integrity checker detects an `INV` gap |
| `INVOICE_LIFECYCLE_TRANSITION_FAILED` | MEDIUM | Illegal transition attempt (e.g., direct field update on SENT invoice) |
| `MOBILE_WRITE_REJECTED` | LOW | Amendment attempt from a mobile client |

`INVOICE_VOIDED` and `INVOICE_AMENDED` are in the `INVOICE` domain per `audit_log_policies`.

---

## Cross-references

- `invoice_schema` — `invoice_type_enum`; `invoice_status_enum`; `against_invoice_id`; `invoice_number`; sequence allocation timing; credit-note cap invariant
- `invoice_lifecycle_policy` — state machine; `DRAFT → SENT` guard; credit note creation (`in_workflow.issue_credit_note`); terminal states
- `invoice_sequence_schema` — `INV-YYYY-NNNN`, `CN-YYYY-NNNN` sequence mechanics; gap detection
- `credit_note_schema` — `CN-YYYY-NNNN` row structure; `against_invoice_id` FK; `ISSUED` credit note immutability
- `audit_event_taxonomy` — `INVOICE_VOIDED`, `INVOICE_AMENDED`, `CREDIT_NOTE_ISSUED`, `CREDIT_NOTE_CREATED` under INVOICE and CREDIT_NOTE domains
- `audit_log_policies` — `INVOICE` domain; past-tense event naming
- `permission_matrix` — Owner/Admin restriction on void; Bookkeeper restriction to DRAFT only
- `mobile_write_rejection_endpoints.md` — form-factor rejection applied to all amendment surfaces
- `archive_step_up_policy` — step-up MFA for finalization-period operations; finalized-period block
- `in_phase_gate_policy` — finalization gate; IN_ADJUSTMENT as the path for finalized-period amendments
- Block 13 Phase 01 — sequence allocator; gap detection periodic scan
- Block 13 Phase 03 — `invoice.markVoided`; `invoice.markCredited`; credit note lifecycle
- Block 11 Phase 07 — `ledger.prepare_invoice_lifecycle_entries`; income reversal on void
- Block 15 Phase 04 — period finalization lock; sealed invoice rows
