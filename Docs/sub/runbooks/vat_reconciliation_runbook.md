# Runbook: VAT Reconciliation

**Namespace:** `report`
**Owning block:** 16 — Reporting & VAT
**Stage:** 4 sub-doc (Layer 3 operational runbook)

---

## Purpose

This runbook describes how to investigate and resolve a discrepancy between the VAT return totals as computed by the system and the expected values for an accounting period. It covers the most common triggers, the SQL queries used to identify mismatched transactions, the process for amending a VAT return before and after submission, and the relationship between tools and schemas involved.

---

## 1. What Triggers a VAT Reconciliation

A VAT reconciliation is required in the following situations:

**1.1 Period close discrepancy**

During OUT workflow completion (`tool_out_workflow_complete.md`), the system computes a VAT summary from `vat_entries`. If the computed output VAT total or input VAT total differs from the `vat_return` row's previously stored estimate by more than 0.01 EUR, a `REVIEW_HOLD` is triggered with `hold_reason = 'VAT_TOTALS_MISMATCH'`. The accountant must investigate before the run can be completed.

**1.2 Amended bank statement**

When a bank statement is re-imported for a period that has already been processed (via `tool_manual_upload_re_entry.md`), any existing matched expense or income line linked to the amended statement may need reclassification. If the reclassification changes a VAT category, the `vat_return` row must be recomputed.

**1.3 Reclassified expense after partial submission**

If an expense is reclassified after the VAT return has been moved to `SENT` or `PAID` status, the reclassification creates a delta that is not reflected in the submitted return. The accountant must decide whether to file an amendment with the Cyprus Tax Department.

---

## 2. Step-by-Step Investigation

### Step 2.1 — Identify the period and run

```sql
SELECT vr.id AS vat_return_id,
       vr.period_id,
       vr.status,
       vr.output_vat_total,
       vr.input_vat_total,
       vr.net_vat_payable,
       wr.id AS run_id,
       wr.run_status
FROM vat_returns vr
JOIN workflow_runs wr ON wr.period_id = vr.period_id
                      AND wr.business_entity_id = vr.business_entity_id
WHERE vr.business_entity_id = $business_entity_id
  AND vr.period_id          = $period_id
ORDER BY vr.created_at DESC
LIMIT 1;
```

### Step 2.2 — Recompute expected VAT totals from source data

```sql
-- Output VAT (from invoices issued)
SELECT SUM(vat_amount) AS computed_output_vat
FROM invoices
WHERE business_entity_id = $business_entity_id
  AND period_id           = $period_id
  AND status             != 'VOID';

-- Input VAT recoverable (from classified expenses)
SELECT SUM(vat_recoverable_amount) AS computed_input_vat
FROM expenses
WHERE business_entity_id = $business_entity_id
  AND run_id IN (
    SELECT id FROM workflow_runs
    WHERE period_id = $period_id
      AND business_entity_id = $business_entity_id
      AND workflow_type = 'OUT_WORKFLOW'
  )
  AND status IN ('CLASSIFIED','MATCHED','LOCKED');
```

Compare results to `vat_returns.output_vat_total` and `vat_returns.input_vat_total`. Any difference greater than 0.01 EUR is a reconciliation discrepancy.

### Step 2.3 — Identify mismatched transactions

```sql
-- Expenses whose vat_amount changed after VAT return was computed
SELECT e.id,
       e.supplier_name,
       e.expense_date,
       e.vat_amount,
       e.vat_recoverable_amount,
       e.vat_category,
       e.updated_at
FROM expenses e
WHERE e.business_entity_id = $business_entity_id
  AND e.run_id IN (
    SELECT id FROM workflow_runs
    WHERE period_id = $period_id
      AND business_entity_id = $business_entity_id
  )
  AND e.updated_at > (
    SELECT computed_at FROM vat_returns
    WHERE business_entity_id = $business_entity_id
      AND period_id = $period_id
    LIMIT 1
  )
ORDER BY e.updated_at DESC;
```

