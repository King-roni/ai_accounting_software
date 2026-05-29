# document_line_items_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 11 — Ledger & Cyprus VAT Engine · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The JSONB shape stored on `documents.line_items_json` for multi-line invoice detail. Per Stage 1 decision: "Multi-line invoices: One consolidated ledger entry per invoice; line items preserved on the underlying document record for drill-down."

Block 09 Phase 04's field extraction populates this column; Block 11 Phase 08's multi-line consolidation reads it; Block 16's drill-down view renders the line-item breakdown when expanded.

---

## Shape

```typescript
type DocumentLineItems = LineItem[];

type LineItem = {
  line_index: integer,                    // 0-based; preserves invoice order
  description: string,                    // post-redaction line description (free text from invoice)
  quantity: numeric,                      // typically integer but allows fractional (e.g., consulting hours)
  unit_eur_cents: bigint,                 // unit price in EUR minor units, NON-NEGATIVE
  line_total_eur_cents: bigint,           // quantity × unit (pre-VAT)
  vat_rate_pct: numeric(5, 2),            // e.g., 19.00, 9.00, 5.00, 0.00
  vat_amount_eur_cents: bigint,           // VAT amount for this line
  tag_hint?: string,                      // optional per-line tag hint (Block 08 may use as a hint)
  account_code_hint?: string,             // optional per-line chart code hint (Block 11 may use as a hint)
};
```

### Concrete example — three-line invoice

```json
[
  {
    "line_index": 0,
    "description": "Web development services — January",
    "quantity": 40,
    "unit_eur_cents": 7500,
    "line_total_eur_cents": 300000,
    "vat_rate_pct": 19.00,
    "vat_amount_eur_cents": 57000
  },
  {
    "line_index": 1,
    "description": "Server hosting — January",
    "quantity": 1,
    "unit_eur_cents": 5000,
    "line_total_eur_cents": 5000,
    "vat_rate_pct": 19.00,
    "vat_amount_eur_cents": 950
  },
  {
    "line_index": 2,
    "description": "Travel reimbursement — Nicosia",
    "quantity": 1,
    "unit_eur_cents": 25000,
    "line_total_eur_cents": 25000,
    "vat_rate_pct": 0.00,
    "vat_amount_eur_cents": 0,
    "tag_hint": "Travel — deductible"
  }
]
```

In this example: €3,300 net + €629.50 VAT = €3,929.50 total. The mixed-VAT-rate case is fully representable.

## Validation rules

### Rule 1: `line_index` is sequential and 0-based

Lines must be ordered `0, 1, 2, …` with no gaps. The extraction layer (Block 09 Phase 04) populates indices based on visual order on the source invoice.

### Rule 2: `line_total_eur_cents = quantity × unit_eur_cents` (within rounding tolerance)

Allowed delta: ±1 cent. Beyond tolerance, the extraction layer raises `intake.extraction_amount_arithmetic_mismatch` per `extraction_policies` (the merged extraction-policies doc).

### Rule 3: `vat_rate_pct` is from Cyprus standard rates

Allowed values: 0.00, 5.00, 9.00, 19.00, plus the deferred Stage 2 rates for non-Cyprus invoices (per `vat_rate_table_cyprus`). Anything else routes the document to `Possible Tax-VAT Issue` per `issue_type_to_group_mapping`.

### Rule 4: `vat_amount_eur_cents ≈ line_total × vat_rate_pct / 100` (within rounding tolerance)

Allowed delta: ±1 cent per line. Multi-line totals may accumulate small drifts; the document-level total cross-check (`documents.total_amount_eur_cents = sum(line_total) + sum(vat_amount)`) is the authoritative validation.

### Rule 5: Currency uniformity

All lines share the document's currency (`documents.currency`). Per Stage 1 invoice-currency-locked-at-creation rule, mixed-currency line items are not supported.

### Rule 6: At least one line

A document with `line_items_json = []` is rejected. Single-line invoices have one entry with `line_index = 0`.

