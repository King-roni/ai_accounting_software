# Full Issue Type to Group Routing Table

**Category:** Reference data · **Owning block:** 14 — Review Queue · **Block reference:** BLOCK_14 · **Stage:** 4 sub-doc (Layer 2)

This document is the exhaustive mapping of every registered `issue_type` to its `issue_group`, `default_severity`, originating block, and auto-resolve eligibility. It is the human-readable counterpart to the `issue_type_registry` table. The table entries here must stay in sync with the `registerIssueType` calls in each block module; the lint job checks for drift at build time.

---

## Purpose

When the review queue loads, it routes each open issue into a filter bucket determined by `issue_group`. The routing table here documents that mapping explicitly so that accountants, operators, and developers can predict which filter bucket an issue lands in without querying the database. It also serves as the canonical reference for setting alert thresholds, SLA targets, and carry-forward escalation rules per group.

---

## Issue group definitions

| Group | Description |
| --- | --- |
| `DATA_QUALITY` | Issues where the underlying data record is incomplete, ambiguous, or structurally invalid. Typically sourced from parse or ingestion failures. |
| `CLASSIFICATION_REVIEW` | Issues where a transaction's type, category, or vendor assignment requires human confirmation or correction. |
| `DOCUMENT_REVIEW` | Issues where an attached document is unreadable, has low OCR confidence, or is a suspected duplicate. |
| `MATCHING_REVIEW` | Issues where a transaction-to-invoice match is ambiguous, unresolved, or split. |
| `TAX_REVIEW` | Issues where VAT treatment is uncertain, a VIES lookup failed, or a counterparty's intra-EU status cannot be determined. |
| `EXCEPTION_REVIEW` | Issues raised when an accountant has explicitly documented that a transaction will not be matched, or when an anomalous condition was accepted with a documented reason. |
| `WORKFLOW_HOLD` | Issues that represent an active manual hold placed on a transaction or run, preventing gate advancement until the hold is cleared. |
| `INVOICE_REVIEW` | Issues related to invoice lifecycle: stale drafts, required amendments, or skipped recurring generations. |

---

## Routing table

`AR` in the `Auto-Resolve` column means `auto_resolve_eligible = true`. Blank means `false`.

### Block 07 — Bank Statement Pipeline

| issue_type | issue_group | default_severity | registered_by_block | auto_resolve_eligible |
| --- | --- | --- | --- | --- |
| `STATEMENT_PARSE_ERROR` | `DATA_QUALITY` | HIGH | BLOCK_07 | |
| `STATEMENT_DUPLICATE_DETECTED` | `DATA_QUALITY` | MEDIUM | BLOCK_07 | |
| `STATEMENT_CURRENCY_UNSUPPORTED` | `DATA_QUALITY` | BLOCKING | BLOCK_07 | |

**`STATEMENT_PARSE_ERROR`** — Raised when the bank statement parser encounters a row it cannot normalise into a `transactions` record. The specific parse error is stored in the issue's `context_payload`. HIGH because parse failures may result in missing transactions for the period.

**`STATEMENT_DUPLICATE_DETECTED`** — Raised when `intake.check_dedup` identifies a probable duplicate upload (soft or hard) against an existing statement for the same period and account. MEDIUM because the duplicate may be intentional (e.g., amended statement). Not auto-resolve eligible: resolving requires an explicit accountant decision about which upload is authoritative.

**`STATEMENT_CURRENCY_UNSUPPORTED`** — Raised when the statement contains transactions in a currency outside the platform's FX-resolved set. BLOCKING because unsupported currencies cannot be normalised to EUR and block ledger preparation.

---

### Block 08 — Transaction Classification

| issue_type | issue_group | default_severity | registered_by_block | auto_resolve_eligible |
| --- | --- | --- | --- | --- |
| `CLASSIFICATION_CONFIDENCE_LOW` | `CLASSIFICATION_REVIEW` | MEDIUM | BLOCK_08 | AR |
| `CLASSIFICATION_CATEGORY_MISSING` | `CLASSIFICATION_REVIEW` | HIGH | BLOCK_08 | |
| `CLASSIFICATION_VENDOR_MEMORY_CONFLICT` | `CLASSIFICATION_REVIEW` | LOW | BLOCK_08 | |

