# Stage 4 Layer 2 Scan 4 — Consistency Findings

**Scan date:** 2026-05-16  
**Corpus:** 353 sub-documents in Docs/sub/  
**Total findings:** 36  

---

## Summary by severity

| Severity | Count |
|---|---|
| BLOCKING | 0 |
| HIGH | 18 |
| MEDIUM | 18 |
| LOW | 0 |
| **Total** | **36** |

---

## BLOCKING — LINE_COUNT

**No files under 140 lines.** The smallest file in the corpus is 140 lines (several files tie at exactly 140). The BLOCKING threshold is strict "under 140", so no violations exist.

---

## HIGH — DUPLICATE_DDL (8 findings)

### `transactions` table — conflicting dual definition

**Files:**  
- `Docs/sub/schemas/transactions_schema.md` line 52  
- `Docs/sub/schemas/transaction_schema.md` line 23  

**Conflict:** Every major column differs. PK name (`transaction_id` vs `id`), FK target (`businesses(id)` vs `business_entities(id)`), amount type (bigint vs NUMERIC), counterparty storage (encrypted bytea vs plain text), and the dedup_status_enum values are entirely different sets.

---

### `chart_of_accounts` table — conflicting dual definition

**Files:**  
- `Docs/sub/schemas/ledger_account_chart_schema.md` line 27  
- `Docs/sub/schemas/chart_of_accounts_schema.md` line 35  

**Conflict:** chart_of_accounts_schema.md has extra columns (chart_mapping_version_id, normal_side, deductibility, vat_treatment_hint, vies_eligible, retired_at, retired_reason) and uses `REFERENCES businesses(id)` while ledger_account_chart_schema.md uses `REFERENCES business_entities(id)`.

---

### `account_type_enum` — conflicting 6th value

**Files:**  
- `Docs/sub/schemas/ledger_account_chart_schema.md` line 12 → `VAT_CONTROL`  
- `Docs/sub/schemas/chart_of_accounts_schema.md` line 68 → `OFF_BALANCE`  

**Conflict:** The first five values (ASSET, LIABILITY, EQUITY, REVENUE, EXPENSE) are identical; the sixth value is a direct conflict.

---

### `dedup_status_enum` — conflicting value sets

**Files:**  
- `Docs/sub/schemas/transactions_schema.md` line 22 → `(NEW, DUPLICATE_EXACT, DUPLICATE_POSSIBLE, NEEDS_REVIEW)`  
- `Docs/sub/schemas/transaction_schema.md` line 85 → `(UNIQUE, DUPLICATE_POSSIBLE, DUPLICATE_CONFIRMED, EXCEPTION_DOCUMENTED)`  

**Conflict:** Only `DUPLICATE_POSSIBLE` is shared; three of four values differ in each definition.

---

### `classification_rules` table — conflicting dual definition

**Files:**  
- `Docs/sub/schemas/classification_rule_schema.md` line 25  
- `Docs/sub/schemas/classification_rule_predicate_schema.md` line 21  

**Conflict:** PK column (`id` vs `rule_id`), FK target (`business_entities` vs `businesses`), operational columns entirely different (target_category/confidence_override/rule_name/version vs rule_kind/result_transaction_type/created_by_user_id).

---

### `invoice_sequences` table — conflicting DDL

**Files:**  
- `Docs/sub/schemas/invoice_sequence_schema.md` line 18  
- `Docs/sub/policies/invoice_numbering_sequence_policy.md` line 52  

**Conflict:** PK column name (`sequence_id` vs `id`); series column type (`invoice_series_enum` vs plain `text`); CHECK constraints and timestamp columns present in schema file but absent in policy file.

---

## HIGH — ENUM_DRIFT (2 findings)

### match_level using old values HIGH/MEDIUM/LOW

The canonical `match_level_enum` is `(EXACT, STRONG_PROBABLE, WEAK_POSSIBLE, NO_MATCH)` per `match_record_schema.md` and `match_level_enum.md`. Two files use the old pre-rename values:

1. **`Docs/sub/policies/match_scoring_weights_policy.md` line 90** — claims "EXACT, HIGH, MEDIUM, LOW values are canonical". Also at lines 85–88 and 130.  
   Fix: HIGH → STRONG_PROBABLE, MEDIUM → WEAK_POSSIBLE, LOW → NO_MATCH.

2. **`Docs/sub/schemas/income_matching_schema.md` line 42** — states `match_level_enum (EXACT | HIGH | MEDIUM | LOW)`. Also at lines 52, 71, 74, 142.  
   Fix: same substitution throughout.

---

## HIGH — AUDIT_EVENT_ORPHAN (8 findings)

