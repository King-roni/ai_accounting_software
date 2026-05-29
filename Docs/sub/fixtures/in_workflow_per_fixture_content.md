# IN Workflow Per-Fixture Content

**Category:** Fixtures · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

**Purpose.** Canonical fixture set for IN workflow live integration tests and development seed data. Each fixture is a self-contained scenario: it specifies the input payload delivered to the IN workflow, the expected database state after run completion, the invoice sequence numbers that must be allocated, and the audit events that must be emitted. Fixture data is inserted by the `LIVE_TEST` harness on test-run start and torn down on completion. Do not use these fixtures as production seed data.

Fixtures follow the format: `fixture_id`, `scenario_name`, `invoice_type`, `input_data`, `expected_output`.

---

## Fixture 1 — Standard tax invoice

**fixture_id:** `fix-in-001`
**scenario_name:** `standard_tax_invoice_three_line_items`
**invoice_type:** TAX

### input_data

```json
{
  "client_id": "01950000-0000-7000-0000-000000000001",
  "invoice_type": "TAX",
  "currency": "EUR",
  "issue_date": "2026-05-01",
  "due_date": "2026-05-31",
  "payment_terms_days": 30,
  "line_items": [
    {
      "description": "Consulting services — April 2026",
      "quantity": 1,
      "unit_price_cents": 250000,
      "vat_treatment": "STANDARD",
      "vat_rate": 0.19
    },
    {
      "description": "Catering supplies — April 2026",
      "quantity": 40,
      "unit_price_cents": 500,
      "vat_treatment": "REDUCED",
      "vat_rate": 0.09
    },
    {
      "description": "Educational materials — April 2026",
      "quantity": 10,
      "unit_price_cents": 2000,
      "vat_treatment": "EXEMPT",
      "vat_rate": 0.00
    }
  ]
}
```

**VAT line breakdown:**
- Line 1: net €2,500.00 · VAT 19% · VAT amount €475.00 · gross €2,975.00
- Line 2: net €200.00 · VAT 9% · VAT amount €18.00 · gross €218.00
- Line 3: net €200.00 · VAT exempt · VAT amount €0.00 · gross €200.00

### expected_output

```json
{
  "invoice_status": "SENT",
  "invoice_number_pattern": "INV-2026-NNNN",
  "invoice_number_series": "INV",
  "invoice_number_year": 2026,
  "total_net_cents": 290000,
  "total_vat_cents": 49300,
  "total_gross_cents": 339300,
  "line_item_count": 3,
  "vat_treatments_present": ["STANDARD", "REDUCED", "EXEMPT"]
}
```

**Required audit events (in order):**
1. `IN_WORKFLOW_RUN_CONFIGURED`
2. `INVOICE_CREATED`
3. `INVOICE_NUMBER_ALLOCATED`
4. `INVOICE_SENT`

**Invariants:**
- `invoice_number` matches `INV-2026-\d{4}`
- All three `vat_rate` values are stored on the `invoice_line_items` rows, not collapsed
- `outstanding_balance_cents` equals `total_gross_cents` (no payments applied)
- `currency` is `EUR`

---

## Fixture 2 — Pro-forma to tax invoice conversion

**fixture_id:** `fix-in-002`
**scenario_name:** `pro_forma_to_tax_conversion`
**invoice_type:** PRO_FORMA → TAX

### input_data

**Step A — create pro-forma:**

```json
{
  "client_id": "01950000-0000-7000-0000-000000000002",
  "invoice_type": "PRO_FORMA",
  "currency": "EUR",
  "issue_date": "2026-04-10",
  "line_items": [
    {
      "description": "Software licence — Q2 2026",
      "quantity": 1,
      "unit_price_cents": 120000,
      "vat_treatment": "STANDARD",
      "vat_rate": 0.19
    }
  ]
}
```

**Step B — convert to tax invoice:**
Call `in_workflow.convert_pro_forma_to_tax` with the `invoice_id` from Step A; provide `tax_issue_date: "2026-04-15"`.

### expected_output

```json
{
  "pro_forma": {
    "invoice_number_series": "PRO",
    "invoice_number_pattern": "PRO-2026-NNNN",
    "final_status": "VOIDED",
    "void_reason": "CONVERTED_TO_TAX"
  },
  "tax_invoice": {
    "invoice_number_series": "INV",
    "invoice_number_pattern": "INV-2026-NNNN",
    "invoice_status": "SENT",
    "total_gross_cents": 142800,
    "parent_pro_forma_id": "<pro_forma_invoice_id from Step A>"
  }
}
```

