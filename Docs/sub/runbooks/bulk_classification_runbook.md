# Bulk Classification Runbook

**Block:** classification
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook covers the procedure for bulk re-classifying transactions when a classification rule has been updated, a rule is found to be incorrect, or a systematic misclassification is discovered across a run or period. It is distinct from single-transaction overrides (handled via the Review Queue UI) and from period amendments (covered in `period_amendment_runbook.md`).

Triggers for this runbook:
- A classification rule is found to have produced incorrect category assignments across 10 or more transactions.
- AI training data is corrected and a backfill is required.
- Vendor memory accumulated incorrect associations due to a mislabelled seed.
- An accountant requests reclassification of a category across a full period (e.g., all "PROFESSIONAL_SERVICES" transactions should be "IT_SERVICES").
- A VAT rate was applied incorrectly (triggers ledger re-reconciliation after reclassification).

Audience: ACCOUNTANT, ADMIN, OWNER roles. Steps marked [ADMIN ONLY] require ADMIN or OWNER.

---

## Step 1 — Identify Scope

Determine which transactions are affected before making any changes.

### 1a. Identify by Run ID

If the issue is confined to a specific run:

```sql
SELECT
  t.id AS transaction_id,
  t.vendor_raw,
  t.amount,
  t.transaction_date,
  c.category,
  c.confidence,
  c.source,
  c.applied_rule_id
FROM transactions t
JOIN transaction_classifications c ON c.transaction_id = t.id
WHERE t.run_id = :run_id
  AND t.business_id = :business_id
  AND c.category = :incorrect_category
ORDER BY t.transaction_date ASC;
```

### 1b. Identify by Date Range

If the issue spans multiple runs or a full period:

```sql
SELECT
  t.id AS transaction_id,
  t.run_id,
  t.vendor_raw,
  t.amount,
  t.transaction_date,
  c.category,
  c.confidence,
  c.source,
  c.applied_rule_id
FROM transactions t
JOIN transaction_classifications c ON c.transaction_id = t.id
WHERE t.business_id = :business_id
  AND t.transaction_date >= :period_start
  AND t.transaction_date < :period_end
  AND c.category = :incorrect_category
ORDER BY t.transaction_date ASC;
```

### 1c. Identify by Rule ID

If a specific rule is suspected:

```sql
SELECT
  t.id AS transaction_id,
  t.vendor_raw,
  t.amount,
  t.transaction_date,
  t.run_id,
  c.category,
  c.confidence
FROM transactions t
JOIN transaction_classifications c ON c.transaction_id = t.id
WHERE t.business_id = :business_id
  AND c.applied_rule_id = :rule_id
ORDER BY t.transaction_date ASC;
```

### 1d. Count Affected Transactions

```sql
SELECT COUNT(*) AS affected_count
FROM transactions t
JOIN transaction_classifications c ON c.transaction_id = t.id
WHERE t.business_id = :business_id
  AND c.category = :incorrect_category
  AND t.transaction_date >= :period_start
  AND t.transaction_date < :period_end;
```

Record the count. If `affected_count > 500`, plan to process in batches of 500 (the tool limit for `classification.apply` array input).

### 1e. Check for FINALIZED Runs

```sql
SELECT DISTINCT
  r.id AS run_id,
  r.run_status,
  r.finalized_at
FROM runs r
JOIN transactions t ON t.run_id = r.id
WHERE t.business_id = :business_id
  AND r.run_status = 'FINALIZED'
  AND t.id IN (
    SELECT t2.id FROM transactions t2
    JOIN transaction_classifications c ON c.transaction_id = t2.id
    WHERE t2.business_id = :business_id
      AND c.category = :incorrect_category
      AND t2.transaction_date >= :period_start
      AND t2.transaction_date < :period_end
  );
```

If any FINALIZED runs are returned, **do not proceed with direct reclassification**. FINALIZED runs are read-only. Go to Step 3, Branch B (Amendment path).

---

## Step 2 — Validate the Correction

Before changing any classifications, confirm the correction is correct and well-scoped.

### 2a. Confirm the New Category

Check that the target category exists in the chart of accounts:

```sql
SELECT code, label, vat_treatment, is_expense, is_income
FROM chart_of_accounts
WHERE code = :new_category
  AND business_id = :business_id;
```

If no row is returned, the category does not exist. Do not proceed; resolve the chart of accounts discrepancy first.

### 2b. Check VAT Rate Implications

If the old and new categories have different default VAT rates:

```sql
SELECT
  c1.code AS old_category, c1.default_vat_rate AS old_vat_rate,
  c2.code AS new_category, c2.default_vat_rate AS new_vat_rate
FROM chart_of_accounts c1, chart_of_accounts c2
WHERE c1.code = :old_category
  AND c2.code = :new_category
  AND c1.business_id = :business_id
  AND c2.business_id = :business_id;
```

If `old_vat_rate != new_vat_rate`, note this. VAT totals will need to be recalculated after reclassification (Step 4b).

### 2c. Check if Vendor Memory Should Be Updated

```sql
SELECT id, vendor_normalized, category, confidence_accumulated, match_count
FROM vendor_memory
WHERE business_id = :business_id
  AND vendor_normalized = :vendor_normalized;
```

