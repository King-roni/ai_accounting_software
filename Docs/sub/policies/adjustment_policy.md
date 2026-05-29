# adjustment_policy.md

**Category:** Policies · Block 12 — OUT Workflow
**Cross-ref:** adjustment_schema.md, period_lock_policy.md, out_adjustment_policies.md, invoice_amendment_policy.md, vies_quarterly_eligibility_policy.md

---

## Overview

This policy governs how corrections are applied to FINALIZED accounting periods. A FINALIZED period is locked — its original ledger entries and finalization record are immutable. Adjustments are the only mechanism for correcting errors in locked periods. They work by adding new ledger entries that reference the originals, not by modifying the originals.

---

## Adjustment Definition

An adjustment is a correction applied to a FINALIZED period that:

- Creates new ledger entries in the correction_ledger_entry_ids array.
- References the original entries in original_ledger_entry_ids.
- Never modifies, deletes, or replaces any existing ledger entry.
- Preserves the period's finalization lock and finalized_at timestamp.

The adjustment leaves a complete before/after trail: the original entries remain visible; the correction entries are dated after the finalization and tagged with the adjustment_run_id.

---

## Who May Request an Adjustment

| Role | May Request |
|---|---|
| OWNER | Yes |
| ADMIN | Yes |
| ACCOUNTANT | No |
| VIEWER | No |

ACCOUNTANT role holders cannot initiate period adjustments. If an accountant identifies an error, they must raise it to an OWNER or ADMIN who will submit the request. This constraint is enforced at the API layer and audited.

---

## Adjustment Types

### VAT_CORRECTION

Applies when the VAT rate or VAT amount on a posted entry was incorrect. The correction replaces the VAT position with the correct values. If the correction affects intra-EU supply amounts, a VIES re-submission may be required (see VIES Consideration section).

### LEDGER_RECLASSIFICATION

Applies when a transaction was posted to the wrong account code. The correction moves the amount from the original account to the correct account. The VAT position is unaffected unless the reclassification crosses a VAT-treatment boundary.

### INVOICE_AMENDMENT

Applies when an issued invoice must be corrected. This type is jointly governed by invoice_amendment_policy.md. The adjustment creates a credit note for the original invoice and a replacement invoice with the corrected values. The replacement invoice receives a new invoice number from the standard sequence.

### MATCHING_CORRECTION

Applies when a bank transaction was matched to the wrong invoice or was incorrectly classified. The correction unmatches the original pairing and creates a new match record. If the original match affected VAT, a VAT_CORRECTION adjustment may be required in addition.

---

## Approval Requirement

All adjustments require:

1. An OWNER role holder to approve the request.
2. Step-up authentication at the time of approval. The step_up_token_id must reference a valid, unexpired step-up token issued to the approving user. Step-up tokens use gen_random_uuid() per step_up_token_schema.md.

An ADMIN can request an adjustment but cannot approve their own request. The approver must be a different user with OWNER role if the requester is ADMIN.

Approval transitions the record from PENDING_APPROVAL to APPROVED. This transition is blocked if step_up_token_id is not populated.

---

## Adjustment Run

When an adjustment is approved, the system creates a dedicated workflow run (adjustment_run_id) in the workflow_runs table. This run:

- Uses a condensed phase sequence tailored to the adjustment_type (ADJUSTING phases, not the full monthly phases).
- Executes only the gate checks relevant to the correction type.
- Runs through the standard run_status_enum states: CREATED → RUNNING → FINALIZING → FINALIZED.
- A failure transitions the run to FAILED; the adjustment_records.status remains APPROVED and may be retried.

The condensed phase sequence for each type is documented in out_adjustment_policies.md.

---

## Net VAT Impact

When the adjustment changes the VAT position:

1. net_vat_impact on the adjustment_records row is computed and stored (positive = additional VAT owed; negative = VAT reclaim).
2. The vat_periods record for the affected period is updated to reflect the new position.
3. If abs(net_vat_impact) > 50 EUR, the system creates a review flag for possible VIES amendment. The threshold and amendment workflow are defined in vies_quarterly_eligibility_policy.md.

Adjustments with zero VAT impact (e.g. a pure account reclassification within the same VAT treatment) leave net_vat_impact as NULL and do not update vat_periods.

---

## Period Lock Behaviour

An adjustment does not unlock the period. After the adjustment run completes:

- The period's finalized_at timestamp is unchanged.
- The original entries' locked status is unchanged.
- The new correction entries are appended to the period's ledger with their own created_at timestamps.
- The audit trail shows the full sequence: original finalization, adjustment request, approval, and correction entries.

---

## Amendment History and Traceability

Every adjustment is recorded in adjustment_schema.md. The record contains:

- The source run (the FINALIZED run being corrected).
- The adjustment run (the correction execution run).
- The original_ledger_entry_ids and correction_ledger_entry_ids arrays.
- The full approval chain including step_up_token_id.

This history is permanent. Adjustment records cannot be deleted.

---

## VIES Consideration

For VAT_CORRECTION adjustments where the corrected entries include intra-EU supply lines:

1. The system checks whether the correction affects amounts that were reported in a prior VIES submission.
2. If yes, a VIES amendment flag is created and surfaced to the OWNER for review.
3. The OWNER must confirm whether a VIES amendment is required before the adjustment run can transition to FINALIZED.

This gate is enforced by the adjustment run's finalization check. The VIES amendment workflow is defined in vies_quarterly_eligibility_policy.md.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| OUT_WORKFLOW_ADJUSTMENT_REQUESTED | LOW | adjustment_records row inserted with status = PENDING_APPROVAL |
| OUT_WORKFLOW_ADJUSTMENT_APPROVED | MEDIUM | status transitions to APPROVED with valid step_up_token_id |
| OUT_WORKFLOW_ADJUSTMENT_APPLIED | MEDIUM | status transitions to APPLIED; correction entries written |
| OUT_WORKFLOW_ADJUSTMENT_REJECTED | LOW | status transitions to REJECTED by OWNER |