Events referenced as emitted in production code paths but absent from `audit_event_taxonomy.md`:

| Event | File | Line | Note |
|---|---|---|---|
| `BANK_UPLOAD_COMPLETED` | bank_statement_live_integration_runbook.md | 40, 96, 143 | Even cited as being in the taxonomy (line 143) — it is not. Nearest alternative: `BANK_UPLOAD_PARSE_COMPLETED`. |
| `LIVE_TEST_FAILED` | bank_statement_live_integration_runbook.md | 125 | Also used in classification, document_intake, matching, and ledger runbooks. Taxonomy has LIVE_TEST_RUN_COMPLETED but not FAILED. |
| `AUTH_SESSION_REFRESHED` | tool_session_refresh.md | 61 | Taxonomy has `SESSION_REFRESHED` (under TENANCY/LOGIN) but not the AUTH_ prefixed variant. |
| `AUTH_SESSION_REFRESH_FAILED` | tool_session_refresh.md | 83 | Not registered in any domain. |
| `AUTH_SESSION_REFRESH_RATE_LIMITED` | tool_session_refresh.md | 108 | Not registered in any domain. |
| `AUTH_SESSION_DEVICE_MISMATCH` | tool_session_refresh.md | 69 | Not registered in any domain. |
| `CLASSIFICATION_MANUAL_OVERRIDE_SET` | tag_conflict_resolution_policy.md | 38 | CLASSIFICATION domain exists but this event is absent. |
| `MATCHING_SCORING_CONFIG_INVALID` | match_signal_evidence_schema.md | 129 | MATCHING domain has MATCHING_SCORING_CONFIG_UPDATED but not INVALID. |
| `VIES_VALIDATION_SYSTEM_ERROR` | vies_record_format.md | 148 | VIES domain has VIES_LOOKUP_FAILED but not this system-error variant. |
| `WORKFLOW_MANUAL_UPLOAD_REMINDER_SENT` | side_phase_routing_policy.md | 152 | Not in WORKFLOW or OUT_WORKFLOW domain. |
| `CHART_MAPPING_VERSION_FROZEN` | ledger_account_mapping_schema.md | 175 | LEDGER domain has CHART_MAPPING_VERSION_CREATED but not FROZEN. |

(Note: findings 11–18 cover 8 unique event groups; AUTH_SESSION events counted as one finding.)

---

## MEDIUM — ENUM_DRIFT: ISSUED used for invoice status (3 findings)

`ISSUED` is valid only for `credit_note_status_enum`. The `invoice_status_enum` uses `SENT` as the post-DRAFT state. Three files incorrectly use `ISSUED` as an invoice status:

1. **`Docs/sub/ui/invoice_lifecycle_ui_spec.md` line 14** — entire lifecycle diagram shows DRAFT → ISSUED → PAID. Lines 25, 26, 28, 77 also affected.
2. **`Docs/sub/ui/drill_down_list_detail_ui_spec.md` line 67** — badge table lists `ISSUED (blue)` for `invoices.status`.
3. **`Docs/sub/runbooks/in_workflow_live_integration_runbook.md` line 28** — fixture assertions use ISSUED for tax invoice status throughout.

Fix for all three: replace `ISSUED` with `SENT` for tax invoice and pro-forma invoice status references. Retain `ISSUED` where it refers to credit note status (credit_note_status_enum correctly uses ISSUED).

---

## MEDIUM — MOBILE_WRITE_MISSING (4 findings)

The following tool files declare `WRITES_AUDIT` in `side_effect_class` but contain no section noting mobile client rejection, as required by `mobile_write_rejection_endpoints.md`:

| File | Line | Side-effect declared |
|---|---|---|
| `Docs/sub/tools/tool_period_report_generator.md` | 54 | `READ_ONLY \| WRITES_AUDIT` |
| `Docs/sub/tools/tool_can_perform_helper.md` | 15 | `READ_ONLY \| WRITES_AUDIT` |
| `Docs/sub/tools/tool_classification_vendor_memory_apply.md` | 44 | `READ_ONLY \| WRITES_AUDIT` |
| `Docs/sub/tools/tool_gateway_invoke_ai.md` | 15 | `EXTERNAL_CALL \| WRITES_AUDIT` |

All four are internal pipeline tools (not user-callable endpoints). The fix for each is to add a Mobile Rejection section explaining that mobile rejection is enforced at the caller/gateway layer and this tool has no independent mobile exposure. Cross-reference `mobile_write_rejection_endpoints.md`.