## Multi-line consolidation (Block 11 Phase 08)

Per Stage 1: "One consolidated ledger entry per invoice; line items preserved on the underlying document record for drill-down."

Per `multiline_invoice_consolidation_policy` (now merged into `redaction_policies` cross-references): the consolidation rule is "multi-line tag-equality" — if every line shares the same primary tag (or maps to the same chart account), produce ONE consolidated ledger entry. If lines map to different accounts (e.g., services + travel as in the example above), produce multiple PRIMARY ledger entries.

Multi-line splits per chart account, NOT per line. A 50-line invoice that all maps to "Office Supplies" produces one ledger entry; an invoice split between "Office Supplies" and "Travel" produces two.

## Storage

Stored on `documents.line_items_json` (JSONB). Column is `NOT NULL` when `documents.has_line_items = true`:

```sql
CHECK (
  NOT has_line_items OR line_items_json IS NOT NULL
)
```

per the `documents` schema (Block 09 Phase 01, the canonical owner).

The JSONB serialization uses canonical JSON per `data_layer_conventions_policy` — keys sorted lexically, currency-as-integer-cents per the currency-special-case rule.

## Block 16 drill-down rendering

The drill-down view per `drill_down_schemas` reads `documents.line_items_json` and renders one row per line. Tabular figures per `tabular_figures_column_width_ui_spec`. Mobile rejection: viewing is allowed (read-only); editing is desktop-only per `mobile_write_rejection_endpoints`.

## OCR confidence

Per `extraction_policies` (the merged policy doc): each line carries an implicit confidence from the extraction layer. Per-line confidences are NOT stored in `line_items_json` (to keep the structure clean); instead, `documents.extraction_confidence` carries the aggregate per-field confidence which extends to line items.

If individual line confidence is low (e.g., < 0.7 on a `line_total_eur_cents` field), the document routes to `Needs Confirmation` per the review-queue routing.

## Line-item validation: valid vs invalid example

**Valid line item** — all constraints satisfied:
```json
{
  "line_index": 0,
  "description": "Consulting services — March 2026",
  "quantity": 10,
  "unit_eur_cents": 15000,
  "line_total_eur_cents": 150000,
  "vat_rate_pct": 19.00,
  "vat_amount_eur_cents": 28500
}
```
`line_total = 10 × 15000 = 150000` (exact). `vat_amount = 150000 × 0.19 = 28500` (exact). `vat_rate_pct = 19.00` is a valid Cyprus standard rate.

**Invalid line item** — arithmetic mismatch:
```json
{
  "line_index": 0,
  "description": "Consulting services — March 2026",
  "quantity": 10,
  "unit_eur_cents": 15000,
  "line_total_eur_cents": 160000,
  "vat_rate_pct": 19.00,
  "vat_amount_eur_cents": 30400
}
```
`line_total_eur_cents = 160000` but `10 × 15000 = 150000` — delta of 10000 cents (€100), exceeding the ±1 cent tolerance. Routes to `intake.extraction_amount_arithmetic_mismatch`.

## Cross-references

- `documents` schema (Block 09 Phase 01) — host table
- `data_layer_conventions_policy` — canonical JSON, currency-as-cents
- `extraction_policies` — extraction confidence rules
- `vat_rate_table_cyprus` — allowed VAT rates
- `invoice_line_item_schema` — the invoice-side equivalent schema for issued invoices (Block 13)
- `multiline_invoice_consolidation_policy` — Block 11 consolidation rule
- `drill_down_schemas` — Block 16 rendering
- `tabular_figures_column_width_ui_spec` — table formatting
- `mobile_write_rejection_endpoints` — read-only on mobile
- Block 09 Phase 04 — field extraction (populator)
- Block 11 Phase 08 — VAT amount, evidence & accountant-review flags (consumer)
- Block 16 Phase 08 — drill-down list & detail views (consumer)
- Stage 1 decision — line items preserved on document for drill-down