If a vendor memory record exists pointing to the incorrect category, plan to update it in Step 5b. Do not update it yet; wait until reclassifications are confirmed.

### 2d. Check Matching Validity

Check whether any affected transactions have confirmed matches that depend on their current classification:

```sql
SELECT
  t.id AS transaction_id,
  m.id AS match_id,
  m.match_level,
  m.match_status
FROM transactions t
JOIN transaction_matches m ON m.transaction_id = t.id
WHERE t.id IN (:affected_transaction_ids)
  AND m.match_status IN ('CONFIRMED', 'AUTO_CONFIRMED');
```

If confirmed matches exist, reclassification may invalidate the match signal. Flag these for manual review after reclassification (Step 4c).

---

## Step 3 — Re-Classify via Batch

### Branch A — RUNNING or REVIEW_HOLD Runs (Non-Finalized)

For runs in RUNNING, REVIEW_HOLD, AWAITING_APPROVAL, or PAUSED state:

#### 3A.1 Batch Reclassification via Tool

The `classification.apply` tool accepts an array of up to 500 transaction IDs with an explicit override category. Call it in batches if needed.

```typescript
// Example: batch reclassify via Edge Function
const batchSize = 500;
const batches = chunk(affectedTransactionIds, batchSize);

for (const batch of batches) {
  const result = await classificationEngine.apply({
    business_id: businessId,
    transactions: batch.map(id => ({
      transaction_id: id,
      override_category: newCategory,
      override_reason: overrideReason,  // required
      override_source: 'BULK_CORRECTION',
    })),
  });

  if (result.error) {
    throw new Error(`Batch failed: ${result.error.message}`);
  }
}
```

#### 3A.2 Create Classification Override Log Entries

For each transaction in the batch, `classification.apply` automatically creates a `classification_override_log` entry. Verify:

```sql
SELECT COUNT(*) FROM classification_override_log
WHERE transaction_id IN (:affected_transaction_ids)
  AND override_source = 'BULK_CORRECTION'
  AND created_at >= NOW() - INTERVAL '1 hour';
-- Expected: count equals number of affected transactions
```

#### 3A.3 Re-Set run_status if Needed

If the run was in RUNNING state and the reclassification is extensive (>10% of run transactions), transition it to REVIEW_HOLD:

```sql
UPDATE runs
SET run_status = 'REVIEW_HOLD',
    updated_at = NOW()
WHERE id = :run_id
  AND business_id = :business_id
  AND run_status = 'RUNNING';
```

Log this status change in the run notes (Step 5a).

### Branch B — FINALIZED Runs (Read-Only, Amendment Required)

FINALIZED runs cannot be modified directly. Use the period amendment flow.

1. Open `period_amendment_runbook.md` and follow the amendment creation procedure.
2. The amendment creates a parallel set of corrected entries against the finalized period.
3. Reference the amendment ID in this runbook's documentation (Step 5a).
4. The amendment propagates corrected categories to the VAT return for the period. Do not manually adjust ledger entries.

Return to this runbook at Step 4 after the amendment is created and approved.

---

## Step 4 — Verify Ledger Impact

### 4a. Re-Run Ledger Reconciliation

After bulk reclassification, run ledger reconciliation for the affected period:

```typescript
await ledger.reconcile({
  business_id: businessId,
  period_start: periodStart,
  period_end: periodEnd,
  run_id: runId,  // if scoped to a run
});
```

Check for reconciliation errors:

```sql
SELECT event_type, severity, payload
FROM audit_log
WHERE business_id = :business_id
  AND run_id = :run_id
  AND event_type IN ('LEDGER_IMBALANCE_DETECTED', 'RECONCILIATION_FAILED')
  AND occurred_at >= NOW() - INTERVAL '30 minutes'
ORDER BY occurred_at DESC;
```

If `LEDGER_IMBALANCE_DETECTED` events appear, follow `ledger_imbalance_runbook.md`.

### 4b. Recalculate VAT Totals (If VAT Rate Changed)

If Step 2b confirmed that old and new categories have different VAT rates:

```typescript
await vatEngine.recalculate({
  business_id: businessId,
  period_start: periodStart,
  period_end: periodEnd,
});
```

Verify the new VAT totals are consistent with expected values:

```sql
SELECT
  vat_rate,
  SUM(vat_amount) AS total_vat,
  SUM(amount_excl_vat) AS total_net
FROM vat_line_items
WHERE business_id = :business_id
  AND period >= :period_start
  AND period < :period_end
GROUP BY vat_rate
ORDER BY vat_rate;
```

Compare against the pre-correction baseline (recorded at Step 1). Significant deltas in VAT totals should be reviewed with the accountant before proceeding.

### 4c. Re-Validate Flagged Matches

For transactions with confirmed matches identified in Step 2d:

```sql
SELECT
  t.id,
  t.vendor_raw,
  t.amount,
  c.category AS new_category,
  m.match_level,
  m.match_status
FROM transactions t
JOIN transaction_classifications c ON c.transaction_id = t.id
JOIN transaction_matches m ON m.transaction_id = t.id
WHERE t.id IN (:transactions_with_confirmed_matches)
  AND m.match_status IN ('CONFIRMED', 'AUTO_CONFIRMED');
```

