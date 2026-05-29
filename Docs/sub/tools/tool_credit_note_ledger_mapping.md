# tool_credit_note_ledger_mapping

**Category:** Tools · **Owning block:** 11 — Ledger & Cyprus VAT Engine · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The contract from Block 13's credit-note issuance to Block 11's ledger entry generation. Per the 2026-05-08 amendment: credit notes route through `REFUND_OUT` / `REFUND_IN` transaction types, and the credit-note number is the matched evidence (replacing the missing-invoice flow that would have been used otherwise).

This is the canonical Stage 1 cross-block contract between credit-note lifecycle and ledger preparation — the prior architecture had a gap where Block 11 didn't know how to handle credit notes.

---

## Function signature

```ts
ledger.prepare_credit_note_entries({
  credit_note_id: uuid,
  business_id: uuid,
  original_invoice_id: uuid,
  credit_amount_eur_cents: integer,
  vat_amount_eur_cents: integer,
  effective_date: date,                  // for VAT-period assignment (per Cyprus VAT period dual-date rule)
  effective_period_year: integer,        // Cyprus VAT-period year
  effective_period_quarter: integer,     // Cyprus VAT-period quarter (1-4)
  credit_note_kind: "REFUND" | "DISCOUNT" | "CORRECTION" | "WRITE_OFF",
}): {
  ledger_entries: LedgerEntry[],         // primary + VAT reversal pair (3 entries typically)
  reverse_charge_handled: boolean,       // true if original was EU_REVERSE_CHARGE
  vies_impact: {
    record_to_decrement?: ViesRecord,    // present when original was VIES-eligible
  } | null,
  audit_event_id: uuid,
}
```

## Routing per direction

| Original invoice direction | Credit note direction | `transaction_type` route | Cyprus VAT period assignment |
| --- | --- | --- | --- |
| `IN_INCOME` (invoice issued by Cyprus business) | Credit out (refund / discount) | `REFUND_OUT` | Per Cyprus dual-date rule (Block 13 Phase 11): the credit-note issuance date is the CN number sequence; the accounting-impact date is the original invoice's period. The Cyprus VAT return assigns the credit to the **original** period for VAT-return purposes, current period for ledger movement. |
| `OUT_EXPENSE` (invoice received from supplier) | Credit in (supplier-issued credit) | `REFUND_IN` | Same dual-date rule, reversed direction. |

The transaction-type routing happens at credit-note creation; the call to this tool happens during ledger preparation.

## Ledger entries produced

### Case 1: `REFUND_OUT` for `IN_INCOME` credit note (Cyprus business issues credit to customer)

If original invoice was `DOMESTIC_STANDARD` / `DOMESTIC_REDUCED` / `DOMESTIC_ZERO`:

```
DR  Revenue Reversal Account (mirror of original revenue account)
DR  VAT Output Reversal (reverses original VAT output)  -- only if VAT > 0
CR  Trade Debtors (or Bank if cash refund)
```

If original invoice was `EU_REVERSE_CHARGE`:

```
DR  Revenue Reversal Account
CR  Trade Debtors
```

