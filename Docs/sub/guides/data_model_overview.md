# Data Model Overview

**Block:** Platform / Data Layer
**Layer:** 2 — Sub-Doc
**Status:** Draft
**Cross-ref:** `data_layer_conventions_policy.md`, `tenancy_schema_definition.md`, `shared_schema_fragments.md`

---

## Overview

This guide describes the logical data model for the Cyprus bookkeeping SaaS platform. The model spans 16 functional blocks and approximately 80 tables across 8 broad groupings. The purpose of this document is to orient engineers to the groupings, the key relationships, and the conventions that apply uniformly across all tables before they read individual schema documents.

---

## Table Groupings

### 1. Tenancy Layer

The tenancy layer is the root of the data model. All other tables reference back to one of these tables.

**`business_entities`** — one row per business (tax entity). All application data is isolated per business via a `business_entity_id` FK present on every non-global table. This is the primary multi-tenancy boundary. RLS policies on all tenant-scoped tables evaluate `business_entity_id` against the caller's `org_members` membership.

**`org_members`** — maps users to businesses with a role assignment. A user may be a member of multiple businesses (e.g., an accountant serving multiple clients). The `role` column drives the permission system.

**`user_profiles`** — extended profile data for platform users. References `auth.users` (Supabase Auth). One row per user, not per business membership.

**`sessions`** — active authentication sessions. References `auth.users`. Tracks session lifetime, step-up token state, and MFA status per session.

### 2. Workflow Layer

The workflow layer tracks the execution state of bookkeeping runs.

**`workflow_runs`** — one row per bookkeeping run (monthly OUT, monthly IN, adjustment). Carries the `run_status_enum` value: CREATED, RUNNING, PAUSED, REVIEW_HOLD, AWAITING_APPROVAL, FINALIZING, FINALIZED, FAILED, CANCELLED, COMPENSATING. All phase progression is tracked here.

**`workflow_run_phases`** (embedded in `workflow_runs` or represented as phase state columns) — tracks which phase the run is currently in and the completion state of each phase. Phase gates are evaluated by `tool_finalization_gate_check.md` before phase advancement.

**`workflow_run_approvals`** — approval records for runs in AWAITING_APPROVAL status. One row per approval checkpoint per run.

**`gate_evaluation_log`** — append-only log of every gate evaluation result, pass or fail. Provides a debug trail for finalization issues.

### 3. Transaction Layer

The transaction layer holds the raw and processed financial data that the workflow engine operates on.

**`transactions`** — the canonical transaction table. One row per classified, deduplicated financial transaction for a business. The central entity that classification, matching, and ledger posting all write to or read from.

**`bank_statement_lines`** — raw lines extracted from imported bank statements before deduplication and transaction creation. References `bank_statement_raw`.

**`bank_statement_raw`** — raw uploaded bank statement files before line extraction.

**`dedup_result`** — deduplication result records keyed on `dedup_fingerprint`. Stores `dedup_status_enum`: NEW, DUPLICATE_EXACT, DUPLICATE_PROBABLE, NEEDS_REVIEW.

**`match_proposals`** — proposed matches between `bank_statement_lines` and expected income (`invoices`) or expense records. Each proposal carries a `match_level_enum` value: EXACT, STRONG_PROBABLE, WEAK_POSSIBLE, NO_MATCH. Confirmed proposals drive ledger posting.

### 4. Document Layer

The document layer stores intake artifacts and the extracted data derived from them.

**`intake_files`** — files uploaded via the intake pipeline (bank statements, invoices, receipts). Carries file metadata, zone classification, and processing status.

**`ocr_results`** — structured text extraction results from OCR processing of intake files. One row per intake file per OCR engine run. Carries the extracted JSON payload and confidence score.

**`document_line_items`** — structured line items extracted from invoices and receipts. Child rows of `ocr_results`.

### 5. Accounting Layer

The accounting layer holds the double-entry ledger and VAT compliance records.

**`ledger_entries`** — double-entry ledger rows. Every debit has a corresponding credit within the same transaction. The ledger is immutable; corrections are made by posting reversal and replacement entries. Rounding uses HALF_UP throughout.

**`ledger_account_chart`** — the chart of accounts for each business. Maps account codes to account types and reporting categories.

**`vat_categories`** — global lookup table of VAT category codes with rates and types. Seed data covers all Cyprus VAT treatments. Referenced by `ledger_entries`, `invoice_line_items`, and `classification_rules`.

**`vat_periods`** — VAT reporting periods for each business. One row per quarterly period. Carries period lock status.

**`vat_returns`** — assembled VAT return data per period. References `vat_periods`. Generated by the OUT monthly workflow's VAT phase.

**`vat_entries`** — individual VAT debit/credit rows feeding into the VAT return. Child of `ledger_entries`.

**`period_locks`** — lock records preventing modifications to ledger entries in a finalised period.

### 6. Invoice Layer

The invoice layer manages outbound and inbound invoicing.

**`invoices`** — tax invoices issued to clients. Carries `invoice_status`: DRAFT, SENT, PARTIALLY_PAID, PAID, OVERDUE, VOID.

**`invoice_line_items`** — individual line items on an invoice. Each line carries a `vat_category_code` FK to `vat_categories`.

**`invoice_payment_allocations`** — maps payments to invoices. Supports partial payment allocation.

**`credit_notes`** — credit note records issued against existing invoices.

**`recurring_invoices`** — recurring invoice schedules. Parent of recurring invoice run records.

**`pro_forma_invoices`** — pro-forma invoices generated before final confirmation.

### 7. Archive Layer

The archive layer stores immutable, integrity-verified copies of finalised run documents.

**`document_archives`** — archived document records. Immutable after promotion. Each row represents a document that has been promoted from the Processing zone to the Archive zone.