**`CLASSIFICATION_CONFIDENCE_LOW`** — Raised when the classifier's aggregate confidence score for a transaction falls below the configured threshold after all three layers (rule-based, vendor memory, AI fallback) have run. Auto-resolve eligible: if a subsequent rescan raises confidence above threshold (e.g., because vendor memory was updated by another confirmed transaction), the issue resolves without human input.

**`CLASSIFICATION_CATEGORY_MISSING`** — Raised when no transaction type could be assigned at all — the classifier returned no match across all three layers. HIGH because a category-less transaction blocks ledger entry preparation.

**`CLASSIFICATION_VENDOR_MEMORY_CONFLICT`** — Raised when the vendor memory layer produces a suggestion that conflicts with a prior human-confirmed classification for the same vendor key. LOW because the conflict is informational; the human-confirmed classification takes precedence, but the accountant should be aware.

---

### Block 09 — Document Intake

| issue_type | issue_group | default_severity | registered_by_block | auto_resolve_eligible |
| --- | --- | --- | --- | --- |
| `DOCUMENT_OCR_CONFIDENCE_LOW` | `DOCUMENT_REVIEW` | MEDIUM | BLOCK_09 | AR |
| `DOCUMENT_UNREADABLE` | `DOCUMENT_REVIEW` | BLOCKING | BLOCK_09 | |
| `DOCUMENT_DUPLICATE_SUSPECTED` | `DOCUMENT_REVIEW` | LOW | BLOCK_09 | |

**`DOCUMENT_OCR_CONFIDENCE_LOW`** — Raised when the OCR pipeline's page-level confidence falls below threshold for one or more pages in the document. Auto-resolve eligible: if a manual re-upload or re-OCR pass yields confidence above threshold, the issue resolves on rescan.

**`DOCUMENT_UNREADABLE`** — Raised when OCR fails entirely (zero text extracted, or the pipeline returns a terminal failure status). BLOCKING because a completely unreadable document cannot be matched or included in ledger preparation.

**`DOCUMENT_DUPLICATE_SUSPECTED`** — Raised by `intake.check_cross_source_dedup` when the document's `content_hash` matches an existing `documents` row from a different source (e.g., email vs. manual upload). LOW because suspected duplicates are usually benign; the accountant confirms which copy to keep.

---

### Block 10 — Matching Engine

| issue_type | issue_group | default_severity | registered_by_block | auto_resolve_eligible |
| --- | --- | --- | --- | --- |
| `MATCH_PROBABLE_UNCONFIRMED` | `MATCHING_REVIEW` | MEDIUM | BLOCK_10 | AR |
| `MATCH_SPLIT_PAYMENT_UNRESOLVED` | `MATCHING_REVIEW` | HIGH | BLOCK_10 | |
| `MATCH_NO_CANDIDATE` | `MATCHING_REVIEW` | HIGH | BLOCK_10 | |

**`MATCH_PROBABLE_UNCONFIRMED`** — Raised when the matching engine scores a transaction-invoice pair above the probable-match threshold but below the auto-confirm threshold. Auto-resolve eligible: if the accountant confirms a related match in the same run (e.g., confirms the invoice for another split-payment line), the rescan may auto-confirm this pair.

**`MATCH_SPLIT_PAYMENT_UNRESOLVED`** — Raised when a split-payment group is proposed but at least one member transaction lacks a confirmed match. HIGH because unresolved splits block ledger entry preparation for the affected invoice.

**`MATCH_NO_CANDIDATE`** — Raised when no invoice candidate with a score above the minimum threshold can be found for a transaction. HIGH because a transaction with no candidate cannot be matched and requires explicit exception documentation or manual invoice linking.

---

### Block 11 — Ledger & Cyprus VAT

| issue_type | issue_group | default_severity | registered_by_block | auto_resolve_eligible |
| --- | --- | --- | --- | --- |
| `VAT_TREATMENT_UNCERTAIN` | `TAX_REVIEW` | HIGH | BLOCK_11 | |
| `COUNTERPARTY_UNRESOLVABLE` | `DATA_QUALITY` | MEDIUM | BLOCK_11 | |
| `VIES_VALIDATION_FAILED` | `TAX_REVIEW` | BLOCKING | BLOCK_11 | |

