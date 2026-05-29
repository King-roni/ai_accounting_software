# Stage 4 Layer 2 — Scan 3 Findings Summary

**Scan date:** 2026-05-15
**Corpus size:** 293 files
**Total findings:** 16 (9 HIGH · 6 MEDIUM · 1 LOW · 0 BLOCKING)

---

## Finding counts by check type

| Check | HIGH | MEDIUM | LOW | Total |
|---|---|---|---|---|
| DUPLICATE_DDL | 7 | 0 | 0 | 7 |
| AUDIT_EVENT_ORPHAN | 1 | 0 | 1 | 2 |
| DATA_ZONE_DRIFT | 0 | 3 | 0 | 3 |
| INVOICE_SERIES | 0 | 1 | 0 | 1 |
| FORWARD_REF_STALE | 0 | 1 | 0 | 1 |
| MOBILE_WRITE_MISSING | 0 | 1 | 0 | 1 |
| ENUM_DRIFT | 0 | 0 | 0 | 0 |
| TOOL_NAMESPACE | 0 | 0 | 0 | 0 |
| GATE_NAMING | 0 | 0 | 0 | 0 |
| UUID_MISMATCH | 0 | 0 | 0 | 0 |
| SEVERITY_DRIFT | 0 | 0 | 0 | 0 |
| LINE_COUNT | 0 | 0 | 0 | 0 |

---

## Checks that passed clean

- **ENUM_DRIFT** — No file uses COMPLETED as a `workflow_runs.status` terminal state. `run_status_enum` is 10 values as amended. No CRITICAL severity references anywhere in the corpus.
- **TOOL_NAMESPACE** — All 12 registered tool namespaces are in the allowlist. All tool names follow `<namespace>.<action>` snake_case two-part pattern.
- **GATE_NAMING** — All gate functions in `gate_function_library_schema.md` and referencing files use `engine.gate_<phase_descriptor>`. No `gate.out.*`, `gate.in.*`, or `gate.finalization.*` patterns found.
- **UUID_MISMATCH** — All `gen_random_uuid()` usages are in the allowed exception list (session IDs, password reset tokens, invitation tokens, OAuth state IDs, step-up MFA tokens, bulk preview tokens). All other IDs use `gen_uuid_v7()`.
- **SEVERITY_DRIFT** — CRITICAL does not appear as a severity value in any sub-doc.
- **LINE_COUNT** — All 293 files meet the 140-line minimum.

---

## DUPLICATE_DDL findings (7 HIGH)

These are the most impactful findings of this scan. Seven tables/types have conflicting DDL definitions across multiple files.

**Finding #1 (HIGH) — `match_level_enum` in `match_record_schema.md`**
The enum body defines `EXACT, HIGH, MEDIUM, LOW` but the canonical reference (`match_level_enum.md`) defines `EXACT, STRONG_PROBABLE, WEAK_POSSIBLE, NO_MATCH`. All scoring code, calibration policy, and signal weights use the canonical form. The stale values in `match_record_schema.md` line 12 would cause broken auto-confirm logic if implemented.

**Finding #2 (HIGH) — `issue_type_registry` table in `review_issue_card_schema.md`**
Defines different column names from the canonical `issue_type_registry_schema.md` (issue_type_registry_id vs id, block_short_name vs registered_by_block, allowed_resolution_actions and description present in card schema but absent from canonical, auto_resolve_eligible and deprecated_at present in canonical but absent from card schema).

**Finding #3 (HIGH) — `workflow_run_approvals` table in `workflow_approval_schema.md`**
Uses a staleness/revocation model (is_stale, stale_reason, revoked_by_user_id, revoked_at) that predates the canonical lifecycle model in `workflow_run_approvals_schema.md` (approval_type, status enum PENDING/APPROVED/REJECTED/EXPIRED, expires_at generated column).

**Finding #4 (HIGH) — `invoice_sequences` table across two files**
`invoice_sequence_schema.md` uses `sequence_id` PK, `REFERENCES businesses(id)`, `invoice_series_enum` type, `last_sequence_number DEFAULT 0`. `invoice_numbering_sequence_policy.md` uses `id` PK, `REFERENCES business_entities(id)`, `series text`, `next_counter DEFAULT 1`. Starting value 0 vs 1 is a semantic difference that affects allocation logic.

**Finding #5 (HIGH) — `oauth_tokens` table across two files**
`oauth_token_encryption_schema.md` has additional columns (account_email, refresh_token_expires_at, provider_account_id, provider_metadata) vs `gmail_oauth_integration.md` which has IV columns (access_token_iv, refresh_token_iv) and uses different encrypted column names (access_token_enc vs access_token_encrypted).

**Finding #6 (HIGH) — `users` table across two files**
`tenancy_schema_definition.md` has mfa_enabled, auth_user_id, deleted_at. `user_schema.md` (canonical) has email_verified, email_verified_at, avatar_url, is_active. The sets are disjoint on these key columns.

