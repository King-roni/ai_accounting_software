# Glossary

**Block:** Cross-cutting — Documentation  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This glossary defines the domain-specific terminology used throughout the Cyprus bookkeeping platform documentation. Terms are listed alphabetically. Each entry provides a definition and the relevant context in which the term appears. When a term has a precise technical meaning that differs from its everyday usage, the technical meaning takes precedence here.

---

## Terms

### Archive Bundle

A structured package produced at the end of a finalized run. It contains the run's ledger entries, supporting documents (PDFs, bank statements), audit log slice, hash chain proof, and manifest. Archive bundles are stored in the `archive` S3 bucket with Object Lock enabled. They are the durable, tamper-evident record of a completed accounting period. See `schemas/archive_bundle_construction_schema.md`.

### Approval Workflow

The structured sign-off process that a run must pass through before transitioning from AWAITING_APPROVAL to FINALIZING. An approval workflow may involve one or more approvers depending on the business's configuration. The workflow is tracked in `workflow_run_approvals`. A run cannot bypass the approval workflow; it is a required gate between accountant submission and finalization.

### Audit Log

The append-only, hash-chained table (`audit_log`) that records every significant event in the system. Each record carries: event type, actor, business context, entity reference, timestamp, and a SHA-256 hash linking to the previous record in the chain. The audit log is immutable after write. See also: Hash Chain.

### Carry-Forward

The mechanism by which unresolved issues from a previous period are surfaced in the subsequent period's run. A carry-forward issue retains its original `entity_id` and `issue_group` but receives a new `review_queue_issues` row with a reference to the carry-forward source. Carry-forward is governed by `review_queue_policy.md`.

### Chart of Accounts

The structured list of ledger accounts used by a business, organised into categories (Assets, Liabilities, Equity, Revenue, Expenses). The default chart of accounts for Cyprus VAT-registered businesses follows ICPAC conventions. Businesses may customise their chart of accounts within the constraints defined in `schemas/chart_of_accounts_schema.md`.

### Classification

The phase in which each transaction is assigned a ledger account code, VAT treatment, and direction (debit/credit). Classification is performed first by rule-based matching (Layer 1), then by AI inference (Layer 2) for transactions that rules do not cover. The output is a `classification_output` record. See `reference/in_monthly_phase_sequence.md` and `reference/out_monthly_phase_sequence.md`.

### Compensation

The rollback mechanism for failed workflow phases. When a run transitions to COMPENSATING status, the engine executes compensating actions in reverse phase order to undo partial writes. Not all phases are compensatable — FINALIZATION and APPROVAL are terminal. Compensation records are written to `compensation_log`. Compensation is triggered automatically when a phase failure is detected and the phase declares `compensatable: true` in its registration.

### Counterparty

The other party in a financial transaction: a vendor (for OUT transactions) or a client (for IN transactions). Counterparties are resolved from bank statement reference data, invoice issuer fields, and vendor memory. The resolved counterparty is stored in `counterparties` and linked to transactions. Unresolved counterparties (where no match can be found) are flagged as issues in the Review Queue.

### Credit Note

A document issued to cancel or reduce a previously issued invoice, partially or in full. In the ledger, credit notes reverse or partially reverse the original invoice's entries. Credit note allocation is tracked in `credit_note_allocations`. The application of a credit note to a payment is governed by `schemas/credit_note_allocation_schema.md`.

### Deduplication Fingerprint

A deterministic hash computed from key transaction fields (amount, date, reference, IBAN) used to detect duplicate bank statement rows during INTAKE. If two transactions produce the same fingerprint, the second is rejected with a `INTAKE_DUPLICATE_TRANSACTION` issue. The fingerprint is stored in `transactions.dedup_fingerprint`.

### ECB FX Rate

The exchange rate sourced from the European Central Bank's daily reference rate feed. Used for converting non-EUR transaction amounts to EUR for ledger posting. Rates are cached in `ecb_rates` with a 24-hour TTL. If a rate is unavailable for a transaction's currency/date, the run is held at REVIEW_HOLD. See `reference/ecb_fx_rate_cache_reference.md`.

### Finalization

The process of permanently closing a bookkeeping run and locking the associated accounting period. Finalization involves: passing all gates, obtaining approval, writing the archive bundle, applying Object Lock to stored documents, and setting the Period Lock. After finalization, no write operations are permitted against the run or period. The run transitions through AWAITING_APPROVAL -> FINALIZING -> FINALIZED.

