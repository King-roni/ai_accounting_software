# Invoice Lines Payload Schema

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Block reference:** BLOCK_13 · **Stage:** 4 sub-doc (Layer 2)

This document specifies the `lines_payload` JSONB column on the `invoices` table: its element schema, calculation rules, VAT treatment rules, validation constraints, and amendment guard.

---

## Purpose

Invoice line items are stored as a JSONB array rather than in a separate normalised table. This choice avoids join complexity for the most common read path (render invoice PDF, compute totals), makes the full line-item snapshot part of the immutable finalized record, and keeps the invoice row self-contained for archive bundling. The trade-off is that aggregate queries across line items require JSONB unnesting; those are infrequent and are served by reporting tools, not the operational path.

---

## Column location

`invoices.lines_payload` — `JSONB NOT NULL`.

The column is constrained to a minimum of 1 element and a maximum of 200 elements via a `CHECK` constraint:

```sql
CONSTRAINT invoice_lines_count_check
    CHECK (
        jsonb_array_length(lines_payload) >= 1
        AND jsonb_array_length(lines_payload) <= 200
    )
```

---

## Element schema

Each element of the `lines_payload` array is a JSON object with the following fields:

| Field | JSON type | Constraints | Description |
| --- | --- | --- | --- |
| `line_id` | string (UUID v7) | Required; unique within the array | Identifier for this line item. UUID v7 — time-ordered, no security-token concern. |
| `description` | string | Required; max 500 characters; non-empty after trim | Human-readable description of the good or service. Appears on the PDF. |
| `quantity` | number | Required; `> 0` | Unit count. May be fractional (e.g., `0.5` for a half-day of consulting). |
| `unit` | string | Required; max 50 characters | Unit label shown on the PDF — e.g., `"hours"`, `"pcs"`, `"kg"`. Not a FK; free text. |
| `unit_price_eur` | number | Required; `>= 0` | Pre-discount price per unit in EUR. Stored as a decimal number; the serialization rule in `data_layer_conventions_policy` applies: no floating-point — use the shortest round-trip decimal that preserves two decimal places of precision. |
| `discount_pct` | number | Optional; `0`–`100`; default `0` | Percentage discount applied to the line before VAT. A value of `10` means 10% off. |
| `vat_rate` | number or string | Required; one of `0`, `5`, `9`, `19`, `"EXEMPT"`, `"REVERSE_CHARGE"` | VAT rate to apply. Numeric values are percentages; string values are named treatments. |
| `vat_amount_eur` | number | Required; computed; `>= 0` | VAT amount for the line in EUR. Computed by the invoice generator; not supplied by the caller. |
| `line_total_eur` | number | Required; computed | Pre-VAT line total in EUR (after discount). Computed; not supplied by the caller. |
| `line_total_incl_vat_eur` | number | Required; computed | Post-VAT line total in EUR. Computed; not supplied by the caller. |

### Canonical element example

```json
{
  "line_id": "01916f4e-3b7a-7000-8000-abcdef012345",
  "description": "Software consulting — May 2026",
  "quantity": 8,
  "unit": "hours",
  "unit_price_eur": 125.00,
  "discount_pct": 0,
  "vat_rate": 19,
  "vat_amount_eur": 190.00,
  "line_total_eur": 1000.00,
  "line_total_incl_vat_eur": 1190.00
}
```

---

## Calculation rules

All computed fields (`vat_amount_eur`, `line_total_eur`, `line_total_incl_vat_eur`) are derived from the editable fields. The invoice generator recomputes them on every save to `DRAFT` status and before any transition to `SENT`.

### `line_total_eur` (pre-VAT, after discount)

```
line_total_eur = round(quantity × unit_price_eur × (1 - discount_pct / 100), 2)
```

Rounding: standard half-up to 2 decimal places (EUR cent precision).

### `vat_amount_eur`

```
vat_amount_eur = round(line_total_eur × vat_rate / 100, 2)
```

Where `vat_rate` is the numeric percentage. For `EXEMPT` and `REVERSE_CHARGE`, `vat_amount_eur = 0` (see VAT treatment rules below).

### `line_total_incl_vat_eur` (post-VAT)

```
line_total_incl_vat_eur = line_total_eur + vat_amount_eur
```

### Invoice-level total consistency check

The invoice row carries `invoices.total_amount_eur`, which must equal the sum of all line `line_total_incl_vat_eur` values within a tolerance of ±0.01 EUR:

```
ABS(SUM(lines_payload[*].line_total_incl_vat_eur) - invoices.total_amount_eur) <= 0.01
```

