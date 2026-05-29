# adjustment_delta_payload_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owners:** 03, 12, 13 · **Stage:** 4 sub-doc (Layer 2)

The per-`delta_kind` JSONB shape stored in `adjustment_records.delta_payload`. Sibling of `adjustment_record_schema` (Block 03) — that doc defines the row; this one defines the JSONB. Each of the 8 `delta_kind` values from `delta_kind_enum` carries a structurally distinct payload; the union is enforced by a CHECK trigger plus a server-side JSON Schema validator (Block 04 Phase 01 helper). Consumers: Block 11 (ledger replay), Block 15 (archive manifest v2+), Block 16 (drill-down history rendering).

---

## Common envelope

Every payload is canonical JSON per `data_layer_conventions_policy` (RFC 8785, sorted keys, no insignificant whitespace, EUR-minor-units as integer or `"12.34"` string — never floats). All shapes share a common envelope:

```json
{
  "old_value": { ... },
  "new_value": { ... },
  "fields_changed": ["..."],
  "additional_context": { ... }
}
```

- `old_value` — the field state captured from the previously-finalized record at adjustment-start
- `new_value` — the state to apply on adjustment-commit
- `fields_changed` — explicit list of leaf paths that differ; redundant with the diff of `old_value`/`new_value` but kept for cheap querying
- `additional_context` — per-kind structured metadata; never PII (counterparty identifiers stay encrypted on the target row)

Keys outside this envelope are forbidden. The JSON Schema validator rejects unknown top-level keys with `OTHER_ADDITIONAL_KEY_REJECTED`. This is intentional — adjustments are a forensic record, and silent acceptance of extra keys would weaken cross-version replay guarantees.

## Per-`delta_kind` shapes

### CORRECT_VAT_TREATMENT (OUT_ADJUSTMENT)

```json
{
  "old_value": { "vat_treatment": "STANDARD_19" },
  "new_value": { "vat_treatment": "REVERSE_CHARGE_EU" },
  "fields_changed": ["vat_treatment"],
  "additional_context": {
    "target_transaction_id": "01935f0d-...",
    "ledger_recompute_required": true,
    "vies_period_reassignment_required": false
  }
}
```

- `old_value.vat_treatment` and `new_value.vat_treatment` MUST be members of the 8-value `vat_treatment_enum`
- `ledger_recompute_required` defaults to `true`; the OUT_ADJUSTMENT engine reads this flag and routes Block 11 recompute
- `vies_period_reassignment_required` flips true when the new treatment crosses the VIES-eligibility boundary

### ADD_EVIDENCE (OUT_ADJUSTMENT)

```json
{
  "old_value": { "primary_document_id": null, "document_count": 0 },
  "new_value": { "primary_document_id": "01935f0d-...", "document_count": 1 },
  "fields_changed": ["primary_document_id", "document_count"],
  "additional_context": {
    "target_transaction_id": "01935f0d-...",
    "document_id": "01935f0d-...",
    "evidence_hash": "9b74c989..."
  }
}
```

- `evidence_hash` MUST be 64 lowercase hex characters (SHA-256 per `data_layer_conventions_policy`)
- `old_value.primary_document_id` may be null; `new_value.primary_document_id` MUST NOT be null

### RECLASSIFY_TYPE (OUT_ADJUSTMENT)

```json
{
  "old_value": { "transaction_type": "OUT_EXPENSE_OTHER" },
  "new_value": { "transaction_type": "OUT_EXPENSE_FUEL" },
  "fields_changed": ["transaction_type"],
  "additional_context": {
    "target_transaction_id": "01935f0d-...",
    "dispatcher_recompute_required": true,
    "classification_layer_at_reclassify": "USER_OVERRIDE"
  }
}
```

- Both type values MUST be members of the closed 12-value `transaction_type_enum` (`UNKNOWN` excluded — reclassification AWAY from UNKNOWN is allowed, TO UNKNOWN is rejected)

### CORRECT_MATCH (OUT_ADJUSTMENT)

```json
{
  "old_value": { "matched_document_id": "01935f0d-...", "match_level": "STRONG_PROBABLE" },
  "new_value": { "matched_document_id": "01935f0d-...", "match_level": "EXACT" },
  "fields_changed": ["matched_document_id", "match_level"],
  "additional_context": {
    "target_transaction_id": "01935f0d-...",
    "prior_match_record_id": "01935f0d-...",
    "new_match_record_id": "01935f0d-..."
  }
}
```

- `old_value.match_level` and `new_value.match_level` MUST be members of the closed 4-value `match_level_enum` (`EXACT`, `STRONG_PROBABLE`, `WEAK_PROBABLE`, `NO_MATCH`)
- `old_value.matched_document_id` may be null when the original state was `NO_MATCH`

### CONVERT_TO_TAX_INVOICE (IN_ADJUSTMENT)

```json
{
  "old_value": { "invoice_kind": "PRO_FORMA", "tax_invoice_number": null },
  "new_value": { "invoice_kind": "TAX_INVOICE", "tax_invoice_number": "INV-2026-0042" },
  "fields_changed": ["invoice_kind", "tax_invoice_number"],
  "additional_context": {
    "target_invoice_id": "01935f0d-...",
    "tax_invoice_sequence_consumed": "01935f0d-...",
    "prior_pdf_superseded_id": "01935f0d-..."
  }
}
```

- `tax_invoice_number` MUST be non-null in `new_value` and match the per-business sequence pattern

### ISSUE_CREDIT_NOTE (IN_ADJUSTMENT)

