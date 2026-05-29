# Workflow Run Fixture Content

**Block:** engine  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This document defines three deterministic workflow run fixture scenarios for the engine test suite. Each scenario provides a complete set of rows across `workflow_runs`, `transactions`, `intake_files`, `ledger_entries` (where applicable), and `audit_log`. All amounts are in EUR. All UUIDs are v7 format. `business_id` is fixed at `018f4e2a-0000-7000-8000-000000000001` (Georgiou & Partners Ltd, VAT CY10099887L).

---

## Scenario A — REVIEW_HOLD (Dedup conflict + Unclassified transactions)

### Purpose

Validates that the review queue correctly surfaces a run stalled in REVIEW_HOLD due to a duplicate detection flag on one transaction and two unclassified transactions.

### workflow_runs row

```json
{
  "id": "018f6a00-0001-7000-8000-000000000001",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "run_code": "RUN-2026-0041",
  "period_start": "2026-01-01",
  "period_end": "2026-03-31",
  "run_status": "REVIEW_HOLD",
  "assignee_id": "018f0000-0000-7000-8000-000000000099",
  "created_at": "2026-05-10T08:00:00Z",
  "updated_at": "2026-05-14T11:23:00Z",
  "notes": null
}
```

### intake_files row

```json
{
  "id": "018f6a00-0010-7000-8000-000000000001",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "workflow_run_id": "018f6a00-0001-7000-8000-000000000001",
  "source_type": "BANK_FEED",
  "provider": "Nordigen",
  "file_name": "alpha_bank_2026_q1.ofx",
  "status": "PROCESSED",
  "uploaded_at": "2026-05-10T08:02:00Z",
  "processed_at": "2026-05-10T08:05:00Z",
  "row_count": 5,
  "error_message": null
}
```

### transactions (5 rows)

```json
[
  {
    "id": "018f6a00-0100-7000-8000-000000000001",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "workflow_run_id": "018f6a00-0001-7000-8000-000000000001",
    "transaction_date": "2026-01-08",
    "amount": -1250.00,
    "currency": "EUR",
    "description": "Α/Φ Παπαδόπουλος — Office supplies Jan",
    "classification_code": "6210",
    "classification_status": "CLASSIFIED",
    "dedup_status": "OK",
    "review_flag": null
  },
  {
    "id": "018f6a00-0100-7000-8000-000000000002",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "workflow_run_id": "018f6a00-0001-7000-8000-000000000001",
    "transaction_date": "2026-01-15",
    "amount": -3800.00,
    "currency": "EUR",
    "description": "Hermes Couriers Lefkosia — Shipping Q1",
    "classification_code": "6280",
    "classification_status": "CLASSIFIED",
    "dedup_status": "NEEDS_REVIEW",
    "review_flag": "Possible duplicate of txn 018f6a00-0100-7000-8000-000000000005"
  },
  {
    "id": "018f6a00-0100-7000-8000-000000000003",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "workflow_run_id": "018f6a00-0001-7000-8000-000000000001",
    "transaction_date": "2026-02-03",
    "amount": 18500.00,
    "currency": "EUR",
    "description": "SEPA CREDIT — Kyriakos Consulting Ltd",
    "classification_code": null,
    "classification_status": "UNCLASSIFIED",
    "dedup_status": "OK",
    "review_flag": "No matching rule or vendor"
  },
  {
    "id": "018f6a00-0100-7000-8000-000000000004",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "workflow_run_id": "018f6a00-0001-7000-8000-000000000001",
    "transaction_date": "2026-03-22",
    "amount": -540.00,
    "currency": "EUR",
    "description": "Aristo Developers Lefkosia — Office rent Mar",
    "classification_code": null,
    "classification_status": "UNCLASSIFIED",
    "dedup_status": "OK",
    "review_flag": "Vendor not in vendor master"
  },
  {
    "id": "018f6a00-0100-7000-8000-000000000005",
    "business_id": "018f4e2a-0000-7000-8000-000000000001",
    "workflow_run_id": "018f6a00-0001-7000-8000-000000000001",
    "transaction_date": "2026-01-15",
    "amount": -3800.00,
    "currency": "EUR",
    "description": "Hermes Couriers Lefkosia — Shipping Q1 (re-presented)",
    "classification_code": "6280",
    "classification_status": "CLASSIFIED",
    "dedup_status": "NEEDS_REVIEW",
    "review_flag": "Possible duplicate of txn 018f6a00-0100-7000-8000-000000000002"
  }
]
```