This tolerance accommodates the per-line rounding accumulation on long invoices. The check is enforced by `in_workflow.validate_invoice_totals` before any transition from `DRAFT` to `SENT`. If the check fails, the transition is rejected and the discrepancy is logged in the issue context.

---

## VAT rate values

| Value | Type | Semantics |
| --- | --- | --- |
| `0` | number | Zero-rated — taxable supply, 0% rate. `vat_amount_eur = 0`. |
| `5` | number | Cyprus reduced rate (5%) — applicable to certain goods per Cyprus VAT Law. |
| `9` | number | Cyprus reduced rate (9%) — applicable to certain services. |
| `19` | number | Cyprus standard rate. |
| `"EXEMPT"` | string | VAT-exempt supply. No VAT charged; no right to input VAT deduction on related costs. |
| `"REVERSE_CHARGE"` | string | EU reverse charge (Intrastat/Article 196). See REVERSE_CHARGE treatment below. |

The full rate table and applicability rules are in `vat_treatment_enum.md`. `lines_payload` does not validate business-logic applicability (e.g., whether the client is eligible for reverse charge) — that validation occurs in `ledger.decide_vat_treatment` before line items are written.

### REVERSE_CHARGE treatment

When `vat_rate = "REVERSE_CHARGE"`:

- `vat_amount_eur` is always `0`.
- `line_total_incl_vat_eur = line_total_eur` (no VAT added).
- The invoice PDF must include the text: **"VAT reverse charge applicable — the recipient is liable for VAT under Article 196 of Council Directive 2006/112/EC."**
- The `invoices` row must carry `has_reverse_charge = true` (a boolean column checked by `in_workflow.render_invoice_pdf` to inject the statutory notice).

Failure to include the statutory notice when `has_reverse_charge = true` is a lint-time error in the PDF renderer — not a runtime validation.

### EXEMPT treatment

When `vat_rate = "EXEMPT"`:

- `vat_amount_eur` is always `0`.
- `line_total_incl_vat_eur = line_total_eur`.
- No statutory notice is required on the invoice PDF, but the accountant is expected to have confirmed the exemption basis before issuing.

---

## Amendment guard

Once an invoice transitions to `SENT` status, `lines_payload` is immutable. The immutability is enforced by:

1. **Application layer:** `in_workflow.update_invoice_lines` rejects any call where the invoice `status` is not `DRAFT`.
2. **Database layer:** A Postgres trigger on `invoices` raises an exception if `lines_payload` is modified on any row where `status IN ('SENT', 'PAID', 'PARTIALLY_PAID', 'OVERPAID', 'CREDITED', 'VOIDED')`.

If a correction is required after `SENT`:

1. Void the original invoice via `in_workflow.void_invoice` — this triggers automatic credit note creation (`CN-YYYY-NNNN` series).
2. Create a replacement invoice with the corrected line items.
3. Issue the replacement invoice — a new `INV-YYYY-NNNN` sequence number is allocated.

See `invoice_amendment_policy.md` for the full amendment workflow, including the case where the correction is discovered after period finalization (which requires an `IN_ADJUSTMENT` run).

---

## Validation summary

| Check | Enforcement point | Error if violated |
| --- | --- | --- |
| Array length 1–200 | Postgres `CHECK` constraint | Row insert/update rejected |
| `quantity > 0` | `in_workflow.validate_invoice_lines` on save | Draft save rejected |
| `unit_price_eur >= 0` | `in_workflow.validate_invoice_lines` on save | Draft save rejected |
| `discount_pct` in `[0, 100]` | `in_workflow.validate_invoice_lines` on save | Draft save rejected |
| `vat_rate` in allowed set | `in_workflow.validate_invoice_lines` on save | Draft save rejected |
| Computed fields consistent | `in_workflow.validate_invoice_totals` before SENT transition | Transition rejected |
| `SUM(line_total_incl_vat_eur)` ≈ `total_amount_eur` (±0.01 EUR) | `in_workflow.validate_invoice_totals` before SENT transition | Transition rejected |
| `lines_payload` immutable post-SENT | Postgres trigger | Update rejected |

---

## Cross-references

- `invoice_line_item_schema.md` — DDL for any normalised line-item shadow tables used in reporting queries
- `invoice_pdf_schema.md` — PDF render spec; references `lines_payload` field names for column layout
- `invoice_amendment_policy.md` — amendment and void workflow for SENT invoices
- `vat_treatment_enum.md` — full VAT rate applicability matrix for Cyprus
- `invoice_numbering_sequence_policy.md` — sequence allocation that happens at DRAFT → SENT transition
- `data_layer_conventions_policy.md` — canonical JSON serialization rules; currency as decimal-precise string in archive contexts