### Gate

An engine-side predicate that must evaluate to true before a run can advance to the next phase. Gates are evaluated synchronously before each phase transition. If a gate fails, the run is held in the current phase and one or more BLOCKING issues are raised in the Review Queue. Gates are registered in `schemas/gate_function_library_schema.md`. Examples: the MATCHING gate checks that no PROPOSED matches remain; the FINALIZATION gate checks that no BLOCKING issues are open.

### Hash Chain

The tamper-evident mechanism applied to the audit log. Each audit log record includes a SHA-256 hash of its own content concatenated with the hash of the previous record. This creates an append-only chain: altering any historical record invalidates all subsequent hashes. The chain can be verified at any time using `archive.verify_hash_chain`. See `schemas/hash_chain_schema.md`.

### IN Workflow

The accounts-receivable processing pipeline. Handles income transactions, client invoices, and payments received. The IN workflow processes: bank credits, invoice matching, receipt-of-payment confirmation, and ledger posting on the revenue side. Monthly phase sequence is defined in `reference/in_monthly_phase_sequence.md`. The IN workflow runs are governed by `schemas/in_run_config_schema.md`.

### Intake

The first phase of a run. During INTAKE, raw bank statement rows are parsed, deduplicated, normalised to the internal transaction schema, and written to the `transactions` table. Intake also triggers OCR on any attached documents. See `tools/tool_intake_parse.md`.

### Issue

A problem detected during run processing that requires accountant review. Issues are stored in `review_queue_issues` and have a severity (INFO, WARNING, BLOCKING), an issue_group (from `issue_group_enum`), and a status (from `issue_status_enum`). BLOCKING issues prevent finalization. Issues are resolved, snoozed, or escalated by accountants via the Review Queue UI.

### Issue Group

One of five categories that describes the nature of a review issue: Missing Documents, Needs Confirmation, Possible Wrong Match, Possible Tax-VAT Issue, Unusual Transaction. Issue groups are defined in `reference/issue_group_enum.md`. Each issue type maps to exactly one issue group via the routing table in `reference/issue_type_to_group_mapping.md`.

### Ledger Entry

A single debit or credit record in the double-entry bookkeeping ledger. Every classified and confirmed transaction produces two or more ledger entries (debit and credit). Ledger entries are written during the LEDGER_POST phase and are immutable after the period is locked. See `schemas/ledger_entry_schema.md`.

### Match Level

The confidence tier assigned to a proposed transaction-invoice match. Four values are defined in `reference/match_level_enum.md`: EXACT (all signals align perfectly), STRONG_PROBABLE (most signals align, minor discrepancy), WEAK_POSSIBLE (partial signal alignment, requires review), NO_MATCH (no viable match found). EXACT and STRONG_PROBABLE matches may be auto-confirmed depending on business configuration. WEAK_POSSIBLE always requires accountant confirmation.

### Object Lock

S3 Write-Once-Read-Many (WORM) protection applied to archived financial documents after finalization. Object Lock prevents deletion or modification of stored files for the retention period (7 years for financial records). It is applied during the archive bundle construction step. See `schemas/archive_schema.md`.

### Operational Zone

The primary persistent data store for financial records. Data in the Operational Zone has a minimum 7-year retention period. It includes ledger entries, transactions, invoices, audit log, and run records. Contrast with Processing Zone (temporary, 7-day TTL) and Export-temp (download links, 24-hour TTL).

### OUT Workflow

The accounts-payable processing pipeline. Handles expense transactions, vendor invoices, and payments made. The OUT workflow processes: bank debits, vendor invoice matching, purchase confirmation, and ledger posting on the expense side. Monthly phase sequence is defined in `reference/out_monthly_phase_sequence.md`. The OUT workflow runs are governed by `schemas/out_run_config_schema.md`.

### Period Lock

A permanent write-lock applied to a VAT/accounting period after finalization. Once a period is locked, no ledger entries, transactions, or VAT entries for that period can be created, updated, or deleted. Any attempt returns `LEDGER_PERIOD_LOCKED`. The lock is recorded in `period_locks` and is enforced at the database level via a trigger. See `schemas/period_lock_schema.md`.

### Phase