**`archive_manifests`** — manifest records for archive bundles. A bundle groups all documents for a completed run period.

**`hash_chain_entries`** — sequential hash chain records providing tamper-evidence for the archive. One row per archive event per business. Each entry's `chain_hash` depends on all preceding entries. See `schemas/hash_chain_entry_schema.md`.

**`archive_access_log`** — access records for every document retrieved from the archive zone. Created by `archive.restore_document`. Append-only.

### 8. Audit Layer

The audit layer provides the immutable, system-wide event record.

**`audit_logs`** — append-only, partitioned-by-month log of all significant platform events. Covers authentication, classification, matching, ledger posting, invoice lifecycle, archive operations, and all admin actions. Hash-chained per `audit_log_hash_chain`.

**`audit_log_hash_chain`** — per-business hash chain entries for the audit log. Parallel to `hash_chain_entries` in the archive layer but scoped to audit events rather than archive events.

---

## Key Relationships

The data model has a hub-and-spoke topology centred on `business_entities`. The key traversal paths are as follows.

**Tenancy to Workflow:** `business_entities` → `workflow_runs` (via `business_entity_id`). A business has many runs; each run belongs to exactly one business.

**Workflow to Transaction:** `workflow_runs` → `transactions` (via `run_id`). A run processes a set of transactions; each transaction is created within a single run context.

**Transaction to Ledger:** `transactions` → `ledger_entries` (via `transaction_id`). Classification and matching phases produce ledger entries. Each transaction may produce multiple ledger entry pairs (debit + credit).

**Invoice to Ledger:** `invoices` → `ledger_entries` (via `invoice_id`). Invoice creation triggers ledger entries in the income account.

**Bank Statement to Match Proposal:** `bank_statement_lines` → `match_proposals` → `invoices`. The income matching phase proposes and confirms matches between incoming bank lines and outstanding invoices.

**Ledger to VAT:** `ledger_entries` → `vat_entries` (via `ledger_entry_id`). VAT entries are child rows of ledger entries carrying the VAT component for VAT-applicable transactions.

**Ledger to VAT Return:** `vat_entries` → `vat_returns` (via `vat_period_id`). The VAT return assembly phase aggregates vat_entries into the quarterly return.

**Document to Archive:** `intake_files` → `document_archives` (via promotion event). When a run is finalised, intake documents are promoted to the archive zone.

**Archive to Hash Chain:** `document_archives` → `hash_chain_entries` (via `event_id` on `audit_logs`). Each archive event writes both an audit log row and a hash chain entry.

**Review Queue to Run:** `review_queue_items` → `workflow_runs` (via `run_id`). Queue items block or annotate runs. BLOCKING items hold the run in REVIEW_HOLD.

---

## FK Conventions

Every tenant-scoped table carries a `business_entity_id` column:

```sql
business_entity_id UUID NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT
```

The `ON DELETE RESTRICT` is standard across the model. Business entities are never deleted in production — they are deactivated. This prevents accidental data loss from cascading deletes.

Tables referencing other tenant-scoped tables carry both the direct FK and `business_entity_id`, allowing RLS policies to evaluate tenant membership on a single column without joins. The application enforces consistency between the denormalised `business_entity_id` and the parent row's `business_entity_id` via BEFORE INSERT triggers where needed (for example, `client_contacts.business_entity_id` must match `clients.business_id`).

All business-data PKs use `gen_uuid_v7()`. UUID v7 encodes a millisecond-precision timestamp in the high bits, producing time-ordered PKs that avoid random-access B-tree fragmentation at high insert rates.

---

## Temporal Design

All tables carry `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`. Tables that support mutation (all tables outside the append-only audit, archive, and hash chain tables) additionally carry `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`, maintained by a standard BEFORE UPDATE trigger.

Soft-delete is used in preference to hard-delete for client-visible entities: `clients`, `invoices`, `org_members`, and `intake_files` carry an `is_active` or `status` column. Hard-delete is restricted to session tokens and OAuth state rows, which carry no compliance-relevant history.

Effective-date bounded rows (for example, `vat_categories`) carry `effective_from` and `effective_to` (nullable) columns. Queries that must be point-in-time correct pass a reference date and filter with `effective_from <= $date AND (effective_to IS NULL OR effective_to > $date)`.

---

## Data Zone Classification

All tables fall into one of three data zones per `policies/data_layer_conventions_policy.md`:

| Zone | Tables | Properties |
|---|---|---|
| Processing | transactions, bank_statement_lines, ocr_results, match_proposals, ledger_entries | Mutable during active runs; locked after period finalization |
| Archive | document_archives, hash_chain_entries, archive_manifests | Immutable after promotion; integrity-verified |
| Permanent | audit_logs, audit_log_hash_chain | Append-only; never modified or deleted |

---

## Related Documents

- `policies/data_layer_conventions_policy.md` — PK convention, FK rules, zone classification, rounding
- `policies/multi_tenancy_isolation_policy.md` — Tenancy isolation guarantees and RLS strategy
- `policies/row_level_security_policies.md` — RLS policy templates and patterns
- `schemas/tenancy_schema_definition.md` — business_entities and org_members DDL
- `schemas/shared_schema_fragments.md` — Reusable column definitions and trigger templates
- `schemas/audit_log_schema.md` — Audit log DDL and hash chain mechanics
- `schemas/hash_chain_entry_schema.md` — Archive hash chain entries
- `schemas/workflow_run_schema.md` — Workflow runs table DDL
- `schemas/transactions_schema.md` — Transactions table DDL
- `schemas/ledger_entry_schema.md` — Ledger entries DDL
- `schemas/vat_category_schema.md` — VAT categories lookup table
- `reference/block_dependency_map.md` — Block dependency diagram