Compare: `tool_hash_chain_append.md` (also `WRITES_AUDIT`) correctly includes: "Mobile write rejection is enforced at the `security.emit_audit` layer" (line 166) — these four files need equivalent notes.

---

## MEDIUM — FK_TARGET: businesses(id) instead of business_entities(id) (systematic, 43 instances across 40 files)

Every schema file using `REFERENCES businesses(id)` is in violation. The canonical FK target is `REFERENCES business_entities(id)`.

**Affected files (40 total):**

| File | Line |
|---|---|
| schemas/workflow_run_schema.md | 46 |
| schemas/invoice_schema.md | 35 |
| schemas/transactions_schema.md | 54 |
| schemas/match_record_schema.md | 33 |
| schemas/credit_note_schema.md | 20 |
| schemas/ledger_entry_schema.md | 14 |
| schemas/review_issues_schema.md | 31 |
| schemas/bank_upload_schema.md | 14 |
| schemas/adjustment_record_schema.md | 39 |
| schemas/ai_gateway_schema.md | 26 |
| schemas/ai_usage_records_schema.md | 27 |
| schemas/bank_statement_rows_schema.md | 23 |
| schemas/bank_upload_status_transitions_schema.md | 31 |
| schemas/chart_of_accounts_schema.md | 18, 37 |
| schemas/classification_output_schema.md | 18 |
| schemas/classification_rule_predicate_schema.md | 23 |
| schemas/client_multi_name_alias_schema.md | 64, 110 |
| schemas/client_schema.md | 14 |
| schemas/counterparty_resolver_tracing_schema.md | 54 |
| schemas/counterparty_schema.md | 14 |
| schemas/document_source_schema.md | 21 |
| schemas/end_scan_schema.md | 21 |
| schemas/evidence_pdf_schema.md | 21 |
| schemas/income_matching_schema.md | 16 |
| schemas/invoice_line_item_schema.md | 17 |
| schemas/invoice_payment_allocations_schema.md | 26 |
| schemas/ledger_account_mapping_schema.md | 21 |
| schemas/match_signal_evidence_schema.md | 18 |
| schemas/oauth_token_encryption_schema.md | 16 |
| schemas/out_config_schema.md | 14 |
| schemas/recurring_invoice_run_schema.md | 26 |
| schemas/rejection_memory_schema.md | 14 |
| schemas/split_payment_relationship_schema.md | 29 |
| schemas/tag_taxonomy_version_schema.md | 14, 76 |
| schemas/trigger_events_processed_schema.md | 25 |
| schemas/vat_entry_schema.md | 14 |
| schemas/vendor_memory_schema.md | 14 |
| schemas/vies_record_schema.md | 14 |
| policies/step_up_validity_window_policy.md | 35 |
| integrations/transactional_email_service_integration.md | 85 |

---

## MEDIUM — FORWARD_REF_STALE (3 findings)

Three forward references point to documents that still do not exist in the corpus:

1. **`Docs/sub/policies/match_scoring_weights_policy.md` lines 21, 96** — `match_scoring_config` table schema, described as "deferred — forward reference to Block 10 Phase 02 sub-doc". No `match_scoring_config` schema file exists.

2. **`Docs/sub/schemas/vendor_memory_schema.md` line 65** — `vendor_memory_conflicts` table, described as "forward reference, Block 08 Phase 03". No such schema file exists.

3. **`Docs/sub/schemas/accountant_pack_manifest_schema.md` lines 7, 146, 198** — `accountant_pack_tamper_runbook`, described as "deferred Layer 2 forward reference". No such runbook file exists.

---

## Checks with no findings

| Check | Result |
|---|---|
| LINE_COUNT | No files under 140 lines |
| GATE_NAMING | No gate.out.*, gate.in.*, gate.finalization.* found |
| DATA_ZONE_DRIFT | All export-temp TTL references correctly state 24 hours |
| UUID_PATTERN | All gen_random_uuid() uses are within allowed exception categories |
| TOOL_NAMESPACE | All tool namespaces are within the 14 allowed namespaces |

---

## Recommended fix priority

1. **Immediate (gate-blocking):** DUPLICATE_DDL on `transactions` and `account_type_enum` — these affect runtime migration and type safety for the most critical tables.  
2. **Before next scan:** All AUDIT_EVENT_ORPHAN events need taxonomy registration — `LIVE_TEST_FAILED` affects 5 runbooks; AUTH_SESSION events affect the session refresh tool.  
3. **Batch fix:** FK_TARGET violations are mechanical find-replace across 40 files.  
4. **Documentation pass:** ENUM_DRIFT on match_level and ISSUED/SENT, plus the 4 MOBILE_WRITE_MISSING tool files.