No VAT entry (the original supplier carried zero VAT; the customer's reverse-charge VAT is their concern). The VIES record decrements per `vies_record_format`.

If original invoice was `NON_EU_SERVICE`:

```
DR  Revenue Reversal Account
CR  Trade Debtors
```

No VAT entry (zero-rated export of services); no VIES impact (NON_EU_SERVICE is not VIES-reportable per `vat_treatment_enum`).

### Case 2: `REFUND_IN` for `OUT_EXPENSE` credit note (supplier credits Cyprus business)

If original expense was `DOMESTIC_STANDARD` / `DOMESTIC_REDUCED`:

```
DR  Trade Creditors (or Bank if cash refund)
CR  Expense Account Reversal (mirror of original)
CR  VAT Input Reversal (reverses original VAT reclaim)  -- only if VAT > 0
```

If original expense was `EU_REVERSE_CHARGE`:

```
DR  Trade Creditors
DR  VAT Reclaim Reversal (reverses original derived reclaim entry)
CR  Expense Account Reversal
CR  VAT Output Reversal (reverses original derived output entry)
```

Four entries — the reverse-charge pair reversal alongside the primary reversal.

If original expense was `IMPORT_OR_ACQUISITION`:

```
DR  Trade Creditors
CR  Expense Account Reversal
+ derived VAT entries reversed per import/acquisition flow
```

## VAT amount inheritance

Per `vat_rate_table_cyprus`: the VAT amount on the credit note matches the original transaction's VAT amount, scaled by `credit_amount / original_amount`. The credit-note line items carry the per-line VAT breakdown; the consolidated ledger entry uses the aggregated total.

## Side-effect class and AI tier

- **Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
- **AI tier:** `NONE`

The tool writes new rows in `draft_ledger_entries` (the credit-note's entry set). It does NOT modify the original invoice's ledger entries — those remain as historical record.

Mobile clients are rejected at the API gateway for all write operations on this tool. See `mobile_write_rejection_endpoints` for the full rejection surface.

## Audit events

| Event | When |
| --- | --- |
| `LEDGER_ENTRIES_PREPARED` | After entries persisted (Block 11) |
| `INVOICE_CREDITED` | Lifecycle event on the original invoice (Block 13) |

## Adjustment-run handling

If the original invoice is in a FINALIZED period and the credit note's effective date falls in that period:

- Per Cyprus dual-date rule: the credit note's number lives in the current period's CN sequence
- The accounting impact (the reversal entries) goes through an IN_ADJUSTMENT run for the original period
- Manifest-version chain captures the adjustment

If the credit-note effective date is in the current (non-finalized) period: the entries go to `draft_ledger_entries` normally.

## Cumulative-credit-cap invariant

Per Block 13 Phase 01: a single invoice cannot accumulate credit notes exceeding the invoice's original amount. Block 13's row-locking SQL pattern enforces this at credit-note creation time:

```sql
SELECT amount_eur_cents,
       COALESCE(SUM(cn.amount_eur_cents), 0) AS total_credited
FROM invoices i
LEFT JOIN credit_notes cn ON cn.original_invoice_id = i.id
WHERE i.id = $1
FOR UPDATE;

-- Reject if (total_credited + new_credit) > amount_eur_cents
```

The tool surfaces this rejection as `CREDIT_NOTE_AMOUNT_EXCEEDS_INVOICE` error.

## VIES decrement

Per the 2026-05-08 amendment integrated into `vies_record_format`: when a credit note reverses an EU_REVERSE_CHARGE or IMPORT_OR_ACQUISITION transaction, the matching VIES record decrements proportionally.

- Same-quarter credit: subtract from the current quarter's VIES record (net effect)
- Cross-quarter credit: per Cyprus VIES rules, the decrement applies to the ORIGINAL quarter's record (the dual-date rule extends to VIES; later VIES submissions show the corrected record)

`vies_impact.record_to_decrement` carries the (client_country_iso, client_vat_number, period_year, period_quarter, amount) tuple of the affected record. Block 16's VIES export consumes this tuple.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `ledger.prepare_credit_note_entries` (1 credit note, 0 reverse charge) | 200 ms | 600 ms | 1.5 s |
| `ledger.prepare_credit_note_entries` (1 credit note, EU_REVERSE_CHARGE reversal) | 300 ms | 1 s | 2 s |

## Registration

```ts
engine.registerTool({
  name: "ledger.prepare_credit_note_entries",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_credit_note_ledger_mapping#v1.input",
  output_schema_ref: "tool_credit_note_ledger_mapping#v1.output",
  audit_events: ["LEDGER_ENTRIES_PREPARED", "INVOICE_CREDITED"],
  description_ref: "Docs/sub/tools/tool_credit_note_ledger_mapping.md",
});
```

## Cross-references

- `tool_naming_convention_policy` — naming + registration
- `vat_treatment_enum` — original transaction's VAT treatment drives reversal pattern
- `vat_rate_table_cyprus` — VAT amount calculations
- `vies_record_format` — VIES decrement payload
- `transaction_type_enum` — `REFUND_OUT` / `REFUND_IN` routing
- `tool_invoice_lifecycle_integration` — `in_workflow.mark_invoice_credited` lifecycle function
- `tool_bad_debt_expense` — sibling lifecycle integration (WRITE_OFF kind)
- `audit_log_policies` — event naming
- Block 11 Phase 07 — type-aware ledger preparation dispatcher
- Block 13 Phase 06 — pro-forma conversion, credit notes & write-off
- Block 13 Phase 11 — IN_ADJUSTMENT workflow + dual-date rule
- `mobile_write_rejection_endpoints` — mobile write rejection enforcement
- 2026-05-08 decisions-log amendment — credit note ↔ ledger contract pinned

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.