If matches appear inconsistent with the new category, reopen them in the review queue:

```sql
UPDATE transaction_matches
SET match_status = 'NEEDS_REVIEW',
    updated_at = NOW()
WHERE transaction_id IN (:transactions_with_confirmed_matches)
  AND match_status = 'AUTO_CONFIRMED';
```

Do not touch CONFIRMED (human-confirmed) matches automatically; raise them in the review queue for accountant re-confirmation.

---

## Step 5 — Document the Correction

### 5a. Create a Run Note

For each affected run, create a run note documenting what was changed and why:

```sql
INSERT INTO run_notes (
  id,
  run_id,
  business_id,
  note_type,
  content,
  created_by,
  created_at
) VALUES (
  gen_uuid_v7(),
  :run_id,
  :business_id,
  'BULK_CORRECTION',
  'Bulk reclassification: [old_category] → [new_category]. Affected: [count] transactions. Reason: [reason]. Rule updated: [rule_id or N/A]. Runbook: bulk_classification_runbook.md.',
  :user_id,
  NOW()
);
```

### 5b. Update the Problematic Classification Rule

If the issue was caused by a rule (`applied_rule_id` populated in the scope query):

1. Raise the rule's disambiguation predicate. For example, add a negative predicate to exclude the vendor pattern that was incorrectly matching:

```sql
UPDATE classification_rules
SET
  predicate_vendor_excludes = ARRAY_APPEND(predicate_vendor_excludes, :exclusion_pattern),
  priority = priority + 10,   -- raise priority to fire before less-specific rules
  updated_at = NOW(),
  updated_by = :user_id
WHERE id = :rule_id
  AND business_id = :business_id;
```

2. If the rule itself was wrong (not just ambiguous), disable it and create a replacement:

```sql
UPDATE classification_rules
SET enabled = false, updated_at = NOW()
WHERE id = :rule_id AND business_id = :business_id;

-- Create replacement rule
INSERT INTO classification_rules (
  id, business_id, predicate_vendor_contains, predicate_vendor_excludes,
  category, confidence, priority, enabled, created_at
) VALUES (
  gen_uuid_v7(), :business_id, :new_predicate, :exclusion_array,
  :correct_category, :confidence, :priority, true, NOW()
);
```

### 5c. Update Vendor Memory

If vendor memory was identified in Step 2c as pointing to the wrong category:

```sql
UPDATE vendor_memory
SET
  category = :correct_category,
  confidence_accumulated = 0.75,  -- reset to cautious level after correction
  last_confirmed_at = NOW(),
  updated_at = NOW()
WHERE business_id = :business_id
  AND vendor_normalized = :vendor_normalized;
```

The confidence is reset to 0.75 (not 1.0) to indicate the record was corrected; it will accumulate confidence again as the correct category is confirmed on subsequent transactions.

### 5d. Verify Audit Events

Confirm that all expected audit events were written:

```sql
SELECT event_type, COUNT(*) AS event_count
FROM audit_log
WHERE business_id = :business_id
  AND run_id = :run_id
  AND event_type IN (
    'CLASSIFICATION_RULE_UPDATED',
    'CLASSIFICATION_APPLIED',
    'CLASSIFICATION_OVERRIDE_CREATED',
    'VENDOR_MEMORY_UPDATED',
    'LEDGER_RECONCILIATION_COMPLETED'
  )
  AND occurred_at >= NOW() - INTERVAL '2 hours'
GROUP BY event_type
ORDER BY event_type;
```

Expected events:
- `CLASSIFICATION_RULE_UPDATED`: 1 (if rule was modified or disabled)
- `CLASSIFICATION_APPLIED`: 1 per reclassified transaction
- `CLASSIFICATION_OVERRIDE_CREATED`: 1 per reclassified transaction
- `VENDOR_MEMORY_UPDATED`: 1 per vendor normalized name updated
- `LEDGER_RECONCILIATION_COMPLETED`: 1 (after Step 4a)

If `CLASSIFICATION_APPLIED` count does not match the expected affected transaction count, investigate which transactions were missed before closing the runbook.

---

## Rollback

Bulk reclassification does not have an automatic rollback. If the correction was wrong:

1. Re-run this runbook in reverse: set `incorrect_category` to the new (wrong) category and `new_category` to the original (correct) category.
2. The override log preserves the history of all changes; the chain is visible in the audit log.
3. If ledger entries were re-posted incorrectly, follow `ledger_imbalance_runbook.md`.

---

## Related Documents

- `/sub/runbooks/period_amendment_runbook.md`
- `/sub/runbooks/ledger_imbalance_runbook.md`
- `/sub/runbooks/vat_recalculation_runbook.md`
- `/sub/runbooks/classification_rule_conflict_runbook.md`
- `/sub/runbooks/classification_confidence_drop_runbook.md`
- `/sub/fixtures/classification_fixture_content.md`
- `/sub/reference/audit_event_taxonomy.md`
- `/sub/reference/match_level_enum.md`