```json
{
  "old_value": { "outstanding_amount_cents": 119000, "status": "SENT" },
  "new_value": { "outstanding_amount_cents": 0, "status": "CREDITED" },
  "fields_changed": ["outstanding_amount_cents", "status"],
  "additional_context": {
    "target_invoice_id": "01935f0d-...",
    "credit_note_invoice_id": "01935f0d-...",
    "credit_amount_cents": 119000,
    "credit_reason_code": "BILLING_ERROR"
  }
}
```

- All amounts in EUR minor units as JSON integer per the currency rule in `data_layer_conventions_policy`
- `credit_amount_cents` MUST equal `old_value.outstanding_amount_cents − new_value.outstanding_amount_cents`

### WRITE_OFF_INVOICE (IN_ADJUSTMENT)

```json
{
  "old_value": { "outstanding_amount_cents": 50000, "status": "OVERDUE" },
  "new_value": { "outstanding_amount_cents": 0, "status": "WRITTEN_OFF" },
  "fields_changed": ["outstanding_amount_cents", "status"],
  "additional_context": {
    "target_invoice_id": "01935f0d-...",
    "write_off_amount_cents": 50000,
    "write_off_ledger_account": "6900",
    "bad_debt_threshold_breached_at": "2026-03-15T00:00:00Z"
  }
}
```

### OTHER (either direction)

```json
{
  "old_value": { "<arbitrary_field_path>": "..." },
  "new_value": { "<arbitrary_field_path>": "..." },
  "fields_changed": ["..."],
  "additional_context": {
    "target_record_id": "01935f0d-...",
    "target_record_kind": "transactions",
    "free_form_explanation": "..."
  }
}
```

`OTHER` is the unconstrained catch-all. Per `adjustment_record_schema`: `requires_accountant_review` is automatically set true. The validator only enforces the envelope; the inner shapes are free-form. `reason_text` on the parent row carries the substantive narrative; the JSONB is the structured side.

## Validation rules

1. Top-level keys are exactly `{old_value, new_value, fields_changed, additional_context}` — no more, no less
2. `fields_changed` is a non-empty array of unique strings; each string is a valid JSON Pointer-style leaf path
3. Every leaf in `fields_changed` MUST be present in BOTH `old_value` and `new_value` (the case where `old_value` is null structurally is rejected — use the literal JSON `null` value at the leaf)
4. Amounts NEVER float; integer minor units OR decimal-precise string per the currency rule
5. Enum values MUST belong to the closed enum named in this doc — drift caught at INSERT time by the validator

The validator is `validate_adjustment_delta_payload(delta_kind, jsonb) → boolean`, implemented in Block 04 Phase 01 alongside the other JSON validators. A `BEFORE INSERT` trigger on `adjustment_records` rejects rows where the validator returns false.

## Evolution rules

The 8 `delta_kind` values are a closed enum locked by the 2026-05-08 amendment. Adding a 9th value requires:
1. A `Docs/decisions_log.md` amendment
2. A new shape section in this sub-doc
3. The direction-enforcement trigger from `adjustment_record_schema` updated to route the new value

Per-shape **field additions** to `additional_context` are minor changes — no amendment required if the field is optional. Field **removals** or required-key additions to `additional_context` are major changes — they invalidate replay of older `adjustment_records.delta_payload` rows and require an amendment plus a migration path (the validator carries a `schema_version` discriminator in `additional_context.schema_version`, defaulting to `1`).

## RLS

The `delta_payload` JSONB inherits RLS from `adjustment_records` per `adjustment_record_schema` — tenant-isolated, role-visibility per `permission_matrix`. No separate JSONB-column policy; Postgres RLS operates at the row level.

## Audit events

| Event | When | Payload sketch |
| --- | --- | --- |
| `OUT_ADJUSTMENT_RECORD_CREATED` | INSERT in an OUT_ADJUSTMENT run | `{ adjustment_record_id, delta_kind, target_record_id, fields_changed }` |
| `IN_ADJUSTMENT_RECORD_CREATED` | INSERT in an IN_ADJUSTMENT run | Same shape |
| `ADJUSTMENT_TOUCHED_RECORD` | Adjustment-driven write to operational tables | Per `out_adjustment_policies` Section 1 (dual-run-id pattern) |

Payload values exclude the full `delta_payload` — that's available by joining `adjustment_records.adjustment_record_id`. The audit event keeps payload size bounded; the JSONB body lives on the operational row.

## Mobile

Adjustment intake itself is desktop-only per `mobile_write_rejection_endpoints` (`out_workflow.adjustment_intake`, `in_workflow.adjustment_intake`). The JSONB payload is produced server-side; mobile never authors it directly.

## Cross-references

- `adjustment_record_schema` — parent table, `delta_kind_enum`, direction-enforcement trigger
- `data_layer_conventions_policy` — canonical JSON, SHA-256 hex, EUR-minor-units currency rule
- `audit_log_policies` — `*_ADJUSTMENT_RECORD_CREATED` and `ADJUSTMENT_TOUCHED_RECORD` naming + chain partitioning
- `out_adjustment_policies` — dual-run-id audit pattern, multiple-adjustments ordering
- `transaction_type_enum` — closed 12-value enum for `RECLASSIFY_TYPE`
- `vat_treatment_enum` — closed 8-value enum for `CORRECT_VAT_TREATMENT`
- `match_level_enum` — closed 4-value enum for `CORRECT_MATCH`
- Block 04 Phase 01 — `validate_adjustment_delta_payload` helper
- Block 12 Phase 09 — OUT_ADJUSTMENT routing
- Block 13 Phase 11 — IN_ADJUSTMENT routing
- 2026-05-08 decisions-log amendment — combined `delta_kind` enum
