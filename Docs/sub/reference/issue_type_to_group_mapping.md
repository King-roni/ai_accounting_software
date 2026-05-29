# Issue Type to Group Mapping

**Category:** Reference data · **Owning block:** 14 — Review Queue · **Co-owners:** 04, 06 · **Stage:** 4 sub-doc (Layer 1 reference)

The canonical map from `issue_type` (the producing block's specific identifier — e.g., `matching.weak_possible_match`) to `issue_group` (the queue bucket — one of the 5 actionable values from `issue_group_enum`). This sub-doc is the index; the per-producing-block sub-docs in Layer 2 enumerate each issue type's full payload schema.

Per the 2026-05-08 Block 14 fix, the canonical exhaustive table is assembled at runtime from each producing block's `registerIssueType` calls — the `issue_type_registry` table in Block 14 Phase 01 carries the live mapping. This sub-doc captures the contract and the Stage 1 inventory.

---

## Namespacing convention

```
<block_short_name>.<check_name>
```

- `block_short_name` per `tool_naming_convention_policy` (same allowlist)
- `check_name` snake_case noun describing the check

Examples: `matching.weak_possible_match`, `classification.rule_conflict`, `ledger.unresolved_counterparty`, `intake.ocr_low_confidence`.

The `issue_type_registry` table (Block 14 Phase 01) enforces uniqueness on `issue_type`. Adding a new issue type requires:
1. Producing block registers it via `registerIssueType({ issue_type, issue_group, default_severity, ... })`
2. The registration call is reachable from boot (boot-time fatal if duplicate)
3. This sub-doc gains the row (Stage 4 or later — kept loosely synchronized; the registry is the runtime authority)

## The Stage 1 inventory (canonical)

### Block 07 — Bank Statement Pipeline

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `intake.statement_partial_upload` | Unusual Transaction | HIGH |
| `intake.statement_duplicate_possible` | Possible Wrong Match | MEDIUM |
| `intake.statement_format_rejected` | Missing Documents | HIGH |
| `intake.evidence_pdf_generation_failed` | Missing Documents | MEDIUM |

### Block 08 — Transaction Classification

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `classification.unknown_type` | Needs Confirmation | **BLOCKING** (per Block 14 Phase 02) |
| `classification.rule_conflict` | Possible Wrong Match | HIGH |
| `classification.layer_3_low_confidence` | Needs Confirmation | MEDIUM |
| `classification.layer_2_vendor_memory_stale` | Needs Confirmation | LOW |

### Block 09 — Document Intake & Extraction

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `intake.ocr_low_confidence` | Needs Confirmation | MEDIUM |
| `intake.extraction_field_missing` | Needs Confirmation | MEDIUM |
| `intake.cross_source_duplicate_possible` | Possible Wrong Match | MEDIUM |
| `intake.document_format_rejected` | Missing Documents | HIGH |
| `intake.manual_upload_stub` | Missing Documents | HIGH |

### Block 10 — Matching Engine

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `matching.strong_probable_needs_confirmation` | Needs Confirmation | MEDIUM |
| `matching.weak_possible_match` | Possible Wrong Match | MEDIUM |
| `matching.no_match_out` | Missing Documents | HIGH |
| `matching.no_match_in` | Needs Confirmation | HIGH |
| `matching.split_payment_proposed` | Needs Confirmation | MEDIUM |
| `matching.duplicate_detected` | Possible Wrong Match | MEDIUM |

### Block 11 — Ledger & Cyprus VAT

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `ledger.unresolved_counterparty` | Possible Tax-VAT Issue | HIGH (BLOCKING if non-OUTSIDE_SCOPE) |
| `ledger.vat_treatment_unknown` | Possible Tax-VAT Issue | HIGH |
| `ledger.accountant_review_flagged` | Possible Tax-VAT Issue | HIGH |
| `ledger.vies_relevant_but_missing_vat_number` | Possible Tax-VAT Issue | HIGH |
| `ledger.evidence_threshold_breach` | Missing Documents | MEDIUM |

### Block 12 — OUT Workflow

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `out_workflow.manual_upload_reminder` | Missing Documents | LOW (entry-anchored cadence per `manual_upload_hold_reminder_consolidation_policy`) |
| `out_workflow.gate_hold_pending_approval` | Needs Confirmation | MEDIUM |
| `out_workflow.adjustment_concurrency_conflict` | Possible Wrong Match | HIGH |

### Block 13 — IN Workflow + Invoice Generator

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `in_workflow.multiple_invoices_one_payment` | Needs Confirmation | MEDIUM |
| `in_workflow.possible_refund_or_transfer` | Needs Confirmation | MEDIUM |
| `in_workflow.invoice_pdf_render_failed` | Unusual Transaction | HIGH |
| `in_workflow.invoice_pro_forma_expired` | Unusual Transaction | LOW |
| `in_workflow.invoice_recurring_template_generation_failed` | Unusual Transaction | HIGH |

### Block 14 — Review Queue (self-emitted)

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `review_queue.notification_dispatch_failed` | Unusual Transaction | LOW (notification fallback — Owner inbox, no email retry per Block 14 Phase 06) |
| `review_queue.bulk_action_partial_failure` | Unusual Transaction | MEDIUM |

### Block 15 — Finalization & Secure Archive

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `archive.finalization_precondition_failed` | Possible Tax-VAT Issue | BLOCKING |
| `archive.finalization_period_report_failed` | Unusual Transaction | HIGH |
| `archive.finalization_lock_sequence_failed` | Unusual Transaction | HIGH |
| `archive.tamper_detected` | Possible Wrong Match | BLOCKING (business-wide halt per Block 15 Phase 07) |

### Block 16 — Dashboard & Reporting

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `report.export_failed` | Unusual Transaction | HIGH |
| `report.accountant_pack_tampered` | Possible Wrong Match | BLOCKING |
| `report.dashboard_stale_data_threshold_exceeded` | Unusual Transaction | LOW |

### Block 06 — AI Layer (cross-cutting)

| issue_type | issue_group | default severity |
| --- | --- | --- |
| `ai.cost_ceiling_hit` | Unusual Transaction | HIGH |
| `ai.gateway_bypass_attempted` | Possible Wrong Match | BLOCKING |
| `ai.end_scan_finding` | (per `end_scan_policies` — the finding carries its own routing) | (per finding) |

End-Scan findings route per the producing block's issue_type — they're not their own routing category.

## Per-issue-group inventory (reverse map)

| Group | Issue type count | Producing blocks |
| --- | --- | --- |
| Missing Documents | 8 | 07, 09, 10, 11, 12 |
| Needs Confirmation | 11 | 08, 09, 10, 12, 13 |
| Possible Wrong Match | 7 | 06, 07, 08, 10, 15, 16 |
| Possible Tax-VAT Issue | 5 | 11, 15 |
| Unusual Transaction | 9 | 07, 13, 14, 15, 16 |

(Counts approximate — the runtime registry is authoritative.)

## Default severity overrides

Per-business severity overrides (`per_business_severity_override_policy`, deferred Stage 2+) can escalate a default-MEDIUM to HIGH for a given (issue_type, business_id). Defaults above are not de-escalated by per-business policy.

The `classification.unknown_type` BLOCKING default is non-overridable (per Block 14 Phase 02). Same for `archive.tamper_detected` BLOCKING.

## Cross-references

- `issue_group_enum` — the 5 actionable values + the Ready to Finalize projection
- `severity_enum` — severity values + dismissal eligibility
- `audit_event_taxonomy` — `REVIEW_ISSUE_CREATED` and related events
- `review_issues_schema` — `issue_type` + `issue_group` columns
- Block 14 Phase 01 — `issue_type_registry` table (runtime authority)
- Block 14 Phase 02 — issue groups, routing & severity (architecture)
- 2026-05-08 amendment — namespacing convention pinned