**Finding #7 (HIGH) — `business_entities` table across two files**
`tenancy_schema_definition.md` has accounting_method, vat_registered, vat_period_type, status, base_currency, country. `business_schema.md` (canonical) has display_name NOT NULL, is_active, timezone, fiscal_year_start_month, country_code, currency, created_by_user_id. Column names conflict (country vs country_code, base_currency vs currency).

---

## AUDIT_EVENT_ORPHAN findings (1 HIGH + 1 LOW)

**Finding #8 (HIGH) — `OUT_WORKFLOW_MANUAL_HOLD_APPLIED` / `OUT_WORKFLOW_MANUAL_HOLD_RELEASED`**
Both events are cited in `out_workflow_live_integration_runbook.md` (lines 98, 100, 132, 164) as required audit-log assertions for the live integration test. Neither exists in `audit_event_taxonomy.md`. The OUT_WORKFLOW domain entry in the taxonomy has no MANUAL_HOLD events.

**Finding #9 (HIGH) — `LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED`**
Referenced three times in `counterparty_resolver_tracing_schema.md` (lines 5, 134, 249) as an event the counterparty resolver emits at the resolution boundary. Absent from the LEDGER domain in `audit_event_taxonomy.md`. The taxonomy has LEDGER_COUNTERPARTY_RESOLVED and LEDGER_COUNTERPARTY_UNRESOLVED but not DISAGREEMENT_DETECTED.

---

## DATA_ZONE_DRIFT findings (3 MEDIUM)

**Finding #10 (MEDIUM) — `vies_submission_tracking_schema.md` line 181**
States export-temp bucket TTL is 30 days. Canonical TTL is 24 hours per `export_pipeline_policy` Section 4 and `data_retention_policy`.

**Finding #11 (MEDIUM) — `vies_xml_schema.md` lines 136, 161, 173**
References 'the 30-day rule per export_pipeline_policy Section 4' and 'Raw Upload zone; 30-day export storage'. Canonical export-temp TTL is 24 hours; no 30-day rule applies.

**Finding #12 (MEDIUM) — `accountant_pack_config_schema.md` line 200**
Cross-reference says 'operational export retention (30 days)'. Canonical policy is 24h for export-temp.

---

## INVOICE_SERIES finding (1 MEDIUM)

**Finding #13 (MEDIUM) — `invoice_numbering_sequence_policy.md` lines 27, 70, 145, 189**
The policy uses 'ISSUED' as the status name for the DRAFT-exit allocation trigger on tax invoices. The canonical `invoice_status_enum` (invoice_schema.md) has no ISSUED state for tax invoices — the first transition out of DRAFT is to SENT. Credit notes correctly use ISSUED (credit_note_status_enum has ISSUED); only the tax-invoice references need correction.

---

## FORWARD_REF_STALE finding (1 MEDIUM)

**Finding #14 (MEDIUM) — `split_payment_detection_policy.md` line 27**
Stale forward reference to `invoice_lifecycle_state_enum in Block 13` — an enum name that was never created. Block 13's actual enum is `invoice_status_enum`. The referenced status `UNPAID` also does not exist; the correct status is `PAYMENT_EXPECTED`.

---

## MOBILE_WRITE_MISSING finding (1 MEDIUM)

**Finding #15 (MEDIUM) — `tool_hash_chain_append.md` line 33**
Declares `side_effect_class: WRITES_AUDIT` but contains no mobile rejection note or cross-reference to `mobile_write_rejection_endpoints.md`. Every other write-class tool in the corpus includes an explicit mobile-rejection statement. While this tool is a server-side primitive not directly invocable from clients, the pattern should be consistent.

---

## Duplicate citation (1 LOW)

**Finding #16 (LOW) — `counterparty_resolver_tracing_schema.md` line 261**
Secondary citation of finding #9 — the cross-references section on line 261 explicitly cites the audit_event_taxonomy for LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED, which doesn't exist there. Resolved by the taxonomy amendment in finding #9.

---

## Remediation priority

| Priority | Findings | Reason |
|---|---|---|
| Immediate | #1 (match_level_enum) | Schema inconsistency will produce wrong auto-confirm routing if implemented as-is |
| Immediate | #3 (workflow_run_approvals) | Two fundamentally different approval models; one will be implemented wrong |
| High | #8, #9 (orphan events) | CI lint will fail on emitAudit calls referencing non-existent events |
| High | #2, #4, #5, #6, #7 (DDL conflicts) | Remaining schema conflicts create implementation ambiguity |
| Medium | #10, #11, #12 (export TTL) | Operators will mismanage file availability expectations |
| Medium | #13, #14 | Terminology and forward-reference cleanup |
| Lower | #15, #16 | Pattern consistency; no runtime impact |
