# Policy: Expense Classification

**Namespace:** `classification`
**Owning block:** 12 — OUT Workflow
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

This policy defines how expense lines in the OUT workflow are assigned an account code, a VAT category, and a VAT recoverability determination. It covers automated AI classification, manual override, and the validation rules that must pass before an expense can be marked `CLASSIFIED`.

The income classification confidence tiers defined in `classification_confidence_policy.md` apply unchanged to expense classification. This policy adds OUT-workflow-specific rules on top of that foundation.

---

## 1. Auto-Classification via AI

### 1.1 Confidence tiers

The AI classification engine scores each expense line using the same confidence bands as income classification:

| Band | Confidence | Action |
|---|---|---|
| 1 | ≥ 0.90 | Auto-accept; no review issue created |
| 2 | 0.85 – 0.89 | Auto-accept; LOW severity informational review issue created |
| 3 | 0.70 – 0.84 | Escalated to accountant; run enters `REVIEW_HOLD`; MEDIUM review issue |
| 4 | < 0.70 | Sent to human review; HIGH review issue; expense stays `PENDING` |

The auto-accept threshold is configurable per business in `business_settings.classification_confidence_threshold` with a platform minimum of 0.80.

### 1.2 Vendor memory

Before the AI model scores an expense, the classification engine checks `vendor_memory` for a prior classification from the same `supplier_name` and `business_entity_id`. If a matching vendor memory entry exists with `confirmed_count >= 2`, the prior category is proposed to the model as a strong prior. If the model and vendor memory agree, the confidence score is treated as 1.0 and the classification is auto-accepted without a review issue.

Vendor memory is incremented after each confirmed classification via `tool_vendor_memory_increment.md`.

### 1.3 AI model inputs

The classification model receives: `supplier_name`, `supplier_vat_number` (if present), `description`, `amount_gross`, `currency`, and the business's `chart_of_accounts` as a structured context block. The model returns a proposed `account_code`, `vat_category`, and `confidence`.

---

## 2. Required Fields Before CLASSIFIED

An expense may not transition from `PENDING` to `CLASSIFIED` unless all of the following conditions are met:

1. `vat_category` is non-null and references a valid code in `vat_categories`.
2. `account_code` is non-null and references a valid code in `chart_of_accounts` for the business.
3. `amount_net` and `vat_amount` are both non-null and non-negative.
4. **Amount reconciliation check:** `amount_gross = amount_net + vat_amount` within a 0.01 EUR tolerance.
5. `expense_date` is non-null and falls within the accounting period associated with the run.

If condition 4 fails beyond the 0.01 EUR tolerance, the expense is held as `PENDING` with a `CLASSIFICATION_AMOUNT_MISMATCH` review issue. The accountant must correct the amounts before classification can proceed.

---

## 3. Manual Override Flow

Any accountant or admin with access to the business may override a classification on a `PENDING` or `CLASSIFIED` expense. The override is performed via `tool_classification_override.md`.

Override requirements:

- The overriding user must supply a valid `account_code`, `vat_category`, and a `reason` string (minimum 10 characters).
- A `classification_override_log` row is inserted to preserve the original values and the override reason.
- `CLASSIFICATION_OVERRIDDEN` (MEDIUM) is emitted to the audit log.
- After a successful override, the expense is re-evaluated against the required field checks (section 2). If all checks pass, the expense is transitioned to `CLASSIFIED`.
- Overriding a `CLASSIFIED` expense is permitted; the override re-runs the reconciliation check.

Overrides on `MATCHED` or `LOCKED` expenses are not permitted.

---

## 4. VAT Recoverability Rules

VAT recoverability determines what portion of `vat_amount` is claimable as input VAT on the Cyprus VAT return. The rules are applied at classification time and stored in `expenses.vat_recoverable_amount`.

### 4.1 Standard business expenses — 19% fully recoverable

Input VAT at the Cyprus standard rate of 19% is fully recoverable on ordinary business expenses (office supplies, professional services, hardware, subscriptions, subcontractor invoices). For these expenses:

```
vat_recoverable_amount = vat_amount
```

### 4.2 Entertainment and meals — 50% recovery

Expenses coded to entertainment or meals account codes (`vat_category IN ('ENTERTAINMENT','MEALS_SUBSISTENCE')`) are subject to a 50% recovery restriction under Cyprus VAT law:

```
vat_recoverable_amount = vat_amount * 0.50
```

The classification engine automatically applies this restriction when the assigned `vat_category` falls in the restricted set. The restriction cannot be overridden without changing the `vat_category` to a non-restricted code, which itself requires a documented override reason.

### 4.3 Personal expenses — 0% recovery

Expenses classified as personal (`vat_category = 'PERSONAL'`) are not eligible for input VAT recovery. The VAT amount is not deductible:

```
vat_recoverable_amount = 0
```

Personal expenses should not appear in business accounts. If the AI proposes `PERSONAL`, a HIGH severity review issue is created and the expense is held for accountant review before classification is applied.

### 4.4 Zero-rated and exempt suppliers

Expenses from zero-rated or VAT-exempt suppliers have `vat_amount = 0` by definition. The `vat_recoverable_amount` is also 0. These are classified normally; no recoverability restriction applies.

---

## 5. Account Code Assignment Guidelines

Common expense types and their expected account code ranges:

| Expense type | Account code range | Notes |
|---|---|---|
| Supplier invoices (goods) | 6000–6099 | Cost of goods purchased for resale |
| Supplier invoices (services) | 6100–6199 | Professional fees, subcontractors |
| Office and admin costs | 6200–6299 | Stationery, postage, subscriptions |
| Utilities | 6300–6349 | Electricity, water, internet |
| Rent and premises | 6350–6399 | Office rent, rates |
| Travel | 6400–6449 | Business travel excluding entertainment |
| Entertainment and meals | 6450–6499 | Subject to 50% VAT recovery restriction |
| Bank charges | 6500–6549 | Transaction fees, FX conversion charges |
| Depreciation | 6600–6699 | Computed by separate depreciation schedule |

Account codes outside these ranges require a manual override with a reason. The AI model may propose codes outside the ranges for unusual expense types; any such proposal is treated as Band 3 (confidence 0.70–0.84) regardless of the model's raw score, triggering accountant review.

---

## Related Documents

- `classification_confidence_policy.md` — confidence tier definitions shared with IN workflow
- `expense_schema.md` — `expenses` table and `expense_status_enum`
- `tool_classification_apply.md` — applies a proposed classification
- `tool_classification_override.md` — manual classification override
- `vendor_memory_schema.md` — vendor memory structure
- `chart_of_accounts_schema.md` — valid account codes
- `vat_categories` table — valid VAT category codes
- `cyprus_vat_rule_catalog.md` — authoritative VAT rate and recoverability rules
- `vat_reconciliation_runbook.md` — what to do when VAT totals do not reconcile