### Expected audit_log entries

| event_name | actor | resource_type | resource_id | occurred_at |
|---|---|---|---|---|
| `run.created` | system | workflow_run | 018f6a00-0001-… | 2026-05-10T08:00:00Z |
| `run.status_changed` | system | workflow_run | 018f6a00-0001-… | 2026-05-10T08:05:10Z |
| `intake.file_processed` | system | intake_file | 018f6a00-0010-… | 2026-05-10T08:05:00Z |
| `classification.tool_invoked` | system | workflow_run | 018f6a00-0001-… | 2026-05-10T08:06:00Z |
| `dedup.flag_raised` | system | transaction | 018f6a00-0100-…0002 | 2026-05-10T08:06:15Z |
| `dedup.flag_raised` | system | transaction | 018f6a00-0100-…0005 | 2026-05-10T08:06:15Z |
| `run.review_hold_entered` | system | workflow_run | 018f6a00-0001-… | 2026-05-14T11:23:00Z |

---

## Scenario B — AWAITING_APPROVAL (All classified, all matched, ready to finalize)

### Purpose

Validates the approval gate. All transactions are classified and matched; the run has passed the VAT calculation phase and is awaiting a senior accountant's approval before finalisation.

### workflow_runs row

```json
{
  "id": "018f6b00-0001-7000-8000-000000000002",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "run_code": "RUN-2026-0042",
  "period_start": "2026-01-01",
  "period_end": "2026-03-31",
  "run_status": "AWAITING_APPROVAL",
  "assignee_id": "018f0000-0000-7000-8000-000000000099",
  "created_at": "2026-05-11T09:00:00Z",
  "updated_at": "2026-05-15T16:40:00Z",
  "notes": "VAT return prepared. Awaiting Stavros approval."
}
```

### transactions (3 rows, all clean)

```json
[
  {
    "id": "018f6b00-0100-7000-8000-000000000001",
    "transaction_date": "2026-02-14",
    "amount": -2200.00,
    "currency": "EUR",
    "description": "Office supplies Lefkosia — stationery batch",
    "classification_code": "6210",
    "classification_status": "CLASSIFIED",
    "dedup_status": "OK",
    "matched_invoice_id": "018f6b00-0200-7000-8000-000000000001"
  },
  {
    "id": "018f6b00-0100-7000-8000-000000000002",
    "transaction_date": "2026-03-01",
    "amount": 45000.00,
    "currency": "EUR",
    "description": "SEPA CREDIT — Marcos Shipping Ltd",
    "classification_code": "7000",
    "classification_status": "CLASSIFIED",
    "dedup_status": "OK",
    "matched_invoice_id": "018f6b00-0200-7000-8000-000000000002"
  },
  {
    "id": "018f6b00-0100-7000-8000-000000000003",
    "transaction_date": "2026-03-18",
    "amount": -9500.00,
    "currency": "EUR",
    "description": "Νικολαΐδης & Υιοί ΕΠΕ — professional fees",
    "classification_code": "6400",
    "classification_status": "CLASSIFIED",
    "dedup_status": "OK",
    "matched_invoice_id": "018f6b00-0200-7000-8000-000000000003"
  }
]
```

### ledger_entries (summary, debit/credit pairs)

| entry_id | account_code | debit | credit | description |
|---|---|---|---|---|
| 018f6b00-0300-…0001 | 6210 | 2200.00 | — | Office supplies |
| 018f6b00-0300-…0002 | 2100 | — | 2200.00 | Accounts payable cleared |
| 018f6b00-0300-…0003 | 1200 | 45000.00 | — | Bank receipt |
| 018f6b00-0300-…0004 | 7000 | — | 45000.00 | Revenue recognised |
| 018f6b00-0300-…0005 | 6400 | 9500.00 | — | Professional fees |
| 018f6b00-0300-…0006 | 2100 | — | 9500.00 | Accounts payable cleared |

Trial balance check: total debits = total credits = **€56,700.00**.

### Expected audit_log entries

