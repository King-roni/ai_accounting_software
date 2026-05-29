# Double-Entry Validation Policy

**Category:** Policies · Block 11 — Ledger  
**Owner:** ledger  
**Last updated:** 2026-05-17

---

## 1. Purpose

This policy defines the double-entry accounting invariant enforced by the system, the timing and mechanism of validation, the rounding tolerance rules, the compensation path on validation failure, and Cyprus-specific statutory requirements. All ledger tooling and gate logic must conform to this policy.

The double-entry invariant: **for every debit entry there must be a corresponding credit entry of equal value**. The sum of all debit amounts must equal the sum of all credit amounts for any complete set of accounting entries within a workflow run.

---

## 2. The Double-Entry Invariant

### 2.1 Algebraic Statement

For a workflow run covering period `(period_year, period_month)` for `business_id`:

```
SUM(ledger_entries.amount_eur WHERE side = 'DEBIT') =
SUM(ledger_entries.amount_eur WHERE side = 'CREDIT')
```

This equality must hold:
- After the `LEDGER_POST` phase completes for all transactions in the run.
- After the `FINALIZATION` gate `engine.gate_double_entry_balanced` passes.
- At any point `ledger.reconcile` is invoked on the run.

A run that violates this invariant cannot be finalized.

### 2.2 Scope

The invariant applies to:
- All `ledger_entries` rows with `run_id` matching the current run.
- Adjustment entries created by `OUT_ADJUSTMENT` or `IN_ADJUSTMENT` runs linked to the parent run.
- VAT control account entries created by `ledger.compute_vat_amounts`.

The invariant does **not** apply across runs (inter-period balancing is handled by the Chart of Accounts mapping, not by this policy).

---

## 3. Validation Timing

Validation occurs at two mandatory checkpoints:

### 3.1 End of LEDGER_POST Phase

`ledger.validate_double_entry` is called by the phase execution engine after all `ledger_entries` for the run have been inserted. This is the primary validation gate. If it fails, the run transitions to `REVIEW_HOLD` and a BLOCKING review issue of type `DOUBLE_ENTRY_IMBALANCE` is raised.

### 3.2 FINALIZATION Gate

`engine.gate_double_entry_balanced` re-runs the validation SQL immediately before the FINALIZATION lock sequence begins. This is a redundant safety check to catch any entries added after the LEDGER_POST phase (e.g., late adjustment entries).

A run that fails this gate is held in `AWAITING_APPROVAL` with a BLOCKING review issue. No finalization can proceed until the issue is resolved.

---

## 4. Validation SQL

```sql
SELECT
  ABS(
    SUM(CASE WHEN side = 'DEBIT'  THEN amount_eur ELSE 0 END) -
    SUM(CASE WHEN side = 'CREDIT' THEN amount_eur ELSE 0 END)
  ) AS imbalance_eur
FROM ledger_entries
WHERE run_id = $1
  AND is_voided = false;
```

The check passes if `imbalance_eur <= 0.01` (the rounding tolerance defined in Section 5).

If `imbalance_eur > 0.01`, the check fails and returns the imbalance amount in the error payload.

---

## 5. Rounding Tolerance

A tolerance of **±0.01 EUR** (one Euro cent) is permitted to accommodate HALF_UP rounding on FX-converted transactions. The tolerance is not a license to allow systematic imbalance; it covers only the accumulated floating-point residual from FX conversions.

**Tolerance rule:**
- `imbalance_eur <= 0.01` → PASS
- `imbalance_eur > 0.01` → FAIL (review issue raised)

The tolerance is defined in `ledger_rounding_policy.md` and must not be hardcoded in application code. `ledger.validate_double_entry` reads the tolerance from the policy configuration at runtime.

**FX rounding context:** all non-EUR transactions are converted to EUR using the ECB daily rate with HALF_UP rounding applied. A run with many small FX transactions may accumulate a residual of up to 0.01 EUR across hundreds of entries. The tolerance covers this case. A residual above 0.01 EUR indicates a systematic error (wrong rate applied, truncation instead of rounding, or a missing entry).

---

## 6. Chart of Accounts Constraints

Every account in the Chart of Accounts has a `normal_side` attribute (`DEBIT` or `CREDIT`). The system validates that each `ledger_entries` row uses the correct side for the account type:

| Account Type | Normal Side | Debit means | Credit means |
|---|---|---|---|
| Asset | DEBIT | Increase | Decrease |
| Expense | DEBIT | Increase | Decrease |
| Liability | CREDIT | Decrease | Increase |
| Equity | CREDIT | Decrease | Increase |
| Revenue | CREDIT | Decrease | Increase |

Entries using the opposite side for an account are not rejected (contra-entries are valid accounting), but the Chart of Accounts validation flag `warn_on_abnormal_side` will emit a review issue of LOW severity when an entry uses the abnormal side for an account that has no contra-entry history.

---

## 7. VAT Control Account Invariant

After `ledger.compute_vat_amounts` completes, the following additional invariant must hold:

```sql
-- VAT control account net balance must be zero after VAT posting
SELECT
  SUM(CASE WHEN side = 'DEBIT'  THEN amount_eur ELSE 0 END) -
  SUM(CASE WHEN side = 'CREDIT' THEN amount_eur ELSE 0 END) AS vat_net
FROM ledger_entries
WHERE run_id = $1
  AND account_id = (SELECT id FROM chart_of_accounts WHERE code = '2400' AND business_id = $2)
  AND is_voided = false;
```

A non-zero VAT control account balance after VAT posting indicates that input VAT and output VAT have not been correctly offset. This triggers a BLOCKING review issue of type `VAT_CONTROL_IMBALANCE`. See `vat_treatment_policy.md` for VAT account codes.

---

## 8. Compensation Path on Validation Failure

If `ledger.validate_double_entry` fails at the LEDGER_POST checkpoint:

1. The run transitions to `REVIEW_HOLD`.
2. A BLOCKING review issue `DOUBLE_ENTRY_IMBALANCE` is raised with payload: `run_id`, `business_id`, `imbalance_eur`, `debit_sum`, `credit_sum`.
3. The accountant investigates the imbalance. Common causes:
   - FX rate applied incorrectly (wrong date or wrong currency pair).
   - A transaction with `income_outcome = UNKNOWN` that was not classified before LEDGER_POST.
   - A manual adjustment entry with the wrong side.
   - A voided entry that was not properly reversed.
4. The accountant corrects the root cause (e.g., re-classifies the transaction, corrects the FX rate via `MANUAL_OVERRIDE`).
5. The accountant calls `ledger.reconcile` to re-run all ledger preparation for the run.
6. `ledger.validate_double_entry` is called again. If it passes, the review issue is auto-resolved and the run is released from `REVIEW_HOLD`.
7. If it still fails after 3 reconcile attempts, the run is escalated to platform support.

---

## 9. ledger.reconcile Integration

`ledger.reconcile` is the idempotent re-computation tool that:

1. Voids all existing `ledger_entries` for the run (`is_voided = true`).
2. Re-runs `ledger.prepare_entries` for all transactions in the run.
3. Re-runs `ledger.compute_vat_amounts` for all transactions.
4. Re-runs `ledger.validate_double_entry`.
5. Returns the `imbalance_eur` value and a boolean `balanced`.

`ledger.reconcile` may be called by:
- The accountant via the review queue `DOUBLE_ENTRY_IMBALANCE` issue action.
- The compensation sequence if the LEDGER_POST phase fails mid-run.
- Platform support tooling.

See `tool_ledger_reconcile.md` for the full tool definition.

---

## 10. Cyprus-Specific Requirements

Under **Cyprus Tax Law 4/1978 (as amended)** and the **Cyprus Companies Law Cap. 113**, companies registered in Cyprus must maintain books of account that:

1. Show a complete and accurate picture of the financial transactions of the business.
2. Disclose with reasonable accuracy the financial position of the company at any time.
3. Enable the directors to ensure that any accounts prepared comply with the Companies Law.

The double-entry system directly satisfies requirement (1) and (2). The system's validation gate ensures that the books are always in balance before any period is finalized and committed to the archive.

**Specific Cyprus accounting obligations:**
- VAT records must reconcile with the VAT control account entries (Tax Law 4/1978, Section 38).
- Ledger entries must be retained for 7 years from the end of the accounting period (Tax Department circular 2016/1).
- Books must be available for inspection by the Tax Commissioner within 7 days of a request (Tax Law 4/1978, Section 61).

All `ledger_entries` rows are included in the archive bundle produced at finalization, satisfying the retention and inspection availability requirements.

---

## 11. Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `LEDGER_ENTRIES_PREPARED` | LOW | `ledger.prepare_entries` completes for a run |
| `LEDGER_ENTRIES_RECOMPUTED` | LOW | `ledger.reconcile` re-prepares entries |
| `ENGINE_GATE_FAILED` | MEDIUM | `engine.gate_double_entry_balanced` fails |

No dedicated event is emitted for a passing validation check — the `LEDGER_ENTRIES_PREPARED` event implies the validation passed (the tool does not return success without passing the check).

---

## 12. Cross-References

- `ledger_rounding_policy.md` — rounding tolerance definition; HALF_UP rule
- `tool_ledger_reconcile.md` — `ledger.reconcile` tool definition
- `vat_treatment_policy.md` — VAT control account codes and posting rules
- `chart_of_accounts_policy.md` — `normal_side` attribute; contra-entry rules
- `audit_event_taxonomy.md` — `LEDGER_ENTRIES_PREPARED`, `LEDGER_ENTRIES_RECOMPUTED`, `ENGINE_GATE_FAILED`
- `reference/error_code_catalog.md` — `DOUBLE_ENTRY_IMBALANCE`, `VAT_CONTROL_IMBALANCE` error codes
- `data_retention_policy.md` — 7-year retention for ledger entries
- Block 11 Phase 03 — `ledger.prepare_entries` and `ledger.compute_vat_amounts` implementation
- Block 15 Phase 02 — `engine.gate_double_entry_balanced` finalization gate