**Required audit events:**
- Step A: `INVOICE_CREATED`, `INVOICE_NUMBER_ALLOCATED` (PRO series)
- Step B: `INVOICE_PRO_FORMA_CONVERTED_TO_TAX`, `INVOICE_VOIDED` (on the PRO invoice), `INVOICE_CREATED` (new TAX), `INVOICE_NUMBER_ALLOCATED` (INV series)

**Invariants:**
- The PRO-series invoice must reach `status = VOIDED` with `void_reason = CONVERTED_TO_TAX` before the INV-series invoice reaches `SENT`
- `tax_invoice.parent_pro_forma_id` must reference the original PRO invoice row
- Both sequence numbers are allocated in the same transaction; no gap is created in either series
- The original PRO invoice sequence counter is NOT reused; the counter increments monotonically

---

## Fixture 3 — Recurring invoice (IN_MONTHLY phase)

**fixture_id:** `fix-in-003`
**scenario_name:** `recurring_invoice_monthly_auto_generation`
**invoice_type:** TAX (recurring)

### input_data

**Prerequisite:** a `recurring_invoice_templates` row must exist for `client_id = 01950000-0000-7000-0000-000000000003` with:

```json
{
  "template_id": "01950000-0000-7000-0000-000000000031",
  "business_id": "<test_business_id>",
  "client_id": "01950000-0000-7000-0000-000000000003",
  "schedule_type": "MONTHLY",
  "billing_day": 1,
  "status": "ACTIVE",
  "line_items": [
    {
      "description": "Monthly retainer — {{period_label}}",
      "quantity": 1,
      "unit_price_cents": 50000,
      "vat_treatment": "STANDARD",
      "vat_rate": 0.19
    }
  ],
  "currency": "EUR",
  "payment_terms_days": 14
}
```

**Run trigger:** IN_MONTHLY run for `period_year = 2026`, `period_month = 5` with `recurring_invoice_enabled = true`.

### expected_output

```json
{
  "invoice_status": "SENT",
  "invoice_number_series": "INV",
  "invoice_number_pattern": "INV-2026-NNNN",
  "total_gross_cents": 59500,
  "generated_from_template_id": "01950000-0000-7000-0000-000000000031",
  "line_item_description": "Monthly retainer — May 2026"
}
```

**Required audit events (in order):**
1. `IN_WORKFLOW_RUN_CONFIGURED`
2. `RECURRING_INVOICE_GENERATED`
3. `INVOICE_CREATED`
4. `INVOICE_NUMBER_ALLOCATED`
5. `INVOICE_SENT`

**Invariants:**
- `RECURRING_INVOICE_GENERATED` event payload must include `template_id` and `workflow_run_id`
- `invoice.generated_from_template_id` is set; confirms the generation path
- If `recurring_invoice_enabled = false` on the run config, `RECURRING_INVOICE_GENERATION_SKIPPED` is emitted and no invoice row is created — this is the negative test path (see Fixture 3-B below)
- The `{{period_label}}` template variable is rendered as `May 2026` for `period_month = 5, period_year = 2026`

**Fixture 3-B (negative path):** identical setup but `recurring_invoice_enabled = false` on the run config. Expected: `RECURRING_INVOICE_GENERATION_SKIPPED` emitted, no new `invoices` row for this template and period.

---

## Fixture 4 — Credit note against issued invoice

**fixture_id:** `fix-in-004`
**scenario_name:** `credit_note_against_issued_invoice`
**invoice_type:** TAX (parent) + CREDIT_NOTE

### input_data

**Prerequisite:** an existing `invoices` row in state `SENT`:

```json
{
  "invoice_id": "01950000-0000-7000-0000-000000000041",
  "invoice_number": "INV-2026-0012",
  "status": "SENT",
  "total_gross_cents": 119000,
  "outstanding_balance_cents": 119000,
  "client_id": "01950000-0000-7000-0000-000000000004"
}
```

**Credit note request payload:**

```json
{
  "invoice_id": "01950000-0000-7000-0000-000000000041",
  "credit_amount_cents": 47600,
  "reason": "PARTIAL_SERVICE_NOT_DELIVERED",
  "issue_date": "2026-05-10"
}
```

### expected_output

