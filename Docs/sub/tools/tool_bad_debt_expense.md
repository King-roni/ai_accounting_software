# tool_bad_debt_expense

**Category:** Tools · **Owning block:** 13 — IN Workflow + Invoice Generator · **Co-owner:** 11 — Ledger & Cyprus VAT Engine · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

When an invoice is written off, Block 13's lifecycle action `in_workflow.mark_invoice_written_off` triggers Block 11's lifecycle-keyed ledger preparation (`ledger.prepare_invoice_lifecycle_entries` per the 2026-05-08 amendment) to produce bad-debt-expense ledger entries.

This is one of the few ledger paths that is **lifecycle-keyed, not transaction-keyed** — there's no source bank transaction for a write-off; the trigger is the invoice transitioning into WRITTEN_OFF state. The 2026-05-08 amendment specifically added this dispatcher path to Block 11 Phase 07.

---

## Function signature

```ts
in_workflow.mark_invoice_written_off({
  invoice_id: uuid,
  business_id: uuid,
  reason: string,                        // ≥ 10 chars, ≤ 1000 chars per adjustment_reason_text_policy shape
  written_off_amount: integer,           // EUR cents — typically the invoice outstanding balance
  written_off_at: date,                  // user-supplied write-off date; defaults to today
  actor_user_id: uuid,
  actor_role: Role,
}): {
  invoice: Invoice,
  ledger_entries: LedgerEntry[],         // pair produced by Block 11
  audit_event_id: uuid,
}
```

Internally, after updating the invoice state, the tool calls:

```ts
ledger.prepare_invoice_lifecycle_entries({
  invoice_id,
  business_id,
  lifecycle_event: "WRITTEN_OFF",
  effective_date: written_off_at,
  amount_eur_cents: written_off_amount,
});
```

The dispatcher (Block 11 Phase 07's `prepare_invoice_lifecycle_entries`) produces the bad-debt-expense entry pair:

```
DR  Bad Debts Expense       (chart account 6850 in Cyprus default chart)
CR  Trade Debtors (or AR)   (chart account 1100 series)
```

Both entries carry `vat_treatment = OUTSIDE_SCOPE` (the original invoice's VAT is unaffected — Stage 2+ may add VAT relief per `pro_forma_policies`).

## Side-effect class and AI tier

- **Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
- **AI tier:** `NONE`

The tool writes:
1. `invoices.status = WRITTEN_OFF`, `invoices.written_off_at`, `invoices.written_off_reason`, `invoices.written_off_by_user_id`
2. Two new rows in `draft_ledger_entries` (the bad-debt-expense pair)
3. Audit events: `INVOICE_WRITTEN_OFF`, `LEDGER_ENTRIES_PREPARED`

## Audit events

| Event | When |
| --- | --- |
| `INVOICE_WRITTEN_OFF` | After lifecycle transition succeeds | `{ invoice_id, business_id, reason, written_off_amount, written_off_at, actor_user_id }` |
| `LEDGER_ENTRIES_PREPARED` | After ledger entries created (Block 11 emits) | `{ invoice_id, lifecycle_event: "WRITTEN_OFF", entry_count: 2 }` |

Both events fire in the same operational transaction; the audit emission per `audit_log_policies` runs out-of-band as separate short transactions.

## Pre-conditions

The lifecycle function fails (`INVOICE_LIFECYCLE_TRANSITION_FAILED`) if:

- Invoice is in DRAFT, SENT, PAID, FINALIZED-FULLY-PAID (state-machine rule per Block 13 Phase 03)
- Invoice was already WRITTEN_OFF (idempotency — second call is rejected)
- `written_off_amount > invoice.outstanding_balance_cents` (cannot write off more than outstanding)
- Cyprus VAT period is FINALIZED for the period containing `written_off_at`, AND no IN_ADJUSTMENT is currently open for that period

Acceptable starting states for write-off:

- `PAYMENT_EXPECTED` (the invoice was sent, expecting payment, but never paid)
- `PARTIALLY_PAID` (some payment received; outstanding balance is being written off)
- `OVERDUE_PAYMENT_EXPECTED` (the typical real-world write-off case)

Write-off of a `WRITTEN_OFF` invoice for additional amount (Stage 2+) — out of MVP scope.

## Adjustment-run interaction

If the period containing `written_off_at` is FINALIZED, write-off must happen via an open IN_ADJUSTMENT run for that period. The lifecycle function checks for an open adjustment_run_id; if found, the write-off succeeds; if not, it rejects with `INVOICE_PERIOD_FINALIZED_REQUIRES_ADJUSTMENT_RUN`.

Block 13 Phase 11's `v_invoices_with_adjustments` view reflects the WRITTEN_OFF state via the manifest-versioned overlay; the base `invoices` row is unchanged for the finalized period.

## VAT treatment

The bad-debt-expense entry pair is currently `OUTSIDE_SCOPE`. The original invoice's VAT remains as originally posted (Cyprus VAT-relief on bad debt is Stage 2+ per `pro_forma_policies` deferral).

Once VAT relief is enabled post-MVP, a third entry pair reverses the VAT output:

```
DR  VAT Output Account
CR  Bad Debt VAT Recoverable
```

Per the eventual Cyprus VAT-relief rules. This sub-doc commits to MVP behavior; the VAT-relief path is documented in `vat_relief_on_bad_debt_policy`.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `in_workflow.mark_invoice_written_off` end-to-end | 200 ms | 800 ms | 2 s |

Latency dominated by Block 11 Phase 07's `prepare_invoice_lifecycle_entries` call. The lifecycle function itself is fast (one row lock + status update).

## Concurrency

Single-invoice mark-write-off is serialized by row lock on `invoices.id`. Concurrent calls on the same invoice from different transactions: second call rejects with `INVOICE_LIFECYCLE_TRANSITION_FAILED` (already WRITTEN_OFF).

## Permission

`REVIEW_QUEUE_RESOLVE` surface — the action is typically invoked from the review queue as a resolution action. Owner / Admin / Bookkeeper / Accountant per `permission_matrix`.

Mobile rejection: REJECTED per `mobile_write_rejection_endpoints` (lifecycle write).

## Registration

```ts
engine.registerTool({
  name: "in_workflow.mark_invoice_written_off",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_bad_debt_expense#v1.input",
  output_schema_ref: "tool_bad_debt_expense#v1.output",
  audit_events: ["INVOICE_WRITTEN_OFF", "LEDGER_ENTRIES_PREPARED", "INVOICE_LIFECYCLE_TRANSITION_FAILED"],
  description_ref: "Docs/sub/tools/tool_bad_debt_expense.md",
});
```

## Cross-references

- `tool_invoice_lifecycle_integration` — sibling lifecycle integration (matching-driven)
- `tool_credit_note_ledger_mapping` — sibling for credit notes
- `pro_forma_policies` — Stage 2+ VAT relief on bad debt deferral
- `audit_log_policies` — `INVOICE_*` event naming
- `vat_treatment_enum` — `OUTSIDE_SCOPE` for bad-debt-expense MVP behavior
- `cyprus_default_chart_catalog` — bad-debt-expense account code (6850)
- Block 11 Phase 07 — `prepare_invoice_lifecycle_entries` dispatcher (canonical home)
- Block 13 Phase 03 — invoice lifecycle state machine
- Block 13 Phase 06 — pro-forma conversion, credit notes & write-off
- 2026-05-08 decisions-log amendment — Block 11 Phase 07 lifecycle dispatcher path added

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.