A named stage within a run. Each phase has defined entry/exit gates, a set of tools that execute within it, and a run_status value. The eight phases are: INTAKE, CLASSIFICATION, MATCHING, LEDGER_POST, VAT_CALC, REVIEW, APPROVAL, FINALIZATION. Phases execute sequentially. A run cannot skip a phase. See `reference/in_monthly_phase_sequence.md` and `reference/out_monthly_phase_sequence.md`.

### Processing Zone

A temporary data store used for active run data during the processing phases. Data in the Processing Zone has a 7-day TTL. If a run does not complete within 7 days, the Processing Zone data expires and the run must be restarted from INTAKE. Contrast with Operational Zone (persistent) and Export-temp (24-hour download links).

### Pro Forma Invoice

A preliminary invoice issued before goods or services are delivered, used as a price quotation. Pro forma invoices are tracked separately from finalised invoices in `pro_forma_invoices` and do not generate ledger entries until converted to a finalised invoice. See `schemas/pro_forma_invoice_schema.md`.

### Reconciliation

The process of confirming that the closing bank balance on the statement matches the sum of all classified and posted transactions for the period. Reconciliation is a gate condition in the LEDGER_POST phase. A reconciliation failure results in a `Possible Tax-VAT Issue` severity WARNING or BLOCKING issue depending on the discrepancy amount.

### Run

A single bookkeeping processing cycle for a business for a specific period. A run processes all transactions for one calendar month (for IN and OUT monthly workflows) or one quarter. Each run has a unique `run_id`, is scoped to one `business_id`, and progresses through the phase sequence from INTAKE to FINALIZED. Runs are created via `engine.create_run` and tracked in `workflow_runs`.

### Run Status

The current state of a run within the processing lifecycle. Valid values are: CREATED, RUNNING, PAUSED, REVIEW_HOLD, AWAITING_APPROVAL, FINALIZING, FINALIZED, FAILED, CANCELLED, COMPENSATING. The value COMPLETED is never used — use FINALIZED. Transitions are governed by the engine phase logic. See `reference/workflow_state_enum.md`.

### Severity

The urgency classification of a review issue. Three levels are defined: INFO (informational, no action required), WARNING (should be reviewed, does not block finalization), BLOCKING (must be resolved before finalization is permitted). The value CRITICAL is not used in this system. See `reference/severity_enum.md`.

### Step-up MFA

An additional authentication challenge required before high-risk write operations. Triggered by tools that declare `requires_step_up: true` in their registration metadata. The user must complete a TOTP or hardware key challenge. A step-up token is issued on successful challenge and is valid for 15 minutes. See `schemas/step_up_token_schema.md` and `ui/step_up_ui_spec.md`.

### Transaction

A single financial movement recorded from a bank statement. In the `transactions` table, each row represents one bank statement line item after parsing, normalisation, and deduplication. Transactions are the primary input to the CLASSIFICATION and MATCHING phases. See `schemas/transaction_schema.md`.

### Vendor Memory

The per-business learned classification preferences for known vendors. When a transaction from a previously classified vendor is encountered, the vendor memory provides the preferred account code, VAT treatment, and direction. Vendor memory is stored in `vendor_memory` and updated after each confirmed classification. It reduces AI inference costs for repeat transactions. See `schemas/vendor_memory_schema.md` and `tools/tool_vendor_memory_update.md`.

### VAT Period

The accounting period for which VAT is calculated and reported. For Cyprus-registered businesses, VAT periods are typically quarterly. A VAT period is distinct from a general accounting period — the same calendar period may have both an accounting run and a VAT return run. VAT periods are tracked in `vat_periods`. See `schemas/vat_period_schema.md`.

### VIES

VAT Information Exchange System. The EU-wide system for reporting intra-community supplies of goods and services between VAT-registered businesses. Cyprus-registered businesses making B2B supplies to EU businesses must submit VIES reports. VIES reporting is handled by the VIES submission workflow. See `ui/vies_submission_ui_spec.md` and `reference/vies_record_format.md`.

---

## Related Documents

- `reference/issue_group_enum.md`
- `reference/issue_status_enum.md`
- `reference/severity_enum.md`
- `reference/match_level_enum.md`
- `reference/workflow_state_enum.md`
- `reference/audit_event_taxonomy.md`
- `schemas/workflow_run_schema.md`
- `schemas/vendor_memory_schema.md`
- `schemas/period_lock_schema.md`
- `schemas/hash_chain_schema.md`