```json
{
  "credit_note": {
    "credit_note_number_series": "CN",
    "credit_note_number_pattern": "CN-2026-NNNN",
    "status": "ISSUED",
    "amount_cents": 47600,
    "parent_invoice_id": "01950000-0000-7000-0000-000000000041"
  },
  "parent_invoice": {
    "invoice_id": "01950000-0000-7000-0000-000000000041",
    "outstanding_balance_cents": 71400,
    "status": "SENT"
  }
}
```

**Required audit events:**
1. `CREDIT_NOTE_CREATED`
2. `CREDIT_NOTE_NUMBER_ALLOCATED`
3. `CREDIT_NOTE_ISSUED`
4. `INVOICE_CREDITED`

**Invariants:**
- `credit_note.parent_invoice_id` references `INV-2026-0012`
- `parent_invoice.outstanding_balance_cents` decreases by exactly `credit_amount_cents` (119000 − 47600 = 71400)
- Parent invoice status remains `SENT`; it is NOT voided by a partial credit note
- `credit_amount_cents` may not exceed `parent_invoice.outstanding_balance_cents`; the `INVOICE_CREDIT_NOTE_CAP_REJECTED` event is emitted if the cap is breached (negative test)
- CN series counter increments monotonically; no gap

---

## Fixture 5 — Amendment flow (issued invoice)

**fixture_id:** `fix-in-005`
**scenario_name:** `amendment_flow_issued_invoice`
**invoice_type:** TAX (original) → VOID + CREDIT_NOTE + TAX (replacement DRAFT)

### input_data

**Prerequisite:** existing `SENT` invoice:

```json
{
  "invoice_id": "01950000-0000-7000-0000-000000000051",
  "invoice_number": "INV-2026-0020",
  "status": "SENT",
  "total_gross_cents": 238000,
  "outstanding_balance_cents": 238000,
  "client_id": "01950000-0000-7000-0000-000000000005"
}
```

**Amendment request payload:**

```json
{
  "invoice_id": "01950000-0000-7000-0000-000000000051",
  "amendment_reason": "INCORRECT_VAT_RATE",
  "replacement_line_items": [
    {
      "description": "IT consulting — April 2026 (corrected)",
      "quantity": 1,
      "unit_price_cents": 200000,
      "vat_treatment": "STANDARD",
      "vat_rate": 0.19
    }
  ]
}
```

### expected_output

```json
{
  "original_invoice": {
    "invoice_id": "01950000-0000-7000-0000-000000000051",
    "invoice_number": "INV-2026-0020",
    "status": "VOIDED",
    "void_reason": "AMENDED"
  },
  "credit_note": {
    "credit_note_number_series": "CN",
    "credit_note_number_pattern": "CN-2026-NNNN",
    "status": "ISSUED",
    "amount_cents": 238000,
    "parent_invoice_id": "01950000-0000-7000-0000-000000000051"
  },
  "replacement_invoice": {
    "invoice_number_series": "INV",
    "invoice_number_pattern": "INV-2026-NNNN",
    "status": "DRAFT",
    "total_gross_cents": 238000,
    "amendment_parent_id": "01950000-0000-7000-0000-000000000051"
  }
}
```

**Required audit events (in order):**
1. `INVOICE_AMENDED`
2. `INVOICE_VOIDED` (on original, `void_reason = AMENDED`)
3. `CREDIT_NOTE_CREATED`
4. `CREDIT_NOTE_NUMBER_ALLOCATED`
5. `CREDIT_NOTE_ISSUED`
6. `INVOICE_CREATED` (replacement draft)

**Sequence number invariants:**
- `INV-2026-0020` is voided; its counter value (0020) is retired and NOT reused by any future invoice
- The CN-series number is allocated at `CREDIT_NOTE_ISSUED` time, not at `CREDIT_NOTE_CREATED`
- The replacement draft receives no INV-series number until it transitions to `SENT`; the counter is not pre-allocated
- `INVOICE_SEQUENCE_GAP_DETECTED` must NOT be emitted for the gap at 0020 — the gap is explained by the void record and the `audit_invoice_number_gaps` scanner must recognise voided invoices as explained gaps

---

## Cross-references

- `in_workflow_live_integration_runbook.md` — test harness setup, teardown, and fixture loading procedures
- `invoice_lines_payload_schema.md` — canonical shape of `line_items` arrays (unit_price as integer minor units; vat_rate as decimal)
- `invoice_sequence_schema.md` — counter allocation mechanics, series definitions, UNIQUE constraints
- `credit_note_schema.md` — `credit_notes` table DDL, `parent_invoice_id` FK, cap enforcement
