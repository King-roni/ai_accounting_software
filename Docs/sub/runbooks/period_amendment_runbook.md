# Runbook: Post-Period Amendment for a Finalized Accounting Period
**Category:** Runbooks · Block 12 — OUT Workflow
**Last updated:** 2026-05-17

---

## When to Use

Use this runbook when an error is confirmed in a `FINALIZED` accounting period and the error
is material — defined as a financial impact exceeding €50. Errors below €50 may be noted in
`decisions_log.md` without a formal amendment unless they affect a VAT return or VIES
submission.

Common amendment triggers:
- Wrong VAT rate applied to one or more transactions
- Transaction classified to the wrong account (misclassification)
- Invoice amount incorrect (requires amended invoice)
- Transaction matched to the wrong counterparty

Minor rounding errors (<€0.50) are auto-corrected by the rounding adjustment policy and do
not require this runbook.

---

## Eligibility

- Only users holding the `OWNER` or `ADMIN` role on the business entity may initiate an
  amendment.
- The period must be in `FINALIZED` status.
- Amendments cannot be initiated for periods in `FINALIZED` + `ARCHIVED` status where the
  archive date is older than 7 years. Those periods are in the immutable archive tier.
- If the period is currently in `RUNNING` or `REVIEW_HOLD`, do not use this runbook — correct
  the error in-place within the current run.

---

## Step 1 — Create the Adjustment Record

1. Navigate to the period in the Dashboard (Accounting → Periods → [period] → Details).
2. Click "Request Amendment".
3. Select the `adjustment_type` from:
   - `VAT_CORRECTION` — incorrect VAT rate or VAT treatment
   - `LEDGER_RECLASSIFICATION` — transaction posted to wrong account
   - `INVOICE_AMENDMENT` — invoice amount, date, or counterparty incorrect
   - `MATCHING_CORRECTION` — transaction matched to wrong invoice or counterparty
4. Describe the error and the intended correction in the free-text field (minimum 50 characters;
   this appears in the audit trail).
5. Submit. This creates a row in `adjustment_records` with `status = PENDING_APPROVAL` and
   assigns an `adjustment_id`.

Alternatively, via API:
```
adjustment.create(
  business_entity_id = '<entity_id>',
  period_id          = '<period_id>',
  adjustment_type    = '<type>',
  error_description  = '<description>',
  initiated_by       = '<user_id>'
)
```

---

## Step 2 — OWNER Approval

The amendment request is routed to the `OWNER` for approval. If the initiator is the `OWNER`,
the approval is still required — the OWNER approves their own amendment request after a
mandatory 10-minute review delay (anti-rubber-stamp control).

- Approval TTL: 72 hours (per `approval_expiry_policy.md`)
- Approval requires step-up auth from the OWNER
- If the approval expires, re-request via `review_queue.request_approval`
- Refer to `finalization_approval_runbook.md` Scenario 2 if the approval expires

On approval, `adjustment_records.status` transitions to `APPROVED` and the adjustment run is
created automatically.

---

## Step 3 — Adjustment Run

A dedicated OUT adjustment run is created (`adjustment_run_id`; `workflow_type = OUT_ADJUSTMENT`).
This run goes through a condensed phase set specific to the `adjustment_type`:

| Phase | Description |
|---|---|
| 1 | Validate adjustment inputs and confirm period eligibility |
| 2 | Apply correction logic (VAT recalculation, ledger reclassification, etc.) |
| 3 | Gate check: no new `BLOCKING` issues introduced by the correction |
| 4 | Accountant review sign-off |
| 5 | Finalize and archive |

The adjustment run inherits the same `run_status_enum` states as standard runs:
`CREATED → RUNNING → REVIEW_HOLD → AWAITING_APPROVAL → FINALIZING → FINALIZED`.

Monitor the run via:
```sql
SELECT run_status, last_phase_completed, updated_at
FROM workflow_runs
WHERE id = '<adjustment_run_id>';
```

---

## Step 4 — Ledger Correction

The adjustment run posts correction ledger entries that reference the original entries:

```sql
-- Verify correction entries are linked to originals
SELECT
  le.id,
  le.entry_type,
  le.amount,
  le.reference_entry_id,
  le.memo
FROM ledger_entries le
WHERE le.workflow_run_id = '<adjustment_run_id>'
ORDER BY le.created_at;
```

For `VAT_CORRECTION` adjustments, `vat_periods` totals are updated as part of the run.
Verify using the verification query in `vat_recalculation_runbook.md` Step 4.

For `INVOICE_AMENDMENT` adjustments, the original invoice is set to `status = SUPERSEDED`
and a new invoice is issued with an amended invoice number (original number + `/A`). The
Cyprus Tax Department requires the amended invoice to reference the original invoice number.

---

## Step 5 — Re-Archive

If the adjustment changes the contents of the accountant pack (e.g., a corrected invoice PDF,
updated VAT summary, or revised ledger report), a new archive bundle is created for the period:

- `archive_bundles.bundle_revision` is incremented (e.g., `revision 2`).
- The original archive bundle is retained (immutable) with `status = SUPERSEDED`.
- The new bundle becomes the `ACTIVE` archive for the period.

The re-archive step is handled automatically by the adjustment run's finalization phase. Confirm:
```sql
SELECT id, bundle_revision, status, created_at
FROM archive_bundles
WHERE period_id = '<period_id>'
ORDER BY bundle_revision DESC;
```

---

## VIES Impact

If the amendment affects transactions involving intra-EU supplies (counterparty
`vat_country_code != 'CY'`), the VIES quarterly submission may need amending:

1. Recalculate the affected quarter's VIES totals post-amendment.
2. If the revised total differs from the filed total by >€100, a VIES amendment is required.
3. Follow `vies_submission_failure_runbook.md` Scenario 4 (partial resubmission) for the
   amendment process.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `OUT_WORKFLOW_AMENDMENT_REQUESTED` | LOW | Adjustment record created |
| `OUT_WORKFLOW_ADJUSTMENT_APPROVED` | MEDIUM | OWNER approves the adjustment |
| `OUT_WORKFLOW_ADJUSTMENT_RUN_CREATED` | LOW | Adjustment run instantiated |
| `OUT_WORKFLOW_ADJUSTMENT_FINALIZED` | LOW | Adjustment run completes |
| `ARCHIVE_BUNDLE_REVISED` | LOW | New archive bundle created for period |
| `VIES_AMENDMENT_FLAGGED` | MEDIUM | VIES total deviation >€100 post-amendment |

---

## Cross-References

- `adjustment_schema.md`
- `adjustment_policy.md`
- `workflow_run_approvals_schema.md`
- `approval_expiry_policy.md`
- `vat_recalculation_runbook.md`
- `vies_submission_failure_runbook.md`
- `finalization_approval_runbook.md`