**`VAT_TREATMENT_UNCERTAIN`** — Raised by `ledger.decide_vat_treatment` when the VAT treatment decision tree cannot produce a confident outcome (e.g., the counterparty's country is indeterminate, or the transaction type is on the ambiguous boundary between standard-rated and exempt). HIGH because uncertain VAT treatment blocks the ledger entry write.

**`COUNTERPARTY_UNRESOLVABLE`** — Raised when `ledger.resolve_counterparty` cannot match the raw payee string to a `counterparties` row and cannot create one (e.g., insufficient fields). MEDIUM because unresolvable counterparties degrade reporting quality but do not necessarily block gate advancement if a fallback treatment is available.

**`VIES_VALIDATION_FAILED`** — Raised when `ledger.validate_vies` attempts a VIES lookup for an intra-EU counterparty and all attempts fail (network errors, invalid VAT number format, or the VIES service returns a negative validation result). BLOCKING because `EU_REVERSE_CHARGE` treatment cannot be applied without a valid VIES result, and applying it without validation would constitute a regulatory error.

---

### Block 12 — OUT Workflow

| issue_type | issue_group | default_severity | registered_by_block | auto_resolve_eligible |
| --- | --- | --- | --- | --- |
| `TRANSACTION_EXCEPTION_DOCUMENTED` | `EXCEPTION_REVIEW` | LOW | BLOCK_12 | |
| `OUT_MANUAL_HOLD_ACTIVE` | `WORKFLOW_HOLD` | MEDIUM | BLOCK_12 | |

**`TRANSACTION_EXCEPTION_DOCUMENTED`** — Raised when an accountant invokes `out_workflow.document_exception` to formally record that a transaction will not be matched. LOW because the accountant has already reviewed and accepted the situation; the issue serves as an audit trail marker rather than a pending action item. See `out_exception_documented_policy` for full semantics.

**`OUT_MANUAL_HOLD_ACTIVE`** — Raised when an accountant places a manual hold on a transaction or on the run itself via `out_workflow.place_hold`. MEDIUM because an active hold prevents `engine.gate_matching_complete` from passing. The issue resolves when the hold is lifted.

---

### Block 13 — IN Workflow + Invoice Generator

| issue_type | issue_group | default_severity | registered_by_block | auto_resolve_eligible |
| --- | --- | --- | --- | --- |
| `INVOICE_DRAFT_STALE` | `INVOICE_REVIEW` | LOW | BLOCK_13 | |
| `INVOICE_AMENDMENT_REQUIRED` | `INVOICE_REVIEW` | HIGH | BLOCK_13 | |
| `RECURRING_INVOICE_SKIPPED` | `INVOICE_REVIEW` | LOW | BLOCK_13 | |

**`INVOICE_DRAFT_STALE`** — Raised when an `invoices` row with `status = DRAFT` has not been modified for more than 14 days within an active run. LOW because the draft is not yet affecting any downstream process; the issue prompts the accountant to either issue or discard the draft.

**`INVOICE_AMENDMENT_REQUIRED`** — Raised when an issued invoice requires correction (e.g., a matching transaction with a different amount was subsequently confirmed, or a client data change invalidates the invoice). HIGH because the amendment workflow (credit note + new invoice) must complete before the period can finalise.

**`RECURRING_INVOICE_SKIPPED`** — Raised by `in_workflow.generate_recurring` when a recurring invoice template's scheduled generation was intentionally suppressed (e.g., via a skip flag) or skipped due to a configuration gap. LOW because a single skipped generation is typically expected but should be visible for review.

---

## Routing guarantees

1. Every `issue_type` in this table has a corresponding `registerIssueType` call in its originating block module.
2. The `issue_group` value in this table must match the value in `issue_type_registry.issue_group` at runtime. The build lint job compares this file against a fixture dump of the registry.
3. `default_severity` values in this table must match `issue_type_registry.default_severity`. Severity can be overridden at the per-issue level at raise time; this table shows the default.
4. No `issue_type` appears in more than one row. Issue types are globally unique across all blocks.

---

## Cross-references

- `issue_type_registry_schema.md` — DDL, `registerIssueType` mechanism, boot validation
- `issue_group_enum.md` — defines the closed set of valid `issue_group` values
- `issue_group_routing_policy.md` — per-group filter, SLA, and carry-forward rules
- `out_exception_documented_policy.md` — `TRANSACTION_EXCEPTION_DOCUMENTED` semantics
- `snooze_carry_forward_policy.md` — snooze and carry-forward rules per severity tier
- `review_queue_rescan_on_resolution_policy.md` — rescan triggers per `issue_type`
