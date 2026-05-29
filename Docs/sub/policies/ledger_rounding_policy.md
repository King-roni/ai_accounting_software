# Ledger Rounding Policy

**Block:** Ledger (Block 11)
**Layer:** 2 — Sub-Doc
**Status:** Active
**Last updated:** 2026-05-17
**Referenced by:** `policies/double_entry_validation_policy.md`

---

## 1. Purpose

This policy defines how rounding differences in EUR monetary amounts are handled within
the double-entry ledger system. It covers the rounding mode, per-line tolerance,
period-total tolerance, the automatic rounding adjustment entry mechanism, and the
treatment of FX-converted amounts.

All monetary amounts in the ledger are stored as `NUMERIC(15, 2)` — two decimal places
in EUR. Because upstream sources (bank statement amounts, invoice line items, FX
conversions) may produce values with more than two decimal places, controlled rounding is
applied at defined pipeline stages. This policy specifies exactly when and how that
rounding occurs.

---

## 2. Rounding Mode

**Rounding mode: HALF_UP**

The platform uses HALF_UP rounding (also known as "round half away from zero") for all
monetary rounding operations. This is the standard rounding mode required by the Cyprus
Tax Department for VAT return and income tax computations.

HALF_UP is defined as: if the digit after the last retained digit is exactly 5, round
away from zero.

Example:
- `0.125` → `0.13` (HALF_UP)
- `0.135` → `0.14` (HALF_UP)
- `-0.125` → `-0.13` (HALF_UP, away from zero)

**Banker's rounding (HALF_EVEN) is explicitly not used.** Although HALF_EVEN is
statistically unbiased, the Cyprus Tax Department's reference computation rules and the
VAT Act (N. 95(I)/2000) require deterministic HALF_UP for official filings. Using
HALF_EVEN would produce discrepancies when comparing platform-computed totals against
manually prepared schedules.

---

## 3. Per-Line Rounding Tolerance

**Tolerance: ±0.01 EUR per individual transaction line**

A rounding difference of up to ±0.01 EUR on a single ledger entry line is considered
acceptable without raising a ledger imbalance error. This tolerance accommodates:

- Three-decimal-place amounts on bank statement rows (e.g., `123.455` EUR) rounded to
  two decimal places.
- Multi-line invoices where each line is rounded independently before summing.
- FX-converted amounts (see Section 6) where the ECB rate multiplied by a foreign-
  currency amount does not produce a clean EUR amount.

When the rounding difference on a line is within ±0.01 EUR, `ledger.prepare_entries`
automatically creates a `LEDGER_ROUNDING_ADJUSTMENT` entry (see Section 5) to absorb
the difference. No manual action is required.

When the rounding difference on a line exceeds ±0.01 EUR, this indicates a data problem
(incorrect amount on the source document, FX rate applied to wrong currency, or an
upstream parsing error) rather than a legitimate rounding artefact. In this case,
validation fails and the run halts at the LEDGER phase pending operator review.

---

## 4. Period-Total Balancing Requirement

**Tolerance: ±0.00 EUR for period totals (must balance exactly)**

The trial balance for a finalized period must balance exactly: the sum of all debit
entries must equal the sum of all credit entries to within zero tolerance. Any imbalance
at the period-total level — regardless of size — is a hard validation failure that blocks
period finalization.

The per-line rounding adjustment mechanism (Section 5) ensures that per-line differences
are resolved during the ledger posting phase, so that by the time `ledger.reconcile` runs
the trial balance check, all entries are clean.

If `ledger.reconcile` detects a non-zero trial balance difference, the `LEDGER_RECONCILIATION_FAILED`
event is emitted (HIGH severity) and a review issue of type `LEDGER_IMBALANCE` is created
for operator resolution.

---

## 5. Automatic Rounding Adjustment Entry

When `ledger.prepare_entries` detects a per-line rounding difference within the ±0.01 EUR
tolerance, it automatically posts a `LEDGER_ROUNDING_ADJUSTMENT` entry to absorb the
difference. This entry:

- Is posted to the platform-internal rounding account (`ROUNDING_ADJUSTMENT` in the chart
  of accounts, account code `999900`).
- Has `entry_type = 'ROUNDING_ADJUSTMENT'` to distinguish it from regular transaction
  entries.
- References the originating `transaction_id` and `run_id` for traceability.
- Is not visible to business users in the standard ledger view (filtered out by the UI
  presentation layer) but is included in the raw ledger export and in archive bundles.

The `LEDGER_ENTRY_CREATED` audit event is emitted for each rounding adjustment entry, with
`entry_type = 'ROUNDING_ADJUSTMENT'` in the payload. This satisfies audit requirement to
log all ledger mutations including rounding.