```sql
-- Audit log: reclassification events after VAT return computed_at
SELECT al.event_name,
       al.payload,
       al.occurred_at
FROM audit_log al
WHERE al.business_entity_id = $business_entity_id
  AND al.event_name IN ('CLASSIFICATION_APPLIED','CLASSIFICATION_OVERRIDDEN')
  AND al.occurred_at > (
    SELECT computed_at FROM vat_returns
    WHERE business_entity_id = $business_entity_id
      AND period_id = $period_id
    LIMIT 1
  )
ORDER BY al.occurred_at DESC;
```

### Step 2.4 — Recompute the VAT return

Call `tool_vat_calc.md` with `{ "business_entity_id": $id, "period_id": $id, "force_recompute": true }`. This recalculates `output_vat_total`, `input_vat_total`, and `net_vat_payable` from current expense and invoice data and updates the `vat_returns` row. The tool emits `VAT_RETURN_RECOMPUTED` (MEDIUM) to the audit log.

---

## 3. Amending a VAT Return Before Submission

If the `vat_return.status` is `DRAFT`, the return has not been submitted and can be amended freely.

1. Correct the underlying expense or invoice data (reclassify, adjust amounts).
2. Call `tool_vat_calc.md` with `force_recompute: true` to refresh the totals.
3. Verify that the recomputed totals match expectations using the queries in step 2.2.
4. Resume the OUT workflow run if it was held; the gate will re-evaluate with the corrected data.

If the `vat_return.status` is `SENT` (submitted to the Cyprus Tax Department), follow section 4 instead.

---

## 4. Handling Already-Submitted Returns

A submitted VAT return (`status = 'SENT'` or `'PAID'`) cannot be modified in place. The Cyprus Tax Department requires a formal amendment filing.

**4.1 Assess materiality**

Corrections below 5 EUR net VAT impact may be carried forward to the next period's return as an adjustment line rather than filing a formal amendment. This is subject to accountant judgment and must be noted in a `note` record against the period.

**4.2 File an amendment**

For corrections above the materiality threshold:

1. Generate the corrected VAT return figures using `tool_vat_calc.md` with `force_recompute: true`.
2. Export the amendment data via `tool_report_generate.md` with `report_type = 'VAT_AMENDMENT'`.
3. Submit the amendment to the Cyprus Tax Department through the TAXISnet portal. This step is performed outside the system; the accountant manually files using the exported report.
4. After confirmation from TAXISnet, update the `vat_returns` row status:

   ```sql
   UPDATE vat_returns
   SET status = 'AMENDED',
       amendment_filed_at = now(),
       amendment_reference = $taxisnet_reference
   WHERE id = $vat_return_id;
   ```

5. Emit `VAT_RETURN_AMENDED` (HIGH) via `tool_emit_audit.md` with the TAXISnet reference number in the payload.

**4.3 Record the amendment in the period**

Create a note record against the period with `note_type = 'VAT_AMENDMENT'` and a summary of the corrected figures and the reason for the amendment. This note is included in the archive bundle for the period.

---

## 5. Related Tools and Schemas

| Resource | Role in reconciliation |
|---|---|
| `tool_vat_calc.md` | Recomputes VAT totals from source data |
| `tool_report_generate.md` | Generates VAT amendment export |
| `tool_emit_audit.md` | Emits `VAT_RETURN_AMENDED` after TAXISnet filing |
| `vat_return_schema.md` | Schema for `vat_returns` table |
| `vat_entry_schema.md` | Individual VAT posting entries |
| `vat_period_schema.md` | Period boundaries used in queries |
| `expense_schema.md` | Source data for input VAT computation |
| `invoice_schema.md` | Source data for output VAT computation |
| `expense_classification_policy.md` | VAT recoverability rules by expense type |
| `cyprus_vat_rule_catalog.md` | Cyprus-specific VAT rates and rules |
| `period_amendment_runbook.md` | Broader period amendment procedures |
| `vat_submission_rejection_runbook.md` | What to do when TAXISnet rejects a submission |