| event_name | actor | resource_type | occurred_at |
|---|---|---|---|
| `run.created` | system | workflow_run | 2026-05-11T09:00:00Z |
| `classification.tool_invoked` | system | workflow_run | 2026-05-11T09:03:00Z |
| `matching.tool_invoked` | system | workflow_run | 2026-05-11T09:04:00Z |
| `ledger.posted` | system | workflow_run | 2026-05-11T09:05:30Z |
| `vat_calc.tool_invoked` | system | workflow_run | 2026-05-11T09:06:00Z |
| `run.awaiting_approval_entered` | system | workflow_run | 2026-05-15T16:40:00Z |
| `notification.sent` | system | notification | 2026-05-15T16:40:05Z |

---

## Scenario C — FAILED (Ledger imbalance during gate check)

### Purpose

Validates that a ledger imbalance detected during the gate check transitions the run to FAILED and records the correct audit event with imbalance details.

### workflow_runs row

```json
{
  "id": "018f6c00-0001-7000-8000-000000000003",
  "business_id": "018f4e2a-0000-7000-8000-000000000001",
  "run_code": "RUN-2026-0043",
  "period_start": "2026-01-01",
  "period_end": "2026-03-31",
  "run_status": "FAILED",
  "assignee_id": "018f0000-0000-7000-8000-000000000099",
  "created_at": "2026-05-12T10:00:00Z",
  "updated_at": "2026-05-12T10:09:45Z",
  "notes": "FAILED: ledger gate — debit/credit imbalance of €420.00"
}
```

### transactions (4 rows)

```json
[
  {
    "id": "018f6c00-0100-7000-8000-000000000001",
    "transaction_date": "2026-01-20",
    "amount": -620.00,
    "description": "Α/Φ Χριστοδούλου — cleaning services Jan",
    "classification_code": "6290",
    "classification_status": "CLASSIFIED",
    "dedup_status": "OK"
  },
  {
    "id": "018f6c00-0100-7000-8000-000000000002",
    "transaction_date": "2026-02-10",
    "amount": 12000.00,
    "description": "SEPA CREDIT — Phivos Imports Ltd",
    "classification_code": "7000",
    "classification_status": "CLASSIFIED",
    "dedup_status": "OK"
  },
  {
    "id": "018f6c00-0100-7000-8000-000000000003",
    "transaction_date": "2026-03-05",
    "amount": -4200.00,
    "description": "Zenon IT Solutions Nicosia — IT support Q1",
    "classification_code": "6300",
    "classification_status": "CLASSIFIED",
    "dedup_status": "OK"
  },
  {
    "id": "018f6c00-0100-7000-8000-000000000004",
    "transaction_date": "2026-03-28",
    "amount": -880.00,
    "description": "Lefkosia Municipality — business licence",
    "classification_code": "6810",
    "classification_status": "CLASSIFIED",
    "dedup_status": "OK"
  }
]
```

### ledger_entries (imbalanced — intentional bug for fixture)

Total debits posted: **€5,700.00**. Total credits posted: **€5,280.00**. Imbalance: **€420.00** (the IT support credit entry was posted with wrong amount due to a simulated rounding error in the test harness).

### Expected audit_log entries

| event_name | actor | resource_type | occurred_at | payload excerpt |
|---|---|---|---|---|
| `run.created` | system | workflow_run | 2026-05-12T10:00:00Z | — |
| `classification.tool_invoked` | system | workflow_run | 2026-05-12T10:03:00Z | — |
| `ledger.posted` | system | workflow_run | 2026-05-12T10:07:00Z | — |
| `ledger.gate_check_failed` | system | workflow_run | 2026-05-12T10:09:45Z | `{"debit_total": 5700.00, "credit_total": 5280.00, "imbalance": 420.00}` |
| `run.status_changed` | system | workflow_run | 2026-05-12T10:09:45Z | `{"from": "RUNNING", "to": "FAILED"}` |
| `notification.sent` | system | notification | 2026-05-12T10:09:50Z | `{"type": "system_alert", "severity": "HIGH"}` |

---

## Related Documents

- `/sub/schemas/workflow_run_schema.md` — `workflow_runs` table and `run_status_enum`
- `/sub/schemas/transaction_schema.md` — `transactions` table
- `/sub/schemas/ledger_entry_schema.md` — `ledger_entries` table
- `/sub/schemas/audit_log_schema.md` — `audit_log` table and event taxonomy
- `/sub/fixtures/fixture_format_spec.md` — Fixture authoring standards
- `/sub/ui/run_detail_ui_spec.md` — How run state is displayed in the UI