### 5.1 Rounding Adjustment Entry Structure

```
Debit:  ROUNDING_ADJUSTMENT (999900)    amount = rounding_difference (abs)
Credit: <affected_ledger_account>        amount = rounding_difference (abs)
```

When the rounding difference is negative (ledger entry is overstated), the debit/credit
are reversed:

```
Debit:  <affected_ledger_account>        amount = |rounding_difference|
Credit: ROUNDING_ADJUSTMENT (999900)    amount = |rounding_difference|
```

The affected ledger account is determined by the original entry's debit or credit
assignment, as computed by `ledger.prepare_entries` before rounding.

---

## 6. FX Conversion Rounding

For non-EUR transactions, the following rounding rule applies:

1. Fetch the ECB reference rate for the transaction date (see `ecb_rate_freshness_policy.md`).
2. Multiply: `foreign_amount × ecb_rate`.
3. Round to **exactly 2 decimal places** using HALF_UP.
4. Use the rounded EUR amount for all subsequent ledger entries.

FX rounding is always applied after conversion, never before. Converting a rounded
foreign amount rather than the raw amount would introduce a systematic error.

The ECB rate is a decimal value with up to 6 significant figures (e.g., `1.08234`). For
Greek bank accounts that transact in GBP, USD, CHF, or other non-EUR currencies, the
FX conversion rounding typically produces differences of less than ±0.01 EUR, which are
absorbed by the automatic rounding adjustment entry (Section 5).

When the FX conversion produces a difference > ±0.01 EUR (possible for very large
transactions), this is treated as an anomaly and a review issue of type
`LEDGER_FX_ROUNDING_ANOMALY` is raised for manual review before the run can advance.

---

## 7. VAT Amount Rounding

VAT amounts are computed as:

```
vat_amount_eur = ROUND(net_amount_eur × vat_rate, 2)   -- HALF_UP
gross_amount_eur = net_amount_eur + vat_amount_eur
```

VAT is always rounded on the per-line net amount, not on the total net amount of an
invoice. This matches the Cyprus VAT Act requirement that VAT is calculated line-by-line
for invoices with multiple line items.

If summing line-level VAT amounts produces a cent-level difference versus the invoice's
stated total VAT, the per-line amounts take precedence and a `LEDGER_ROUNDING_ADJUSTMENT`
entry is posted for the difference.

---

## 8. Interaction with Double-Entry Validation Policy

`policies/double_entry_validation_policy.md` defines the gate conditions for the LEDGER
phase. This policy (ledger_rounding_policy.md) is a dependency of that gate. Specifically:

- The double-entry validation policy calls `ledger.reconcile` after `ledger.prepare_entries`
  and `ledger.compute_vat_amounts` complete.
- `ledger.reconcile` uses the ±0.00 period-total tolerance (Section 4) as its balance check.
- Rounding adjustments (Section 5) must have been posted by `ledger.prepare_entries`
  before `ledger.reconcile` runs; the reconcile step does not post adjustments itself.

If both policies are updated concurrently, the ledger_rounding_policy.md takes precedence
on tolerance values. The double_entry_validation_policy.md must not hardcode tolerance
values — it must reference this document.

---

## 9. Audit Trail

All rounding-related ledger mutations are captured in the audit log via the following
events:

| Event | Severity | Trigger |
|---|---|---|
| `LEDGER_ENTRY_CREATED` | LOW | A rounding adjustment entry is posted (entry_type = ROUNDING_ADJUSTMENT) |
| `LEDGER_RECONCILIATION_FAILED` | HIGH | Period trial balance does not balance after all rounding adjustments |

The `LEDGER_ENTRY_CREATED` payload for rounding adjustments includes:
`entry_id`, `transaction_id`, `entry_type = 'ROUNDING_ADJUSTMENT'`, `amount_eur`
(the rounding difference being absorbed), `run_id`, `business_id`.

---

## Related Documents

- `policies/double_entry_validation_policy.md` — gate conditions; references this policy
- `tools/tool_ledger_post.md` — posts ledger entries; applies this rounding logic
- `tools/tool_ledger_reconcile.md` — trial balance check; uses period-total tolerance
- `tools/tool_fx_convert.md` — FX conversion; applies rounding after conversion
- `policies/ecb_rate_freshness_policy.md` — ECB rate staleness and fallback
- `policies/fx_conversion_policy.md` — full FX conversion rules; HALF_UP specified there too
- `reference/audit_event_taxonomy.md` — `LEDGER_ENTRY_CREATED`, `LEDGER_RECONCILIATION_FAILED`
- `reference/vat_rate_table_reference.md` — VAT rates used for per-line VAT computation
