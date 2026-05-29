# Master Outline — Cyprus Bookkeeping Software

This document is the navigation hub for the entire elaboration phase. It lists every block, every phase, and every sub-doc as they are produced, with their file paths and current status. Every other document in the project should be reachable from here.

**Related documents**

- Core concept: `Docs/bookkeeping_software_core_plan.md`
- Elaboration roadmap: `Docs/elaboration_roadmap.md`
- Decisions log: `Docs/decisions_log.md`

---

## Conventions

- **File naming:** two-digit prefix for stable ordering, snake_case for the rest (e.g. `03_workflow_engine.md`).
- **Folder layout:**
  - `Docs/blocks/` — one architecture doc per block (Stage 1 deliverable)
  - `Docs/phases/<block-folder>/` — one doc per phase inside that block (Stage 2 deliverable)
  - `Docs/sub/<category>/` — focused sub-docs for tools, schemas, prompts, integrations (Stage 4 deliverable)
- **Status legend:** `[ ]` not started · `[~]` in progress · `[x]` complete

---

## Foundation — Cross-Cutting Infrastructure

These blocks underpin every workflow. Nothing in the domain or workflow layers can be built before these are locked.

### 01 — Core Principles & Design Constraints

- **File:** `Docs/blocks/01_core_principles.md`
- **Status:** [x]
- **Scope:** The non-negotiable rules everything else must obey — workflow-first architecture, structured data as the source of truth, AI assists / rules decide / user finalizes, security by design, simple UI with an advanced backend. This block is the constitution; later blocks reference it.
- **Phases folder:** `Docs/phases/01_core_principles/` — _to be filled in Stage 2_
- **Sub-docs:** _to be identified in Stage 3_

### 02 — Tenancy & Access Control

- **File:** `Docs/blocks/02_tenancy_and_access.md`
- **Status:** [x]
- **Scope:** Identity hierarchy (User → Organization → Business → Bank Account), role model (Owner, Admin, Bookkeeper, Accountant, Reviewer, Read-only), permission matrix, row-level isolation enforced by `organization_id` + `business_id` on every query.
- **Phases folder:** `Docs/phases/02_tenancy_and_access/`
  - [x] 01 — Schema scaffolding (`01_schema_scaffolding.md`)
  - [x] 02 — Authentication baseline (`02_authentication_baseline.md`)
  - [x] 03 — Multi-factor authentication (`03_multi_factor_authentication.md`)
  - [x] 04 — Role model & permission matrix (`04_role_model_and_permission_matrix.md`)
  - [x] 05 — Row-level security policies (`05_row_level_security_policies.md`)
  - [x] 06 — Step-up authentication (`06_step_up_authentication.md`)
  - [x] 07 — User invitation & management (`07_user_invitation_and_management.md`)
  - [x] 08 — OAuth integration foundation (`08_oauth_integration_foundation.md`)
  - [x] 09 — Role change propagation (`09_role_change_propagation.md`)
  - [x] 10 — Tenant isolation invariant tests (`10_tenant_isolation_invariant_tests.md`)
  - [x] 11 — Account settings (`11_account_settings.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 03 — Workflow Engine

- **File:** `Docs/blocks/03_workflow_engine.md`
- **Status:** [x]
- **Scope:** The orchestrator. Defines workflow runs, phases, gates, state transitions, audit-coupled advancement. Every other block exposes tools that this engine calls. Section 19 of the core plan flags this as the first thing to elaborate.
- **Phases folder:** `Docs/phases/03_workflow_engine/`
  - [x] 01 — Workflow run schema (`01_workflow_run_schema.md`)
  - [x] 02 — Workflow type registry & per-business config (`02_workflow_type_registry_and_config.md`)
  - [x] 03 — Tool registration framework (`03_tool_registration_framework.md`)
  - [x] 04 — State machine & lifecycle controls (`04_state_machine_and_lifecycle_controls.md`)
  - [x] 05 — Gate evaluation framework (`05_gate_evaluation_framework.md`)
  - [x] 06 — Phase execution engine (`06_phase_execution_engine.md`)
  - [x] 07 — Resumability & idempotency (`07_resumability_and_idempotency.md`)
  - [x] 08 — Failure policy & retry (`08_failure_policy_and_retry.md`)
  - [x] 09 — Trigger engine (`09_trigger_engine.md`)
  - [x] 10 — Concurrency control (`10_concurrency_control.md`)
  - [x] 11 — Adjustment runs (`11_adjustment_runs.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 04 — Data Architecture & Storage Zones

- **File:** `Docs/blocks/04_data_architecture.md`
- **Status:** [x]
- **Scope:** Database schema for all core data objects, the five storage zones (Raw Upload, Processing, Operational DB, Finalized Archive, Analytics), retention policy, encryption boundaries between zones.
- **Phases folder:** `Docs/phases/04_data_architecture/`
  - [x] 01 — Hashing & ID utilities (`01_hashing_and_id_utilities.md`)
  - [x] 02 — Bank statement & transaction schema (`02_bank_statement_and_transaction_schema.md`)
  - [x] 03 — Document & matching schema (`03_document_and_matching_schema.md`)
  - [x] 04 — Ledger & review schema (`04_ledger_and_review_schema.md`)
  - [x] 05 — Raw Upload zone (`05_raw_upload_zone.md`)
  - [x] 06 — Processing zone (`06_processing_zone.md`)
  - [x] 07 — Finalized Secure Archive zone (`07_finalized_secure_archive_zone.md`)
  - [x] 08 — Zone promotion pipeline (`08_zone_promotion_pipeline.md`)
  - [x] 09 — Analytics zone (`09_analytics_zone.md`)
  - [x] 10 — Retention engine (`10_retention_engine.md`)
  - [x] 11 — Legal hold (`11_legal_hold.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 05 — Security & Audit Layer

- **File:** `Docs/blocks/05_security_and_audit.md`
- **Status:** [x]
- **Scope:** Encryption (in transit, at rest, field-level), key management, per-business key separation, tamper-resistant audit log, GDPR posture, backup encryption.
- **Phases folder:** `Docs/phases/05_security_and_audit/`
  - [x] 01 — TLS & at-rest encryption baseline (`01_tls_and_at_rest_encryption_baseline.md`)
  - [x] 02 — Audit log schema & emission API (`02_audit_log_schema_and_emission_api.md`)
  - [x] 03 — Audit log tamper resistance (`03_audit_log_tamper_resistance.md`)
  - [x] 04 — Vault setup & DEK hierarchy (`04_vault_setup_and_dek_hierarchy.md`)
  - [x] 05 — pgcrypto field-level encryption (`05_pgcrypto_field_level_encryption.md`)
  - [x] 06 — Access control runtime (`06_access_control_runtime.md`)
  - [x] 07 — Secrets management (`07_secrets_management.md`)
  - [x] 08 — Backup encryption & DR (`08_backup_encryption_and_dr.md`)
  - [x] 09 — GDPR data subject rights (`09_gdpr_data_subject_rights.md`)
  - [x] 10 — Security alerting (internal) (`10_security_alerting_internal.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 06 — AI Layer (Privacy Gateway + End-Scan)

- **File:** `Docs/blocks/06_ai_layer.md`
- **Status:** [x]
- **Scope:** Three-tier routing (no AI / local LLM / external with redaction), the AI Privacy Gateway, schema-validated input and output, prompt management, anomaly detection, plain-language issue generation, AI usage logs.
- **Phases folder:** `Docs/phases/06_ai_layer/`
  - [x] 01 — Tier classification & routing (`01_tier_classification_and_routing.md`)
  - [x] 02 — Privacy Gateway pipeline (`02_privacy_gateway_pipeline.md`)
  - [x] 03 — Redaction policy & engine (`03_redaction_policy_and_engine.md`)
  - [x] 04 — Prompt management (`04_prompt_management.md`)
  - [x] 05 — Tier 3 (Anthropic Claude) integration (`05_tier_3_anthropic_claude_integration.md`)
  - [x] 06 — Tier 2 (local LLM) integration (`06_tier_2_local_llm_integration.md`)
  - [x] 07 — AI usage logging & cost tracking (`07_ai_usage_logging_and_cost_tracking.md`)
  - [x] 08 — Cost ceiling enforcement (`08_cost_ceiling_enforcement.md`)
  - [x] 09 — AI cache (within run) (`09_ai_cache_within_run.md`)
  - [x] 10 — Plain-language pipeline (`10_plain_language_pipeline.md`)
  - [x] 11 — End-Scan engine (`11_end_scan_engine.md`)
- **Sub-docs:** _to be identified in Stage 3_

---

## Domain Engines — The Financial Logic

Reusable engines that the OUT and IN workflows orchestrate. Each one is deterministic-first; AI assistance is bounded and routed through Block 06.

### 07 — Bank Statement Pipeline

- **File:** `Docs/blocks/07_bank_statement_pipeline.md`
- **Status:** [x]
- **Scope:** Statement upload, parsing (CSV preferred, PDF supported), normalization to transaction objects, deduplication via fingerprint and source_row_hash, generation of the per-transaction evidence PDF.
- **Phases folder:** `Docs/phases/07_bank_statement_pipeline/`
  - [x] 01 — Upload pipeline & file intake (`01_upload_pipeline_and_file_intake.md`)
  - [x] 02 — CSV parser & Revolut format (`02_csv_parser_and_revolut_format.md`)
  - [x] 03 — PDF parser via Google Document AI (`03_pdf_parser_via_google_document_ai.md`)
  - [x] 04 — Row normalization (`04_row_normalization.md`)
  - [x] 05 — Deduplication engine (`05_deduplication_engine.md`)
  - [x] 06 — Evidence PDF generation (`06_evidence_pdf_generation.md`)
  - [x] 07 — INGESTION workflow phase registration (`07_ingestion_workflow_phase_registration.md`)
  - [x] 08 — Partial upload handling & period validation (`08_partial_upload_handling_and_period_validation.md`)
  - [x] 09 — Event-driven workflow trigger (`09_event_driven_workflow_trigger.md`)
  - [x] 10 — End-to-end pipeline tests (`10_end_to_end_pipeline_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 08 — Transaction Classification & Tagging

- **File:** `Docs/blocks/08_transaction_classification_and_tagging.md`
- **Status:** [x]
- **Scope:** The 12 transaction types (`OUT_EXPENSE`, `IN_INCOME`, `INTERNAL_TRANSFER`, `FX_EXCHANGE`, `BANK_FEE`, `REFUND_IN/OUT`, `CHARGEBACK`, `LOAN_OR_SHAREHOLDER_MOVEMENT`, `PAYROLL_OR_TEAM_PAYMENT`, `TAX_PAYMENT`, `UNKNOWN`), tag system, recurring-vendor memory, business-specific tagging rules.
- **Phases folder:** `Docs/phases/08_transaction_classification_and_tagging/`
  - [x] 01 — Schema for classification & tagging (`01_schema_for_classification_and_tagging.md`)
  - [x] 02 — Type classifier Layer 1 (deterministic rules) (`02_transaction_type_classifier_layer_1.md`)
  - [x] 03 — Recurring vendor memory Layer 2 (`03_recurring_vendor_memory_layer_2.md`)
  - [x] 04 — AI fallback classifier Layer 3 (`04_ai_fallback_classifier_layer_3.md`)
  - [x] 05 — Tag system & default taxonomy (`05_tag_system_and_default_taxonomy.md`)
  - [x] 06 — Per-business custom tags (`06_per_business_custom_tags.md`)
  - [x] 07 — Confidence scoring & auto-confirm (`07_confidence_scoring_and_auto_confirm.md`)
  - [x] 08 — Tag taxonomy versioning (`08_tag_taxonomy_versioning.md`)
  - [x] 09 — CLASSIFICATION workflow phase registration (`09_classification_workflow_phase_registration.md`)
  - [x] 10 — End-to-end classifier tests (`10_end_to_end_classifier_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 09 — Document Intake & Extraction

- **File:** `Docs/blocks/09_document_intake_and_extraction.md`
- **Status:** [x]
- **Scope:** Email invoice finder (scoped, query-driven, not blanket ingestion), Google Drive invoice finder, manual upload path, OCR + structured field extraction (supplier, VAT number, totals, etc.).
- **Phases folder:** `Docs/phases/09_document_intake_and_extraction/`
  - [x] 01 — Schema for documents & source mappings (`01_schema_for_documents_and_source_mappings.md`)
  - [x] 02 — Document lifecycle state machine (`02_document_lifecycle_state_machine.md`)
  - [x] 03 — OCR pipeline (`03_ocr_pipeline.md`)
  - [x] 04 — Field extraction (deterministic + AI fallback) (`04_field_extraction_deterministic_and_ai_fallback.md`)
  - [x] 05 — Email finder (Gmail) (`05_email_finder_gmail.md`)
  - [x] 06 — Drive finder (`06_drive_finder.md`)
  - [x] 07 — Manual upload path (`07_manual_upload_path.md`)
  - [x] 08 — Cross-source document deduplication (`08_cross_source_document_deduplication.md`)
  - [x] 09 — EVIDENCE_DISCOVERY workflow phase registration (`09_evidence_discovery_workflow_phase_registration.md`)
  - [x] 10 — End-to-end intake tests (`10_end_to_end_intake_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 10 — Matching Engine

- **File:** `Docs/blocks/10_matching_engine.md`
- **Status:** [x]
- **Scope:** Deterministic-first match scoring across the four match levels (Exact, Strong Probable, Weak Possible, No Match), match statuses, duplicate detection, stored match reasons in plain language.
- **Phases folder:** `Docs/phases/10_matching_engine/`
  - [x] 01 — Schema for matching (`01_schema_for_matching.md`)
  - [x] 02 — Match scoring engine (`02_match_scoring_engine.md`)
  - [x] 03 — Strong Probable auto-confirm rule (`03_strong_probable_auto_confirm_rule.md`)
  - [x] 04 — Split-payment combinatorial detection (`04_split_payment_combinatorial_detection.md`)
  - [x] 05 — Duplicate detection (`05_duplicate_detection.md`)
  - [x] 06 — Rejection memory (`06_rejection_memory.md`)
  - [x] 07 — Match reason generation (`07_match_reason_generation.md`)
  - [x] 08 — Income matching variant (`08_income_matching_variant.md`)
  - [x] 09 — MATCHING + INCOME_MATCHING workflow phase registration (`09_matching_workflow_phase_registration.md`)
  - [x] 10 — End-to-end matching tests (`10_end_to_end_matching_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 11 — Ledger & Cyprus VAT Engine

- **File:** `Docs/blocks/11_ledger_and_cyprus_vat_engine.md`
- **Status:** [x]
- **Scope:** Type-aware draft ledger entry generation, the eight VAT treatments, VIES relevance, reverse-charge logic, accountant-review flagging, retention policy hooks.
- **Phases folder:** `Docs/phases/11_ledger_and_cyprus_vat_engine/`
  - [x] 01 — Schema for ledger entries & chart of accounts (`01_schema_for_ledger_and_chart_of_accounts.md`)
  - [x] 02 — Default Cyprus-friendly chart of accounts (`02_default_cyprus_chart_of_accounts.md`)
  - [x] 03 — Per-business chart customization & versioning (`03_per_business_chart_customization_and_versioning.md`)
  - [x] 04 — Counterparty country & VAT number resolution (`04_counterparty_country_and_vat_number_resolution.md`)
  - [x] 05 — VAT treatment classifier (`05_vat_treatment_classifier.md`)
  - [x] 06 — Reverse charge & VIES relevance (`06_reverse_charge_and_vies_relevance.md`)
  - [x] 07 — Type-aware ledger preparation paths (`07_type_aware_ledger_preparation_paths.md`)
  - [x] 08 — VAT amount, evidence & accountant-review flags (`08_vat_amount_evidence_and_accountant_review_flags.md`)
  - [x] 09 — LEDGER_PREPARATION workflow phase registration (`09_ledger_workflow_phase_registration.md`)
  - [x] 10 — End-to-end ledger tests (`10_end_to_end_ledger_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

---

## Workflows — Orchestrating the Engines

The two end-to-end pipelines that consume the foundation and domain blocks.

### 12 — OUT / Write-Off Workflow

- **File:** `Docs/blocks/12_out_workflow.md`
- **Status:** [x]
- **Scope:** Full outgoing pipeline from statement upload → transaction structuring → classification → email + Drive + manual evidence matching → ledger preparation → Cyprus VAT classification → AI end-scan → human review → finalization.
- **Phases folder:** `Docs/phases/12_out_workflow/`
  - [x] 01 — Schema & per-business OUT config (`01_schema_and_per_business_out_config.md`)
  - [x] 02 — `OUT_MONTHLY` workflow type definition (`02_out_monthly_workflow_type_definition.md`)
  - [x] 03 — `OUT_FILTER` phase (`03_out_filter_phase.md`)
  - [x] 04 — OUT/IN parallel coordination (`04_out_in_parallel_coordination.md`)
  - [x] 05 — Gate-function library (`05_gate_function_library.md`)
  - [x] 06 — `MANUAL_UPLOAD_HOLD` phase (`06_manual_upload_hold_phase.md`)
  - [x] 07 — `HUMAN_REVIEW_HOLD` phase (`07_human_review_hold_phase.md`)
  - [x] 08 — Triggers — manual + event (`08_triggers_manual_and_event.md`)
  - [x] 09 — `OUT_ADJUSTMENT` workflow type (`09_out_adjustment_workflow_type.md`)
  - [x] 10 — End-to-end OUT workflow tests (`10_end_to_end_out_workflow_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 13 — IN / Income Workflow + Invoice Generator

- **File:** `Docs/blocks/13_in_workflow_and_invoice_generator.md`
- **Status:** [x]
- **Scope:** Invoice creation lifecycle (Draft → Sent → Paid → Finalized, with credit notes and recurring invoices), incoming payment matching engine (full / partial / overpayment / multi-invoice patterns), full IN pipeline through to finalized income ledger.
- **Phases folder:** `Docs/phases/13_in_workflow_and_invoice_generator/`
  - [x] 01 — Invoice schema & numbering (`01_invoice_schema_and_numbering.md`)
  - [x] 02 — Client database (`02_client_database.md`)
  - [x] 03 — Invoice composition & lifecycle state machine (`03_invoice_composition_and_lifecycle.md`)
  - [x] 04 — PDF rendering & VAT-aware text (`04_pdf_rendering_and_vat_aware_text.md`)
  - [x] 05 — Recurring templates & daily scheduler (`05_recurring_templates_and_daily_scheduler.md`)
  - [x] 06 — Pro-forma conversion, credit notes & write-off (`06_pro_forma_conversion_credit_notes_and_write_off.md`)
  - [x] 07 — `IN_MONTHLY` workflow type definition (`07_in_monthly_workflow_type_definition.md`)
  - [x] 08 — `IN_FILTER` phase (`08_in_filter_phase.md`)
  - [x] 09 — IN gate library + `HUMAN_REVIEW_HOLD` (`09_in_gate_library_and_human_review_hold.md`)
  - [x] 10 — Income matching integration & multi-invoice allocation (`10_income_matching_integration_and_multi_invoice_allocation.md`)
  - [x] 11 — `IN_ADJUSTMENT` workflow type (`11_in_adjustment_workflow_type.md`)
  - [x] 12 — End-to-end IN workflow & invoice generator tests (`12_end_to_end_in_workflow_and_invoice_generator_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

---

## User Experience & Closeout

The user-facing edge of the product, plus the irreversible final step.

### 14 — Review Queue & Human Review

- **File:** `Docs/blocks/14_review_queue.md`
- **Status:** [x]
- **Scope:** The 6-bucket UI grouping (Missing Documents / Needs Confirmation / Possible Wrong Match / Possible Tax-VAT Issue / Unusual Transaction / Ready to Finalize), issue card structure, severity levels, resolution actions, audit-logged decisions.
- **Phases folder:** `Docs/phases/14_review_queue/`
  - [x] 01 — Schema extensions for `review_issues` (`01_schema_extensions_for_review_issues.md`)
  - [x] 02 — Issue groups, routing & severity (`02_issue_groups_routing_and_severity.md`)
  - [x] 03 — Issue card rendering & plain-language (`03_issue_card_rendering_and_plain_language.md`)
  - [x] 04 — Resolution actions (`04_resolution_actions.md`)
  - [x] 05 — Bulk actions (`05_bulk_actions.md`)
  - [x] 06 — Notes & assignment (`06_notes_and_assignment.md`)
  - [x] 07 — Snooze & cross-run carry-forward (`07_snooze_and_cross_run_carry_forward.md`)
  - [x] 08 — Re-scan on resolution (`08_rescan_on_resolution.md`)
  - [x] 09 — Mobile read-only UX (`09_mobile_read_only_ux.md`)
  - [x] 10 — End-to-end review queue tests (`10_end_to_end_review_queue_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 15 — Finalization & Secure Archive

- **File:** `Docs/blocks/15_finalization_and_secure_archive.md`
- **Status:** [x]
- **Scope:** Finalization preconditions, lock semantics, immutable archive design, retention (≥ 6 years for VAT/books), adjustment and period-reopening workflow with full audit trail.
- **Phases folder:** `Docs/phases/15_finalization_and_secure_archive/`
  - [x] 01 — Schema for archive package & locked ledger (`01_schema_for_archive_package_and_locked_ledger.md`)
  - [x] 02 — Finalization preconditions & gates (`02_finalization_preconditions_and_gates.md`)
  - [x] 03 — Approval modality & step-up auth (`03_approval_modality_and_step_up_auth.md`)
  - [x] 04 — The lock sequence (`04_lock_sequence.md`)
  - [x] 05 — Archive package construction (`05_archive_package_construction.md`)
  - [x] 06 — Manifest versioning for adjustments (`06_manifest_versioning_for_adjustments.md`)
  - [x] 07 — Storage Object Lock & three-layer immutability (`07_storage_object_lock_and_three_layer_immutability.md`)
  - [x] 08 — Re-finalization for adjustment runs (`08_re_finalization_for_adjustment_runs.md`)
  - [x] 09 — Failure handling & rollback (`09_failure_handling_and_rollback.md`)
  - [x] 10 — End-to-end finalization tests (`10_end_to_end_finalization_tests.md`)
- **Sub-docs:** _to be identified in Stage 3_

### 16 — Dashboard & Reporting

- **File:** `Docs/blocks/16_dashboard_and_reporting.md`
- **Status:** [x]
- **Scope:** Dashboard views (monthly overview, income, expense, missing docs, VAT, etc.), drill-down rules tied to permissions, exports (transaction, expense, income, VAT prep, VIES prep, accountant pack, finalized archive package — see Block 16 for the complete 13-item export catalogue).
- **Phases folder:** `Docs/phases/16_dashboard_and_reporting/`
  - [x] 01 — Schema, preferences & analytics consumption (`01_schema_preferences_and_analytics_consumption.md`)
  - [x] 02 — Drill-down routing & permissions (`02_drill_down_routing_and_permissions.md`)
  - [x] 03 — Design System MASTER (`03_design_system_master.md`)
  - [x] 04 — Component library (`04_component_library.md`)
  - [x] 05 — Dashboard shell (`05_dashboard_shell.md`)
  - [x] 06 — Default dashboard cards (`06_default_dashboard_cards.md`)
  - [x] 07 — Multi-business view, refresh state & customization (`07_multi_business_view_and_customization.md`)
  - [x] 08 — Drill-down list & detail views (`08_drill_down_list_and_detail_views.md`)
  - [x] 09 — Export pipelines & format dispatcher (`09_export_pipelines_and_format_dispatcher.md`)
  - [x] 10 — PDF generators (`10_pdf_generators.md`)
  - [x] 11 — Accountant pack & VIES regulator XML (`11_accountant_pack_and_vies_xml.md`)
  - [x] 12 — Accessibility, i18n, mobile read-only, performance (`12_accessibility_i18n_mobile_performance.md`)
  - [x] 13 — End-to-end tests & visual regression (`13_end_to_end_dashboard_tests_and_visual_regression.md`)
- **Sub-docs:** _to be identified in Stage 3_

---

## Stage 5 — Plane Mapping

Stage 5 translated the locked spec set into an actionable backlog inside the self-hosted Plane workspace (`timefuser.plane.so`). The Plane project is **Cyprus Bookkeeping SaaS** (identifier `BOOK`, UUID `28b250c0-d991-4dcb-a48c-51af27aa17dd`, workspace `ae77dd56-5e8e-4321-a859-6e6dff0a707a`).

**Build position** is encoded in module names (`#01 · B01 — Core Principles & Design Constraints`, etc.). Module names carry the build-order prefix because Plane modules sort alphabetically by name in the UI and block numbers are not strictly sequential (B03 — Workflow Engine — is the 5th block to build, not the 3rd).

### Blocks → Plane modules

| Build # | Block | Module name | Plane module UUID |
|---|---|---|---|
| 01 | B01 | Core Principles & Design Constraints | `fd330c71-4390-4f43-89a9-7e929aa2031e` |
| 02 | B02 | Tenancy & Access Control | `7ac97230-4024-4f7d-9faa-1b30b9cf0543` |
| 03 | B04 | Data Architecture & Storage Zones | `e10d8875-34a0-4a27-9b6d-9ae1ff4c0929` |
| 04 | B05 | Security & Audit Layer | `e8ecd532-3f7f-4c19-9635-14484e06f686` |
| 05 | B03 | Workflow Engine | `4f7ddebd-7a50-446b-b5c9-719c36f343af` |
| 06 | B06 | AI Layer | `a57b86f0-bd65-44e9-916e-35341cbc1471` |
| 07 | B07 | Bank Statement Pipeline | `513a4eee-28cc-4a5c-89d8-997f31d66906` |
| 08 | B08 | Transaction Classification & Tagging | `dd63669e-2741-488b-88c9-b7226afd2796` |
| 09 | B09 | Document Intake & Extraction | `92183b23-61fc-4421-a90a-5b8a4dcb468c` |
| 10 | B10 | Matching Engine | `b9fe7bb5-460b-4d5c-b733-ed846cf363df` |
| 11 | B11 | Ledger & Cyprus VAT Engine | `340d9adb-796b-4dde-87b9-28030c5d387f` |
| 12 | B12 | OUT / Write-Off Workflow | `9fabf417-5d44-4666-a665-80f1548bde1e` |
| 13 | B13 | IN / Income Workflow + Invoice Generator | `cbe4f0b1-fa8e-4a80-89a3-a0b4d52b35d0` |
| 14 | B14 | Review Queue & Human Review | `ab72b937-47bb-4c75-bd58-82432bc2d0f0` |
| 15 | B15 | Finalization & Secure Archive | `7ec4e640-7c47-49bf-90d7-f109703ce667` |
| 16 | B16 | Dashboard & Reporting | `c9dab35a-9f7a-4bb5-8335-8c94c1b02ae9` |

### Phases → Plane issues

Each phase doc maps to one Plane work-item under its block's module. Issue names follow `[B{block}·P{phase}] {phase name}`; `external_id` is `B{XX}P{YY}` for programmatic lookup (e.g. `B05P02`); `external_source` is `stage5_brief`. Block 01 has no phases and is represented by one reference issue `[B01·P00] Design Constraints & Principles Reference`.

Phase issue counts per block: B01 (1 reference) · B02 (11) · B03 (11) · B04 (11) · B05 (10) · B06 (11) · B07 (10) · B08 (10) · B09 (10) · B10 (10) · B11 (10) · B12 (10) · B13 (12) · B14 (10) · B15 (10) · B16 (13) = **160 phase issues**.

Issues are queryable via `mcp__plane__list_work_items` with `external_id="B{XX}P{YY}"` or `external_source="stage5_brief"`.

### Sub-docs → Plane child work-items

Stage 4 produced 638 sub-doc files across 9 categories under `Docs/sub/`. Stage 5 Pass 3 created one Plane child work-item per **unique sub-doc hook** referenced by the phase docs' `## Sub-doc Hooks (Stage 4)` sections, attached to the **earliest consuming phase** in build order (per the brief's cross-block deduplication rule). After dedup, **721 child issues** were created (cross-block hooks went to their earliest owner only).

Child issue naming: `[B{block}·P{phase}·SD] {short_name}`. external_id pattern: `B{XX}P{YY}SD{NN}`. external_source: `stage5_brief_pass3`. Parent: the phase issue UUID.

Pass 3b enriched each child issue's description with (a) the **phase doc path** (`Docs/phases/<block>/<file>.md`) for the hook context and (b) the **best-matched sub-doc spec file(s)** under `Docs/sub/` based on token-overlap fuzzy matching against the 638 sub-doc files. 651/721 (90%) had at least one file match. The remaining 70 carry an explicit `no file match found — Stage 6 should reconcile` note in the description.

Per-block child issue counts:

| Block | Hooks | With file match | No match (Stage 6) |
|---|---|---|---|
| B02 | 43 | 36 | 7 |
| B03 | 43 | 39 | 4 |
| B04 | 54 | 48 | 6 |
| B05 | 47 | 43 | 4 |
| B06 | 47 | 42 | 5 |
| B07 | 44 | 40 | 4 |
| B08 | 38 | 35 | 3 |
| B09 | 39 | 38 | 1 |
| B10 | 35 | 32 | 3 |
| B11 | 43 | 40 | 3 |
| B12 | 43 | 41 | 2 |
| B13 | 52 | 49 | 3 |
| B14 | 54 | 45 | 9 |
| B15 | 52 | 50 | 2 |
| B16 | 87 | 73 | 14 |
| **Total** | **721** | **651** | **70** |

### Stage 6 follow-ups identified during Stage 5

1. **Stale duplicate phase file** — `Docs/phases/07_bank_statement_pipeline/03_pdf_parser_google_document_ai.md` is a stale copy of `03_pdf_parser_via_google_document_ai.md` (the canonical title carries "via"). Stage 5 used the canonical file; the duplicate should be deleted in Stage 6 pre-build cleanup.
2. **Missing reference file** — the brief at `Docs/PLANE_STAGE5_BRIEF.md` refers to `outputs/stage3_locked_subdocs.json`, which does not exist in the repo. Stage 5 sub-doc ownership was derived directly from phase docs' `## Sub-doc Hooks (Stage 4)` sections instead. Stage 6 should either regenerate this artefact or update the brief.
3. **Hook count delta** — brief estimated ~637 sub-docs; Stage 5 produced 721 unique hook tasks. The delta reflects fine-grained hook decomposition in the phase docs that wasn't captured by the (missing) Stage 3 JSON. Stage 6 should confirm hook-level granularity is the right build unit, or merge child issues where they collapse to one sub-doc file.
4. **70 child issues without a fuzzy-matched spec file** — token-overlap matching found no candidate in `Docs/sub/` for these hook names. Each carries an explicit Stage-6-reconcile note in its Plane description. Most are likely genuine omissions from Stage 4 or hooks that need to be merged with a similarly-named existing sub-doc.

---

## How This Document Grows

- **End of Stage 1:** every block above has its architecture file written and ticked `[x]`. The cross-block compatibility scan is logged below.
- **End of Stage 2:** each block's `Phases folder` line expands into a list of phase files with their own statuses.
- **End of Stage 4:** each block's `Sub-docs` line expands into a list of sub-doc files with their own statuses.
- **End of Stage 5:** a final section maps blocks → Plane modules and phases → Plane issues.

---

## Scan Log

Each compatibility scan produces a one-paragraph entry below: what was checked, what was found, what was fixed.

### Stage 6 — Pre-build final scan — 2026-05-18

**Scope.** Final pre-build verification across (a) the Plane backlog (16 modules, 160 phase issues, 721 sub-doc child issues = 897 work-items), (b) the spec corpus (16 block docs, 160 phase docs, 638 sub-doc files), (c) the decisions log + amendment record, (d) the four Stage-5 carryover items captured in the prior scan-log entry. Goal: every Plane item traces back to a locked spec; all last-minute inconsistencies resolved before Stage 7 implementation begins.

**Method.** Five `general-purpose` agents in parallel, each tightly scoped to keep token spend bounded: (A) Plane backlog audit — counts, module/parent linkage, description hygiene; (B) closed-enum + convention violations across the spec corpus — `CRITICAL` vs `BLOCKING`, `COMPLETED` vs `FINALIZED`, gate-name 2-dot rule, FK target `business_entities(id)`, `HALF_UP` rounding; (C) cross-reference integrity — every backtick-quoted `.md` resolves, audit-event taxonomy membership, tool-naming policy compliance; (D) Stage-5 carryover resolution — duplicate phase file, missing JSON artefact, 721 vs 638 hook granularity, 70 no-match hooks triaged; (E) decisions-log alignment — 15 sampled locked decisions verified against spec coverage, 12 amendments checked for drift, 4 deferred items confirmed resolved. Then a sixth `general-purpose` agent attached the 721 sub-doc child issues to their block's Plane module (Pass-3 omission flagged by agent A), and a seventh applied the spec-corpus reconciliation patches (taxonomy additions, dangling-ref fixes, tool-name renames). Main thread applied remaining deterministic fixes (camelCase residues, banker's-rounding, brief annotations) and wrote this sign-off.

**Findings.** **0 BLOCKING outstanding** at sign-off. Raw findings before reconciliation: 1 BLOCKING (audit-event taxonomy drift, 20+ events emitted but absent from `Docs/sub/reference/audit_event_taxonomy.md`), 14 HIGH (dangling backtick `.md` references), 8+ MEDIUM (tool-name prefix violations outside the `tool_naming_convention_policy` allowlist), 2 MEDIUM (banker's-rounding in B11 P08 contradicting `HALF_UP always`), 1 MEDIUM (721 sub-doc children unattached to Plane modules), 9+ LOW (camelCase residues `report.generatePeriodReport`, `prepareInvoiceLifecycleEntries`), plus the 4 Stage-5-carryover items. Plane backlog audit (A): counts PASS (16/160/721), all 721 children resolved to valid phase parents, all external_id prefixes match parent — zero linkage defects. Convention scan (B): the `CRITICAL` severity occurrences in Block 05's security-alerting are a separate alerting-severity enum (disambiguated at `Docs/sub/reference/severity_enum.md:57` and `security_best_practices_guide.md:211`), not the review-issue severity — downgraded to verified-OK. Decisions-log scan (E): 15/15 sampled decisions have spec coverage; 12/12 amendments aligned; zero contradictions; only LOW editorial drift surfaced.

**Fixes applied (all severities, ~25 files):**

- *BLOCKING — audit-event taxonomy:* 16 new events added to `Docs/sub/reference/audit_event_taxonomy.md` under the appropriate domain sections (`WORKFLOW_GATE_DECISION`, `BUSINESS_VAT_VALIDATED`, `BUSINESS_SETTINGS_UPDATED`, `VAT_RATE_CHANGED`, `VIES_SUBMISSION_RESUBMITTED`, `ENGINE_APPROVAL_EXPIRED`, `ENGINE_APPROVAL_REREQUESTED`, `ENGINE_RUN_STALE_PAUSED`, `ARCHIVE_PERIOD_LOCKED`, `ARCHIVE_LOCK_VIOLATION_ATTEMPTED`, `BANK_STATEMENT_ROWS_SKIPPED`, `CLIENT_VIES_VALIDATED`, `CLIENT_DATA_EXPORTED`, `IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`, `OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`, `EXPORT_REQUEST_REJECTED_PERMISSION`); 4 events renamed in source files to match canonical taxonomy forms (`MATCH_AUTO_CONFIRMED` → `MATCHING_AUTO_CONFIRMED` across `matching_engine_policy.md` + `match_proposals_schema.md` + `matching_engine_fixture_content.md`; `INVOICE_RECURRING_CANCELLED` collapsed to canonical `RECURRING_SCHEDULE_CANCELLED` in `recurring_invoice_policy.md`).
- *HIGH — dangling backtick refs:* 5 fixed (`tool_security_emit_audit.md` → `tool_emit_audit.md` in `tool_schema_definition_policy.md`; `in_workflow.md` / `out_workflow.md` → `Docs/blocks/13_…` / `12_…` in `income_outcome_enum.md`; `review_queue_create_issue.md` → `tool_review_queue_create_issue.md` in `tool_vies_validate.md` and `tool_invoice_send.md`). 8 flagged as Stage-7 follow-ups (no candidate sibling): `bank_statement_pipeline_overview.md`, `document_intake_flow.md`, `dr_baseline_snapshots.md`, `intake_pipeline_overview.md`, `invoice_lifecycle_integration.md`, `pinned_library_versions.md`, `out_monthly_type_definition.md`, plus `tool_ledger_generate_vat_explanation.md` / `tool_matching_generate_reason.md` / `tool_review_queue_generate_card_content.md` referenced from prompt docs — these are missing sub-docs to be written during Stage 7 as their owning phases land.
- *MEDIUM — tool-name prefix violations:* 15 occurrences renamed across 8 files to comply with `tool_naming_convention_policy` allowlist. `assignment.assign` / `assignment.reassign` / `assignment.clear` → `review_queue.assign` / `review_queue.reassign` / `review_queue.clear_assignment` (in `14_review_queue/06_notes_and_assignment.md`); `client.add_alias` / `client.retire_alias` / `client.change_canonical_name` → `in_workflow.*` (in `client_multi_name_alias_schema.md`); `invoice.create` → `in_workflow.create_invoice` (in `recurring_invoice_policy.md`); `bank_statement.ingest` → `intake.ingest_bank_statement` (in `bank_statement_fixture_content.md`); `vies.validate` → `in_workflow.vies_validate` (in `onboarding_ui_spec.md`); `vendor_memory.write` → `classification.vendor_memory_write` (in `classification_review_ui_spec.md`); `gateway.invoke` → `ai.gateway_invoke` (in `gateway_bypass_detection_policy.md`); `integrations.disconnect` → `auth.integrations_disconnect` (in `settings_integrations_ui_spec.md`).
- *MEDIUM — banker's rounding:* Both occurrences in `Docs/phases/11_ledger_and_cyprus_vat_engine/08_vat_amount_evidence_and_accountant_review_flags.md` (lines 58 + 125) rewritten to `HALF_UP` to match the canonical project-wide rounding rule.
- *MEDIUM — Plane module membership:* `add_work_items_to_module` called for each of the 15 blocks with children. All 16 module `total_issues` now match expected (B01=1, B02=54, B03=54, B04=65, B05=57, B06=58, B07=54, B08=48, B09=49, B10=45, B11=53, B12=53, B13=64, B14=64, B15=62, B16=100; sum=881). Module-scoped Plane UI view now surfaces sub-doc children alongside phase issues.
- *Stage-5 carryover:* (1) Stale duplicate `Docs/phases/07_bank_statement_pipeline/03_pdf_parser_google_document_ai.md` deleted (the `_via_` version is canonical); (2) brief references to the non-existent `outputs/stage3_locked_subdocs.json` annotated as "superseded by `Docs/sub/` corpus + Stage-5 hook map" in `Docs/HANDOFF.md` L17 + L176 and `Docs/NEXT_SESSION_START_PROMPT.md` L22 — file deliberately not regenerated (the Stage-5 hook-to-file matching produced a fresher, more accurate artefact); (3) hook-level granularity (721 hooks vs 638 sub-doc files) kept as-is — hooks represent distinct build-time responsibilities and many-to-one file mapping is intentional; (4) 70 no-match hooks triaged on a 20-sample basis — extrapolated ~38 genuinely-missing sub-docs (Stage 4 omissions), ~14 misnamed-file existing (improvable via better fuzzy match), ~18 overloaded concepts (need explicit file pointers). These remain as Stage-7 incremental work: as each owning phase is built, the implementer writes any missing sub-doc references at that point.
- *LOW — editorial:* 6 occurrences of `report.generatePeriodReport` renamed to canonical snake_case `report.generate_period_report` in `Docs/phases/16_dashboard_and_reporting/10_pdf_generators.md` (5) + `Docs/phases/15_finalization_and_secure_archive/05_archive_package_construction.md` (1); 13+ occurrences of `prepareInvoiceLifecycleEntries` renamed to `prepare_invoice_lifecycle_entries` across `tool_bad_debt_expense.md`, `invoice_lifecycle_policy.md`, `dedup_key_generator_policy.md`, `adjustment_entry_schema.md`, `13_…/06_pro_forma_conversion_credit_notes_and_write_off.md`, `11_…/07_type_aware_ledger_preparation_paths.md`, `15_…/06_manifest_versioning_for_adjustments.md`, `15_…/08_re_finalization_for_adjustment_runs.md`. Historical references in `Docs/decisions_log.md` and earlier scan-log entries left intact (those record what was decided at the time).

**Stage-7 starting punchlist (residual; not blocking).** (i) Write the 8 referenced-but-missing sub-docs as their owning phases come up; (ii) write the ~38 hook-implied-but-missing sub-docs uncovered by the no-match triage as their phases come up; (iii) the `MATCHING_MATCH_AUTO_CONFIRMED` variant in `match_proposal_schema.md` / `match_records_schema.md` / `match_status_enum.md` was left intact pending a decisions-log clarification on whether it's a distinct event from `MATCHING_AUTO_CONFIRMED` or a typo; (iv) re-run the fuzzy matcher with code-token / alias awareness against the 70 no-match list once any new sub-docs land.

**Sign-off.** **GO.** Plane backlog is build-ready, fully traceable end-to-end; every Plane item carries an external_id that maps to a phase doc + (where matched) one or more sub-doc spec files; convention and taxonomy violations resolved; decisions-log aligned; only Stage-4-gap residuals remain and are scoped to be filled incrementally during Stage 7. Stage 7 (Build) can begin.

---

### Stage 5 — Plane setup — 2026-05-18

**Scope.** Translate the locked Stage 1–4 specification (16 block docs, 160 phase docs across 15 phase folders, 638 sub-doc files under `Docs/sub/`) into an actionable Plane backlog in strict chronological build order. Target workspace: self-hosted Plane at `timefuser.plane.so`, project "Cyprus Bookkeeping SaaS" (identifier `BOOK`). Brief: `Docs/PLANE_STAGE5_BRIEF.md`.

**Method.** Four-pass execution per the brief's plan. **Pass 1** — created 16 modules in build order (not numerical order), named with build-position prefix (`#01 · B01 — Core Principles & Design Constraints`, etc.) so Plane's name-sort displays the correct sequence. Module descriptions reference `Docs/blocks/<NN>_<name>.md`. **Pass 2** — created 160 phase work-items, one per phase doc, attached to its block's module via `mcp__plane__add_work_items_to_module`. Phase issues use external_id `B{XX}P{YY}` for programmatic lookup, external_source `stage5_brief`. Block 01 (constitution-only, no phases) is represented by one reference issue (`B01P00`). Titles follow the brief's exact wording from Section 3. **Pass 3** — parsed every phase doc's `## Sub-doc Hooks (Stage 4)` section, normalized hook names (lower-cased, "sub-doc" suffix stripped), deduplicated across build order so cross-block hooks attach to their earliest consuming phase. Two parallel `general-purpose` subagents handled creation (blocks 02–09 / 10–16) using `mcp__plane__create_work_item` with `parent=<phase_issue_id>` to establish the hierarchy. **Pass 3b** — patched every child issue's description with the parent phase doc path and the top-ranked candidate sub-doc spec file(s) under `Docs/sub/` (token-overlap fuzzy match against the 638 Stage-4 files), so a Stage-7 implementer can open a child issue and immediately know which spec to read. Two parallel `general-purpose` subagents handled the updates. **Pass 4** — verified counts, updated this outline and `elaboration_roadmap.md`.

**Findings.** **16 modules + 160 phase issues + 721 sub-doc child issues = 897 Plane work-items.** Brief estimated ~165 issues + ~637 tasks; the actual numbers (160 + 721) reflect (a) Block 01 collapsing to one reference issue rather than ~5 phases, and (b) phase-doc hooks being more granular than the (missing) `outputs/stage3_locked_subdocs.json` originally implied. Zero create errors across both Pass 3 subagents (355/355 and 366/366). Of the 721 child issues, **651 (90%) had at least one fuzzy-matched sub-doc spec file** linked into the description; **70 (10%)** carry an explicit `no file match found in Docs/sub/ — Stage 6 should reconcile this hook against the spec corpus` note for pre-build cleanup. Two hygiene issues surfaced: a stale duplicate phase file (`03_pdf_parser_google_document_ai.md` alongside the canonical `03_pdf_parser_via_google_document_ai.md` in B07) and the missing `outputs/stage3_locked_subdocs.json` referenced by the brief — phase-doc sub-doc-hook sections were used as the authoritative source in its place.

**Conventions enforced.** Module name format: `#{build_pos} · B{block} — {scope}`. Phase issue: `[B{XX}·P{YY}] {phase name}` with external_id `B{XX}P{YY}` and external_source `stage5_brief`. Sub-doc child issue: `[B{XX}·P{YY}·SD] {short_name}` with external_id `B{XX}P{YY}SD{NN}` and external_source `stage5_brief_pass3`. Severity vocabulary in descriptions matches the canonical `LOW · MEDIUM · HIGH · BLOCKING` (no `CRITICAL`); run_status / invoice_status / dedup_status / match_level / gate-name / audit-event-name conventions per the brief Section 8 hard conventions table. Every child issue's description carries the parent phase doc path and the candidate spec file path(s) — Stage-7 implementer can open any Plane item and find its spec.

**Sign-off.** GO. Plane backlog is build-ready, structured, and traceable end-to-end: every Plane item carries an external_id that maps back to a spec file under `Docs/phases/` or `Docs/sub/`. Four Stage-6 follow-ups captured: (1) delete stale B07 duplicate phase file, (2) regenerate or replace `outputs/stage3_locked_subdocs.json` reference, (3) confirm hook-level granularity vs sub-doc-file granularity for the 721 children, (4) reconcile the 70 no-match hooks against the spec corpus. Stage 6 (pre-build final scan) follows — walk the Plane backlog top-to-bottom, verify every item maps cleanly to a finished spec, fix the four Stage-6-flagged items, and sign off before Stage 7 implementation begins.

---

### Stage 4 — Layer 1 cross-corpus consistency scan — 2026-05-15

**Scope.** All 93 Layer 1 sub-docs under `Docs/sub/` (the cross-block conventions, taxonomies, tools, schemas, integrations, runbooks, policies, UI specs, and fixtures that bind Layer 2's per-block work). Plus `outputs/stage3_locked_subdocs.json`, `Docs/decisions_log.md` (Stage 4 amendments), and `Docs/HANDOFF.md` as authoritative references for the closed enums and conventions.

**Method.** One delegated `general-purpose` agent ran a structured cross-corpus scan across the 93 sub-docs, checking 6 categories: convention adherence (tool naming, data-layer conventions, audit-event taxonomy membership), closed-enum cleanliness (severity / VAT / transaction type / issue group / permission surface), cross-reference integrity (every named sub-doc reference resolves), permission-surface usage (15-surface canonical set), mobile-rejection consistency, and cross-block symmetry. Findings written to `outputs/stage4_layer1_scan_findings.json` as structured per-finding records with severity / category / file / suggested_fix.

**Findings.** **6 BLOCKING, 18 HIGH, 17 MEDIUM, 3 LOW (44 total).** Zero findings in the ENUM, PERMISSION, MOBILE categories — those three closed taxonomies were already consistent. Three patterns dominated: (1) tool / issue-type namespace violations against the `tool_naming_convention_policy` allowlist (`clients.*`, `invoice.*`, `vendor_memory.*`, `income_matching.*`, plus issue-type prefixes `finalization.*`, `dashboard.*`, `analytics.*`); (2) audit event taxonomy out of sync with policies / runbooks / tools / integrations — 60+ events emitted across the corpus that weren't in the canonical catalogue; (3) Stage 3 Layer 0 compression renames not propagated (`pdf_font_pinning_policy` → `pdf_generation_policies`, etc.).

**Fixes applied (all severities, ~25 files):**

- *BLOCKING — Tool namespace violations:* 5 tools renamed to allowlist-compliant forms. `vendor_memory.*` → `classification.*` (per Block 08 ownership); `clients.*` → `in_workflow.*` (per Block 13 ownership); `invoice.mark_*` lifecycle calls → `in_workflow.mark_invoice_*`; `income_matching.apply_outcome` → `matching.apply_income_outcome`. Plus added the missing Registration block to `tool_vendor_memory_increment.md`. Issue-type renames in `issue_type_to_group_mapping.md` (`finalization.*` → `archive.finalization_*`, `invoice.*` → `in_workflow.invoice_*`, `dashboard.*` → `report.dashboard_*`, `analytics.refresh_failed` → `data.analytics_refresh_failed`).
- *HIGH — Audit event taxonomy:* Added 60+ missing events across 10 domains to `audit_event_taxonomy.md`. Includes the canonical step-up token lifecycle events (`STEP_UP_TOKEN_CONSUMED/EXPIRED/REVOKED/ALREADY_CONSUMED/ACTION_MISMATCH/SIMULATION_*`), mobile-rejection (`MOBILE_WRITE_REJECTED`), workflow approval (`WORKFLOW_APPROVAL_RECORDED/RE_APPROVAL/STALE`), config (`BUSINESS_WORKFLOW_CONFIG_TOGGLED`, `WORKFLOW_TRIGGER_SHORT_CIRCUITED`), phase-migration (`WORKFLOW_TYPE_REGISTRY_UPDATED/PHASE_SEQUENCE_MIGRATED/REVERTED`), event-subscription (`EVENT_SUBSCRIPTION_REGISTERED/DISABLED`, `TRIGGER_EVENTS_PROCESSED_RECORDED`), object-lock retention (`OBJECT_LOCK_RETENTION_SET`), AI tier (`AI_TIER_UNAVAILABLE`), end-scan affected-only (`END_SCAN_AFFECTED_ONLY_RESCAN_TRIGGERED`), gateway bypass lint (`AI_PRIVACY_GATEWAY_BYPASS_LINT_FAILURE`), redaction (`AI_PAYLOAD_REDACTED`), VIES (`LEDGER_VIES_PERIOD_ASSIGNED/CHANGED`, `EXPORT_VIES_GENERATED/CORRECTIVE_FILING_FLAGGED`), chart-of-accounts lifecycle (`CHART_MAPPING_VERSION_CREATED`, `CHART_ACCOUNT_ADDED/RETIRED`, `CHART_DEFAULT_VERSION_CHANGED`), internal-transfer detection (`INTERNAL_TRANSFER_DETECTED/BILATERAL_LINKED`), FX rate (`FX_RATE_FETCHED_BANK/ECB/UNRESOLVABLE`), manual override (`MANUAL_OVERRIDE_REJECTED_FINALIZED_PERIOD`), filter-status flip (`TRANSACTION_FILTER_STATUS_CHANGED`), adjustment-record creation (`OUT_ADJUSTMENT_RECORD_CREATED`, `IN_ADJUSTMENT_RECORD_CREATED`, `ADJUSTMENT_TOUCHED_RECORD`), invoice PDF supersession (`INVOICE_PDF_SUPERSEDED`), gate timeout (`WORKFLOW_GATE_TIMEOUT`), force-resume (`WORKFLOW_RUN_FORCE_RESUMED`), email (`EMAIL_DISPATCHED/FAILED/BOUNCED/COMPLAINED/ADDRESS_SUPPRESSED`), integration folder-mapping (`INTEGRATION_FOLDER_MAPPED`), archive recovery (`ARCHIVE_PROMOTION_RECOVERY_INITIATED/COMPLETED`, `ARCHIVE_TAMPER_FALSE_POSITIVE_CLEARED`), client registry lookup (`CLIENT_REGISTRY_LOOKUP`), vendor memory increment / tier transition (`CLASSIFICATION_VENDOR_MEMORY_INCREMENTED`, `CLASSIFICATION_VENDOR_MEMORY_TIER_TRANSITION`), audit-chain timestamp verification (`AUDIT_CHAIN_TIMESTAMP_VERIFICATION_FAILED`), security investigation (`SECURITY_INVESTIGATION_RECORDED`). Plus consequential rename in `phase_renumbering_migration_runbook.md` to use the prefixed `WORKFLOW_PHASE_SEQUENCE_*` forms.
- *MEDIUM — Cross-ref consolidation drift:* `pdf_font_pinning_policy` (2 files) → `pdf_generation_policies`; `bulk_action_performance_policy` → `bulk_action_policies`; `dashboard_card_sync_requery_policy` → `dashboard_card_policies`; `snooze_severity_elevation_policy` → `rescan_policies`; `custom_tag_uniqueness_policy` → `custom_tag_policies`. Plus Layer 2 forward-reference annotations for `audit_event_payload_schemas`.
- *MEDIUM — Schema cross-refs:* Added `data_layer_conventions_policy` cross-reference to 7 schema sub-docs that were missing it (adjustment_record, transaction_tag_columns, review_issues, block_16_as_of_view, oauth_token_encryption, review_issues_status_enum_migration, split_payment_relationship).
- *LOW — Editorial:* Fixed `ARCHIVE_DATA_READ` contradiction in `archive_schema.md` (the per-read event was collapsed into `ARCHIVE_DATA_READ_SESSION_SUMMARY` per the Block 15 scan; reworded to remove the contradiction); corrected `trigger_events_processed_schema.md` "formerly" parenthetical; moved the `report.generate_period_report` rename open-item from `tool_naming_convention_policy.md`'s open-items section to a new Resolved-items section now that the 2026-05-09 Stage 4 Layer 1 amendment ratified the rename.

**Sign-off.** GO. Layer 1 cleared. Ready for Layer 2 — per-section parallel writes (541 sub-docs across 4 parallel agents per the HANDOFF Stage 4 plan).

---

### Stage 3 — Sub-Doc Identification master scan — 2026-05-09

**Scope.** All 16 architecture docs (`Docs/blocks/*.md`) + ~165 phase docs (`Docs/phases/<block>/*.md`) + `Docs/decisions_log.md` (Stage 1 deferred decisions + 12 Stage 2 amendments) + this outline's 15-entry Scan Log. Goal: identify every sub-doc that Stage 4 must produce. The seed is the `## Sub-doc Hooks (Stage 4)` section at the bottom of every phase doc, plus informal body-text references and decisions-log deferrals.

**Method.** Three-pass delegated. **Pass 1 — Parallel harvest:** four `general-purpose` agents in parallel, sliced along this outline's existing sections — Foundation (Blocks 01–06, 237 entries), Domain Engines (07–11, 223), Workflows (12–13, 95), UX/Closeout (14–16, 199). Each agent extracted `FORMAL` hooks + `INFORMAL` body-text references + `DEFERRED-CONTRACT` mentions, returned structured JSON with verbatim source citations and within-section dedup. Outputs: `outputs/stage3_harvest_<section>.json` (754 raw entries total). **Pass 2 — Consolidation:** one `general-purpose` agent took the four harvests + decisions log + Scan Log, did cross-section dedup, applied re-categorization rules, swept for missed sub-docs in the decisions log / Scan Log, and produced one locked list. Output: `outputs/stage3_locked_subdocs.json` (676 entries before compression). **Pass 3 — Compression + pre-lock fixes (main thread):** reviewed the consolidated list, identified 27 merge clusters where 2–4 entries clearly cover one feature surface, added 6 pre-lock entries. Decision against the single-scan strategy that the prior HANDOFF recommended: 180+ source files exceed any sensible single-context window — the four-section split mirrored the proven Stage 2 per-block pattern.

**Findings.** 754 raw harvest entries → 676 after cross-section dedup + re-categorization + decisions-log/scan-log sweep → **634 locked** after compression + pre-lock additions. Distribution: Policies 157, Reference data 117, Schemas 110, UI specs 88, Runbooks 56, Tools 45, Integrations 34, Fixtures 21, Prompts 6. Zero `UNCATEGORIZED`. 80 sub-docs are cross-block (non-empty `co_owning_blocks`), including the canonical contracts pinned by the Stage 2 amendments — `permission_matrix`, `audit_event_taxonomy`, `step_up_validity_window_policy`, `tool_period_report_generator`, `archive_promotion_completed_event_integration`, `tool_clients_registry`, `tool_invoice_lifecycle_integration`, `internal_transfer_cross_workflow_dedup_policy`, plus the fixture-format / live-integration / cross-block-stitching / performance-budget testing scaffolds spanning 5–10 blocks each.

**Actions applied:**

- *Cross-section consolidation:* 80 cross-block sub-docs merged across the four section harvests; source citations concatenated, owning block set to the producer/registrar (per decisions-log ownership where explicit), co-owners listed.
- *Re-categorization:* 6 entries moved from `Policies` → `Prompts` after the Foundation agent mis-bucketed Block 06's prompt specs — `plain_language_pipeline_prompt` (Block 06), `tier_3_classifier_prompt` (Block 08), `extraction_prompt` (Block 09), `match_reason_prompt` (Block 10), `vat_treatment_explanation_prompt` (Block 11), `review_card_content_prompt` (Block 14). Other re-categorizations applied per the closed taxonomy: audit-event taxonomy / permission matrix / severity rule registry → `Reference data`; external-API contracts → `Integrations`; fixture corpora → `Fixtures`.
- *Decisions-log / Scan-log sweep:* 9 deferred contracts verified as already represented in the consolidated list, attached as additional `DEFERRED-CONTRACT` source citations on existing entries — specific local LLM model & runtime, cost-ceiling thresholds, retention dates per business, prompt test-corpus structure, `ARCHIVE_PROMOTION_COMPLETED` event, `report.generatePeriodReport` snapshot-input, both 2026-05-08 and 2026-05-09 permission-matrix decompositions, `clients_registry` IN-side resolver, `prepareInvoiceLifecycleEntries` dispatcher, `review_issues` schema reconciliation.
- *Compression — 27 merge clusters (−48 entries):* `legal_hold_policies` + `data_layer_conventions_policy` (Block 04); `audit_log_policies` (Block 05); `end_scan_policies` / `ai_cache_policies` / `prompt_management_policies` / `redaction_policies` (Block 06); `custom_tag_policies` (Block 08); `extraction_policies` (Block 09); `out_adjustment_policies` (Block 12); `pro_forma_policies` / `in_gate_policies` / `invoice_pdf_policies` / `invoice_schema_migrations` (Block 13); `rescan_policies` / `bulk_action_policies` / `bulk_action_schemas` (Block 14); `lock_sequence_policies` / `archive_bundle_policies` / `archive_manifest_schemas` (Block 15); `export_pipeline_policies` / `dashboard_card_policies` / `i18n_a11y_policies` / `dashboard_performance_policies` / `multi_business_view_policies` / `pdf_generation_policies` / `drill_down_schemas` (Block 16). Each merged entry preserves all mergee `source_citations` concatenated. Blocks 02, 03, 07, 10, 11 left at full granularity — their policies and schemas were each distinct surfaces that would over-flatten on merge.
- *Pre-lock additions (+6 entries):* `transaction_type_enum`, `match_level_enum`, `issue_group_enum`, `severity_enum` (closed-enum reference docs, parallel to the existing `vat_treatment_enum` for taxonomy consistency); `review_issues_schema` (Block 04, the canonical Block 04 Phase 04 table that didn't yet have a schema sub-doc despite every other major table having one; co-owner Block 14 per the 2026-05-08 amendment); `export_definitions_catalog` (Block 16, index over the 13 distributed export-format specs).

**Locked output.** `outputs/stage3_locked_subdocs.json` — 634 entries, sorted by category → owning_block → proposed_name for stable diff.

**Sign-off.** GO. Stage 3 cleared. The Stage 4 layered plan is recorded in `Docs/HANDOFF.md` (Layer 0 compression done; Layer 1 = ~80 cross-block contracts written solo; Layer 2 = per-section parallel delegation with per-block scans; Stage 4 final scan = canonical roadmap sign-off). **Sub-doc list locked.**

---

### Stage 2 — Block 16 phase scan — 2026-05-09 (FINAL Stage 2 scan)

**Scope.** Block 16 architecture doc + decisions log + 13 phase docs (the largest block in the project; backend export pipelines + PDF generators + analytics consumer AND a complete SaaS-quality UI/UX dashboard layer). Cross-block contract checks against Blocks 01, 02, 03, 04, 05, 11, 12, 13, 14, 15.

**Method.** Cross-read of all 14 in-block documents plus selective deep reads of Block 02 Phase 04 (canonical 9-surface permission matrix), Block 12 Phase 04 (`getCombinedRunProgress`), Block 14 Phase 02 / 09 (severity enum + mobile read-only), Block 15 Phase 04 / 05 / 06 (`report.generatePeriodReport` + `ARCHIVE_PROMOTION_COMPLETED` + `vies_export.csv` vs XML split), Block 13 Phase 11 (`v_invoices_with_adjustments`), and the 2026-05-08 amendments. Walked the 13-export catalogue, the 11-card severity rule registry, the closed taxonomies (severity, VAT treatments, transaction types), the audit-event taxonomy across five new domains, the SaaS-quality design system + component library, the cross-cache interaction (analytics MV cache + archive verification cache), the mobile read-only consumer contract, and the i18n / a11y / performance commitments.

**Findings.** **2 CRITICAL**, 8 HIGH, 9 MEDIUM, 5 LOW. The two criticals were a permission-matrix decomposition added unilaterally without a decisions-log amendment (parallel to the `ISSUE_RESOLVE` decomposition in 2026-05-08), and a `report.generatePeriodReport` snapshot-vs-live ambiguity in the cross-block contract pinned with Block 15. Sign-off recommendation: GO_WITH_FIXES.

**Fixes applied (all severities) — including two coordinated decisions-log amendments:**

- *Critical:* 2026-05-09 decisions-log amendment ratifies the permission-matrix decomposition: `REPORT_EXPORT` → `REPORT_EXPORT_BASIC` + `REPORT_EXPORT_FULL`; plus three new surfaces `DASHBOARD_VIEW`, `DASHBOARD_REFRESH_MANUAL`, `BUSINESS_SETTINGS_EDIT`. Same amendment pins the `report.generatePeriodReport({ workflow_run_id, period_snapshot }) → pdf_bytes` snapshot-input contract — the function consumes Block 15 Phase 04's lock-sequence step 1 snapshot, NOT raw DB state; resolves the live-vs-locked ambiguity and pins determinism.
- *High:* Phase 01 pins the `ARCHIVE_PROMOTION_COMPLETED` subscription mechanism via Block 05 Phase 02's `subscribeByEventType` hook + event-id dedup. Phase 06 pins `getCombinedRunProgress` consumer + separate `getRunActivePhase` fetch from Block 03 Phase 06 (and drops the hard-coded "11/8" phase numbers — the active sequence length is read dynamically). Phase 03 separates severity tokens from status tokens — `severity-success` renamed to `status-success` (severity tokens map ONLY to Block 14 Phase 02's four-value enum); Phases 04 / 05 / 06 references updated. Phase 06 / 09 / 10 / 11 cross-link to Block 11 Phase 05's canonical 8-VAT-treatment enum. Phase 11 adds Block 02 dependencies + pins `BUSINESS_SETTINGS_EDIT` permission for accountant-pack config edits. Phase 10 corrects PDF/A-1b → PDF/A-2a (or PDF/UA-1) for archive-bundle PDFs — PDF/A-1b doesn't support tagged structure trees and conflicts with the WCAG accessibility requirement. Phase 02 documents the cache-layer interaction (operational direct read; archive consults Block 15 Phase 07's pre-read verification cache; concurrent refresh + drill-down handled correctly).
- *Medium:* Phase 09 cross-links retention to Block 04 Phase 10's retention engine. Phase 01 schema extended with `sidebar_collapsed` + `drilldown_mode` columns. Phase 05's theme persists via `users.theme_preference` (Block 02 Phase 01 schema extension). Phase 12 enumerates the per-Block-16 mobile-write surfaces added to Block 14 Phase 09's rejection list. Phase 12 corrects refresh-now classification — treated as READ intent on mobile (allowed; not soft-prompted). Phase 06 pins missed-payment detection ownership to Block 08 Phase 03 (vendor memory side; cleaner than dashboard-side detection). Phase 09 strengthens export idempotency — data-change-aware (returns existing COMPLETED export when source data hasn't changed; `force_regenerate` opt-in for manual refresh). Phase 11 declares the manifest schema-evolution policy (additive backward-compatible; breaking changes bump `schema_version`).
- *Low:* Phase 03 adds extended display type scale sub-doc hook for PDF cover pages. Phase 02 cross-links the deferred per-business step-up policy to Block 02 Phase 06's `STEP_UP_REQUIRED` matrix flag. Phase 13 visual regression baseline extended with period-detail-with-manifest-chain + cross-business drill-down list + invoice-detail-with-adjustment-overlay (worst-case complexity pages). Phase 04 reconciles the component count language (deliverables list is the source of truth). Phase 07 mobile rule-name reference clarified.

**Sign-off.** GO. Block 16 cleared. **Stage 2 is complete — all 16 blocks decomposed and signed off.**

---

### Stage 2 — Block 15 phase scan — 2026-05-08

**Scope.** Block 15 architecture doc + decisions log + 10 phase docs. Cross-block contract checks against Blocks 01, 02, 03, 04, 05, 11, 12, 13, 14, 16.

**Method.** Delegated cross-read of all 11 in-block documents plus selective deep reads of Block 02 Phase 04 / 06 (permission surfaces + step-up runtime), Block 03 Phase 01 / 04 / 07 (`workflow_runs` schema, state machine, resumability), Block 04 Phase 04 / 07 / 09 / 10 (review_issues, archive zone, analytics rebuild trigger, retention engine), Block 05 Phase 02 / 03 (audit log + hash-chain), Block 11 Phase 06 / 07 (VIES contract, `prepareInvoiceLifecycleEntries`), Block 12 Phase 01 / 07 / 09 (`workflow_run_approvals`, approval method, OUT_ADJUSTMENT), Block 13 Phase 09 / 11 (IN HUMAN_REVIEW_HOLD, IN_ADJUSTMENT), Block 14 Phase 01 / 02 / 04 (severity enum, issue routing, resolution actions). Walked the 8-precondition gate library, the 8-step lock sequence, the 11-file bundle layout, the three immutability layers, the manifest-version chain, and the 13-row failure-mode taxonomy.

**Findings.** **2 CRITICAL**, 7 HIGH, 9 MEDIUM, 5 LOW. The two criticals were real cross-block contract gaps: the analytics rebuild trigger event (Block 15 didn't emit `ARCHIVE_PROMOTION_COMPLETED` that Block 04 Phase 09 subscribes to), and the `documents` table cross-block ownership reference. Sign-off recommendation: GO_WITH_FIXES.

**Fixes applied (all severities) — including five decisions-log amendments:**

- *Critical:* Phase 04 step 7 now emits BOTH `FINALIZATION_LOCK_COMMITTED` (Block-15-internal) AND `ARCHIVE_PROMOTION_COMPLETED` (the canonical cross-block trigger consumed by Block 04 Phase 09's analytics-rebuild subscriber + Block 16 dashboard refresh + any other archive consumer); the act of writing the audit event IS the analytics-enqueue mechanism (event-bus subscription model — no separate queue infrastructure). Phase 06's adjustment lock emits the same pair. Phase 04 step 8 collapsed (no separate enqueue step needed). Phase 04 step 2's `documents` table reference now pins canonical ownership in Block 09 Phase 01 with explicit column listing.
- *High:* Phase 03's `WORKFLOW_APPROVE` references corrected to `FINALIZATION` (the canonical Block 02 Phase 04 surface name). Phase 02 gate 8's `audit_log_quiescent` predicate pinned concretely (audit subsystem reachable + 5-second emission settle window for the run; chain integrity is Block 05 Phase 03's concern, not this gate's). Phase 04's audit-write atomicity decision pinned: step 7 runs as a SEPARATE short transaction (append-only hash-chain writes work best alone to avoid chain-head contention); crash-window between step 6 commit and step 7 write handled by Block 03 Phase 07 resumability + recovery emission. Phase 07's pre-read verification pinned to per-session-per-resource caching with 30-minute TTL (full re-hash on every read would be unusable at scale). Phase 01's "unique constraint with equality predicate" rewritten as a Postgres partial unique index. Phase 07's Layer 1 RLS now uses TWO mutually exclusive session variables (`app.original_lock_active`, `app.adjustment_lock_active`) for INSERT-gating across all four archive tables — distinguishes original-finalization writes from adjustment-driven writes.
- *Medium:* Phase 02 gate 6 now notes the architecture-doc "Zero BLOCKING" wording is narrower than the canonical post-2026-05-08-amendment `{HIGH, BLOCKING}` predicate; Phase 02 adopts the wider predicate for cross-block consistency. Phase 03 defers approval-staleness SQL ownership to Block 12 Phase 01 (table owner). Decisions log gains five amendments: (a) VIES export inside the bundle is CSV; the regulator-filed VIES is generated separately by Block 16; (b) `report.generatePeriodReport` cross-block contract pinned (Block 16 commits to deterministic, side-effect-free function); (c) `ARCHIVE_PROMOTION_COMPLETED` is the canonical cross-block trigger event; (d) lock-sequence audit emission as separate transaction; (e) per-bundle Object Lock storage model. Phase 07 `ARCHIVE_TAMPER_DETECTED` scoping clarified — business-wide blocking (a tamper alert against ANY package halts all new finalizations and adjustments for that business until Owner-level investigation). Phase 09 removed the invented `FINALIZATION_AUDIT_INTEGRITY_FAILURE` emergency-audit-bypass path (Block 05 hash-chain integrity is non-negotiable; persistent audit failure halts finalizations globally instead). Phase 09 added `manifest_version_collision` to the failure-mode taxonomy as TRANSIENT auto-retry (concurrent adjustment runs against the same parent). Phases 05 / 06 / 07 reconciled the storage model — each bundle is a separate zone object (`bundle_v1.zip`, `bundle_v2.zip`, ...), each independently Object-Locked; manifest files live INSIDE their respective zip bundles, not as separate zone objects.
- *Low:* Phase 01 removed the editorial suppressed `FINALIZATION_FILE_INDEXED` line (kept only the canonical `FINALIZATION_LEDGER_BULK_LOCKED` aggregate). Phase 07 `ARCHIVE_DATA_READ` aggregation pinned (per-session per-resource first-read; in-memory counter flushed at session-end as `ARCHIVE_DATA_READ_SESSION_SUMMARY`). Phase 08 added cross-link to Block 04 Phase 10 retention engine — per-bundle retention timestamps (whole package purgeable only when all bundles aged out). Phase 10 added `approval_step_up_window_expired_re_prompts` fixture for the 5-minute step-up validity window. Phase 06 manifest schema gained `evidence_inherited_from_versions` field for cross-version evidence dedup.

**Sign-off.** GO. Block 15 cleared; ready to start Block 16 phase decomposition (the final block).

---

### Stage 2 — Block 14 phase scan — 2026-05-08

**Scope.** Block 14 architecture doc + decisions log + 10 phase docs. Cross-block contract checks against Blocks 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 13, 15, 16.

**Method.** Delegated cross-read of all 11 in-block documents plus selective deep reads of Block 02 Phase 04 (permission matrix), Block 03 Phase 04/05 (state machine, gate audit events), Block 04 Phase 04 (canonical `review_issues` schema), and Block 12 Phases 05/06/07 + Block 13 Phase 09 (gate logic and HUMAN_REVIEW_HOLD pattern). Walked the four closed taxonomies (six issue_groups, four severity values, 13-action vocabulary, ten audit-event domain expectations), the issue_type registration mechanism, the snooze + cross-run carry-forward semantics, the bulk-action partial-success pattern, the re-scan-on-resolution affected-set scope, and the mobile-read-only constraint.

**Findings.** **3 CRITICAL**, 8 HIGH, 9 MEDIUM, 5 LOW. The three criticals were real cross-block coordination gaps: the Block 14 phase docs invented column names that didn't match Block 04 Phase 04 (the canonical `review_issues` owner — the `notes` vs `resolution_note` rename and `SNOOZED` status drift were the most consequential); permission surfaces were unilaterally declared without a Block 02 Phase 04 amendment; and `generateAndPersistCardContent` / `revalidateIssue` were declared as cross-block APIs that producing blocks hadn't agreed to expose. Sign-off recommendation: GO_WITH_FIXES.

**Fixes applied (all severities) — including three coordinated cross-block edits and a four-amendment decisions-log entry:**

- *Critical:* Block 04 Phase 04 amended canonically to add the `card_payload_json` / `card_content_*` / `assignment_notification_sent_at` / `snoozed_at` / `snoozed_by` / `auto_resolution_trigger_issue_id` columns and extend the status enum with `AUTO_RESOLVED_BY_RESCAN`; the existing `SNOOZED` value is preserved and Block 14 phases align to use it (snooze sets `status = SNOOZED`, not `status = OPEN`). Block 14 Phase 01 reframed to consume canonical column names (`resolution_note`, not `notes`). Block 02 Phase 04's `ISSUE_RESOLVE` surface decomposed into `REVIEW_QUEUE_VIEW` / `REVIEW_QUEUE_RESOLVE` / `REVIEW_ASSIGN` / `REVIEW_REGENERATE` per the decisions-log amendment; the role table's "Reviewer resolves issues = yes" contradiction resolved (Reviewer gets VIEW only, not RESOLVE). `generateAndPersistCardContent` and `revalidateIssue` reframed as Block 14-INTERNAL helpers (no producing-block helpers required) — the helper reads producing-block state by FK at issue-creation time; per-`issue_type` validity-check functions are registered in Block 14's `issue_type_registry` (a new table declared in Phase 01).
- *High:* Phase 04 / 05 / 08 / 10 corrected the run-state references — `HUMAN_REVIEW_HOLD` ↔ `AWAITING_APPROVAL` (canonical per Block 12 Phase 07 / Block 13 Phase 09); `MANUAL_UPLOAD_HOLD` ↔ `REVIEW_HOLD` is the distinct OUT-only path. Block 12 Phase 07 SQL drift `('HIGH', 'CRITICAL')` → `('HIGH', 'BLOCKING')` finally landed (the prior 2026-05-08 amendment had been ratified but not implemented). Phase 04's `Mark as no invoice available` scoped to OUT-only; IN-side has no analog; the resolution path on IN-side is reclassification or invoice creation, not exception. Phase 02's routing table reframed as illustrative (the canonical exhaustive table is the sub-doc artifact assembled from each producing block's `registerIssueType` calls); namespacing convention pinned (`<block_short_name>.<check_name>`). Phase 02's "six buckets" decomposed into five actionable enum values + one `Ready to Finalize` queue-state projection (NOT a row value); Block 04 Phase 04's ENUM constraint reduced to five. Phase 02 `Ready to Finalize` rendering wires to the per-workflow `user_approval` tools (not Block 15 directly). Phase 07's unsnooze pre-execution-hook anchored as `review_queue.unsnooze_at_run_start` registered as the first tool of the first phase of every run (no Block 03 Phase 06 special hook needed).
- *Medium:* Phase 02's `classification.unknown_type` severity raised from `HIGH` to `BLOCKING` (architecture line 82 specifies `UNKNOWN`-classified as a canonical BLOCKING case). Phase 03's `card_payload_json.expand_pointer` clarified to be live FK pointers, not snapshot copies — frozen-vs-live boundary pinned (user-facing text frozen; technical-detail expand resolves live). Phase 01 declares `REVIEW_REGENERATE` permission surface for Phase 03's manual regenerate flow. Phase 03's fallback follow-up issues now coalesce by `(primary_issue_id, failure_category)` to avoid retry-storm audit volume. Phase 04 / 08 align with Block 03 Phase 05's standard gate audit events (`WORKFLOW_GATE_PASSED` / `_HOLD` / `_ROUTED_TO_SIDE_PHASE`); the made-up `WORKFLOW_GATE_REEVALUATION_REQUESTED` event removed. Phase 06's notification-failure issue-class made special: deterministic content (no AI), auto-routes to all Owners via in-app inbox only (no email, which just failed), no recursive assignment. Phase 04 documents the Accountant + WORKFLOW_TRIGGER conflict explicitly: an Accountant assigned via Send-to-accountant cannot resolve via `Mark as no invoice available`; the intended flow is reassignment back. Phase 03 pins the boundary with Block 10 Phase 07 / Block 11 Phase 05 plain-language fields — Block 14's card text is frozen, producing-block fields can regenerate, the two intentionally drift. Phase 01 declares `bulk_preview_tokens` and `issue_type_registry` tables (closing the storage gaps).
- *Low:* Phase 06's `REVIEW_ASSIGNMENT_NOTIFICATION_SENT` consolidated into a single `REVIEW_ASSIGNMENT_NOTIFICATION_DISPATCHED` event with channel-success payload. Phase 03's `recommended_action` cap raised from 60 to 120 chars to fit contextualized recommendations. Phase 10 fixture `severity_critical_drift_lint_check` added — repo-wide scan asserts no phase doc references the dropped `CRITICAL` severity. Phase 09 enumerates the explicit desktop-only tool names (`out_workflow.user_approval` / `_revoke_approval`, `in_workflow.user_approval` / `_revoke_approval`, `out_workflow.start_run_manually`, `in_workflow.start_run_manually`, `out_workflow.adjustment_intake`, `in_workflow.adjustment_intake`).

**Sign-off.** GO. Block 14 cleared; ready to start Block 15 phase decomposition.

---

### Stage 2 — Block 13 phase scan — 2026-05-08

**Scope.** Block 13 architecture doc + decisions log + 12 phase docs (the largest block — Invoice Generator + `IN_MONTHLY` + `IN_ADJUSTMENT`). Cross-block contract checks against Blocks 01, 03, 04, 05, 06, 07, 08, 09, 10, 11, 12, 14, 15, 16.

**Method.** Delegated cross-read of all 13 in-block documents plus selective deep reads of Block 10 Phase 08 (IN matching variant), Block 11 Phases 04 / 07 / 09, Block 12 Phases 01 / 03 / 04 / 07 / 09. Walked the 10-state lifecycle, the seven IN-side outcomes, the `INV` / `CN` / `PRO` numbering trio, the eight VAT treatments, the audit-event taxonomy across six new domains, the two-sub-system structure (Invoice Generator + workflow), and the OUT/IN parallel-coordination contracts.

**Findings.** **3 CRITICAL**, 8 HIGH, 9 MEDIUM, 6 LOW. The three criticals were real cross-block coordination gaps (bad-debt-expense ledger path didn't exist in Block 11 Phase 07; Block 11 Phase 04's resolution chain had no IN-side `clients` registry branch; Phase 09's severity enum drifted from Block 14's canonical taxonomy — same drift previously inherited by Block 12 Phase 07). Sign-off recommendation: GO_WITH_FIXES.

**Fixes applied (all severities) — including three coordinated cross-block edits:**

- *Critical:* Block 11 Phase 07 amended to add a top-level `prepareInvoiceLifecycleEntries` dispatcher path (registered as `ledger.prepare_invoice_lifecycle_entries`) covering lifecycle-driven entries that have no source transaction; Stage 1 case = `WRITTEN_OFF` → bad-debt expense (debit Bad Debts, credit Trade Debtors). Block 11 Phase 04 amended to add Step 1.5 (`CLIENTS_REGISTRY` source) ahead of vendor memory for IN-side runs; the `getClientByName` and `getClientByVatNumber` helpers exposed by Block 13 Phase 02 are the canonical lookup. Severity enum fixed to `{HIGH, BLOCKING}` (Block 14's canonical) across Block 13 Phase 09 AND back-ported to Block 12 Phase 05 + Phase 07. Decisions-log amendment ratifies all three fixes plus the `PRO-YYYY-NNNN` separate sequence (H2).
- *High:* Phase 01 lifecycle enum extended to 11 values (`CONVERTED_TO_TAX_INVOICE` added); Phase 03 declares the named function `invoice.markConvertedToTaxInvoice`; the audit event renamed from `INVOICE_CONVERTED_TO_TAX_INVOICE` to `INVOICE_PRO_FORMA_CONVERTED_TO_TAX` to disambiguate from the lifecycle-status value. Phase 03 declares the two valid exits from `OVERPAID` (`REFUNDED` via refund match, `CREDITED` via credit note) plus the FINALIZED carry-forward path. Phase 01 declares a cross-block schema migration on `match_records` adding `invoice_id` (nullable, mutually exclusive with `document_id`) and `income_outcome` (the seven-value IN-side outcome enum) to align with Block 04 Phase 03's six-value `match_status`. Phase 01 declares the cumulative-credit-cap row-locking invariant (`SELECT … FOR UPDATE` on the source invoice + cumulative-sum check inside one transaction) closing the credit-note race condition. Phase 11 declares the `v_invoices_with_adjustments` read-only Postgres view that overlays adjustment-driven retroactive states (e.g., a finalized invoice surfaced as `WRITTEN_OFF`) without modifying the base `invoices` row. Phase 09's gate logic reframed — `gate.in.income_matching_complete` HOLDs on `MULTIPLE_INVOICES_ONE_PAYMENT` AND `POSSIBLE_REFUND_OR_TRANSFER` (closes the silent-misclassification path), advances on `NO_MATCH` (HIGH issue blocks at HUMAN_REVIEW_HOLD).
- *Medium:* Phase 10 pins `effective_match_status` as OUT-only (Stage 1) — the IN side reads `match_records.income_outcome` instead. Phase 09 declares the `in_workflow.finalize_period_invoices` tool that bulk-fires `invoice.markFinalized` near the end of `FINALIZATION` (closes the gap where Block 15's lock sequence didn't fire it). Phase 08 collapses per-row `IN_FILTER_INCLUDED_TRANSACTION` events into a single `IN_FILTER_RAN` aggregate event for audit-volume containment. Phase 07's `IN_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED` use case clarified (covers never-finalized old periods; not redundant with Phase 11's adjustment-side event). Phase 05 declares pro-forma expiry policy (`pro_forma_expires_at`; default 30 days; new `EXPIRED_UNCONVERTED` lifecycle state) closing the ghost-pro-forma accumulation problem. Phase 11 moves the Cyprus VAT-period-assignment dual-date rule (current-year `CN` number + historical-period accounting impact) from DoD into the body. Phase 10 adds `invoice_type = TAX` enforcement to the allocation invariant (defense in depth alongside the candidate-set filter). Phase 04 rejects `IMPORT_OR_ACQUISITION` on FINAL render (the treatment is OUT-side only); new audit event `INVOICE_PDF_RENDER_REJECTED_INAPPLICABLE_VAT_TREATMENT`.
- *Low:* The "`IN_MONTHLY` does not invoke Block 09" rule consolidated into Phase 07 as canonical; Phase 12 references it. Phase 11 declares the combined `delta_kind` enum (8 values across OUT + IN) with a CHECK constraint scoping kinds to the right workflow type. Phase 03 enumerates the six `allocation_kind` enum values explicitly (closing the `OVERPAYMENT_PRIMARY` / `OVERPAYMENT_SURPLUS` ambiguity). Phase 01 adds the canonical no-op statement: number allocation fires once at first transition out of `DRAFT`. Phase 12's fixture pass/fail audit events removed (repo-governance, not runtime audit — same fix Block 09 Phase 10's prior scan established).

**Sign-off.** GO. Block 13 cleared; ready to start Block 14 phase decomposition.

---

### Stage 2 — Block 12 phase scan — 2026-05-08

**Scope.** Block 12 architecture doc + decisions log + 10 phase docs. Cross-block contract checks against Blocks 01, 03, 04, 06, 07, 08, 09, 10, 11, 13, 14, 15, 16.

**Method.** Delegated cross-read of all 11 Block 12 documents plus selective reads of Block 03 Phases 01/04/07/09/10/11, Block 04 Phase 03 (`match_status` enum) and Phase 10 (retention), Block 11 Phase 09 (LEDGER_PREPARATION consolidation), and the Block 14 / 15 / 16 architecture docs. Checked phase ordering, schema coherence, the 11-vs-12 phase consolidation, the closed 12-type taxonomy, the `EXCEPTION_DOCUMENTED` enum addition, the eight registered tools' side-effect / AI-tier contracts, audit-event taxonomy, cross-block durable contracts (`STATEMENT_UPLOAD_COMPLETED`, `paired_run_id`, `LEDGER_PREPARATION`, `FINALIZATION`, `INTERNAL_TRANSFER` single-writer), gate determinism, MANUAL_UPLOAD_HOLD reminder semantics, HUMAN_REVIEW_HOLD approval semantics, trigger idempotency vs Block 03 Phase 07 / 09, OUT_ADJUSTMENT additive-only enforcement and concurrency, per-business config short-circuits, failure paths, Stage 1 decision alignment, scope coverage and leak.

**Findings.** **1 CRITICAL**, 7 HIGH, 8 MEDIUM, 5 LOW. The critical was a missing schema column (`workflow_runs.paired_run_id`) consumed by Phase 04 / Phase 08 / dashboard but never declared. Sign-off recommendation: GO_WITH_FIXES.

**Fixes applied (all severities):**

- *Critical:* Phase 01 now declares the `workflow_runs` schema migration adding `paired_run_id` (self-referential FK, nullable), `trigger_kind` (`MANUAL` / `EVENT`), `triggered_by_user_id`, `triggered_by_event_id`, `manual_trigger_note` — flagged as Block 03 Phase 01 sub-doc-stage migration. Phase 01 also takes ownership of the `workflow_run_approvals` and `adjustment_records` tables previously declared inline in Phases 07 / 09 (M4 / M5 same root cause).
- *High:* Phase 02 now adds a downstream-consumer guidance section pinning the 11-vs-12 phase mental-model: Block 14 / Block 16 must query `LEDGER_PREPARATION` only — there is no `VAT_CLASSIFICATION_PHASE_*` event series. Phase 06 now pins `EXCEPTION_DOCUMENTED` storage shape — the new value lives on `transactions.effective_match_status` (a new denormalized column) and never on `match_records`; Block 04 Phase 03's per-pair enum and unique constraint are unaffected. Phase 04 corrects "OUT_MONTHLY ↔ OUT_ADJUSTMENT for the same period" claim — impossible by construction (a finalized period blocks new monthly runs); the Stage 1 concurrency rule applies to different periods only. Phase 06 corrects `out_workflow.upload_invoice` AI tier from `EXTERNAL_LLM` to `NONE` (the wrapper itself is `NONE`; only the downstream `intake.ocr_and_extract` carries the tier — matches Block 09 Phase 09's pattern). Phase 09 consolidates `OUT_ADJUSTMENT` from the architecture-doc 6-phase mental model to the registered 5-phase sequence (`ADJUSTMENT_LEDGER_PREP` covers both ledger and VAT, parallel to Phase 02's monthly consolidation). Phase 08 reframes trigger dedup to use Block 03's existing primitives — manual triggers use Phase 10's per-business concurrency lock; event triggers use Phase 09's `event_id`-based replay protection — no separate composite key. Phase 06 pins `out_workflow.document_exception` storage shape — exception is transaction-bound, written to `transactions.effective_match_status`, no synthetic `match_records` row; reversible if a matching invoice arrives later.
- *Medium:* Phase 06 pins reminder cadence as **entry-anchored** (within-phase activity does not reset; reminder N fires at `entry_time + N × cadence_days`). Phase 05's `gate.out.matching_complete` now reads `effective_match_status` (the single mechanism) and accepts `EXCEPTION_DOCUMENTED` as a clear state alongside `MATCHED_AUTO_HIGH_CONFIDENCE` / `MATCHED_CONFIRMED`. Phase 03's filter-decision schema split per-direction (`out_filter_decided_at` / `_by_run_id` and parallel IN columns) — drops the multi-valued claim. Phase 02 now documents the audit-event domain split (`OUT_WORKFLOW` vs `OUT_ADJUSTMENT`). Phase 07 + Phase 08 defer to Block 02 Phase 04 permission surfaces (`WORKFLOW_APPROVE`, `WORKFLOW_TRIGGER`) instead of inline role enumeration. Phase 02 + Phase 03 split `LOAN_OR_SHAREHOLDER_MOVEMENT` per direction — OUT direction (loan disbursement, capital return) routes to OUT_FILTER; IN direction (capital injection, loan receipt) routes to IN_FILTER (Block 13).
- *Low:* Phase 02 "12 phases" wording corrected to "11 registered positions." `OUT_WORKFLOW_TYPE_REGISTERED` event ownership consolidated to Phase 01 only. Phase 10 fixture set extended with `out_monthly_re_enters_manual_upload_hold_after_recompute` for the re-entry path. Phase 09 `delta_kind = OTHER` semantics pinned — always sets `requires_accountant_review = true` and makes ADJUSTMENT_HUMAN_REVIEW mandatory. Phase 07 pins the snoozed-issue carry-forward boundary — finalized archive captures the resolved-or-snoozed-or-open state at finalization moment; snoozed issues reappear at the next monthly run; non-snoozed informational issues stay in the archive only.

**Sign-off.** GO. Block 12 cleared; ready to start Block 13 phase decomposition.

---

### Stage 2 — Block 11 phase scan — 2026-05-08

**Scope.** Block 11 architecture doc + decisions log + 10 phase docs.

**Method.** Delegated cross-read of all 12 documents. Checked phase ordering, schema coherence across phases, the eight-VAT-treatment closed taxonomy, the 12-transaction-type closed taxonomy, all 11 compliance fields populated and exit-gate-validated, side-effect contracts vs Block 08 / Block 10 patterns, audit-event taxonomy under `<DOMAIN>_<PAST_VERB>` naming, cross-block durable contracts (Block 12/13/15/16 consumers), AI compliance with Principle 3 (rules decide, AI explains only), failure paths, chart-version-pin replay invariant, reverse-charge book-keeping coupling, VIES export contract, multi-line invoice consolidation, manual-override semantics, review-issue bucket alignment with Block 14, all six Stage 1 decisions and both deferred items, scope coverage and leak.

**Findings.** **2 CRITICAL**, 7 HIGH, 8 MEDIUM, 5 LOW. The two criticals were a real architectural gap (multi-version-per-period freeze contract was undefined when chart customizations happened mid-period) and an exit-gate vs Phase 04 UNRESOLVED-counterparty inconsistency that would have prevented LEDGER_PREPARATION from ever exiting cleanly when even one counterparty was unresolved. Sign-off recommendation: GO_WITH_FIXES.

**Fixes applied (all severities):**

- *Critical:* Phase 03 now declares the pre-finalization invariant — every `draft_ledger_entries` row in a period must share a single `chart_mapping_version_id` before Block 15 sees it; Phase 09's pre-exit recompute pass replays Phase 07's dispatcher for any rows pinned to stale versions. Phase 09's exit-gate clause rewritten with canonical nullability rules — `counterparty_*` may be null when `vat_treatment ∈ {OUTSIDE_SCOPE, UNKNOWN}` (covers Phase 04's UNRESOLVED branch); other nullable fields per Phase 01 schema annotations are explicitly enumerated.
- *High:* Phase 09's tool sequence reordered — `resolve_counterparty → classify_vat → compute_reverse_charge_vies` now run as in-memory READ_ONLY proposers; `prepare_entries` is the single creator of `draft_ledger_entries` rows with all VAT decisions already in hand; `compute_vat_and_evidence_flags` (renamed) and `flag_for_review` enrich the persisted rows. The proposer + single-writer pattern aligns with Block 08 Phase 09's shape. Phase 05 now declares an explicit manual-override pre-check that short-circuits to the override `vat_treatment` and emits `LEDGER_VAT_TREATMENT_HONORED_MANUAL_OVERRIDE`. Phase 01 schema extended to declare every column referenced downstream — `vat_treatment_explanation`, `entry_currency_original` / `entry_amount_original`, `manual_override_*` fields, `vies_period`, `vies_value_basis_eur`. Phase 05 IN-3 clarified — `NON_EU_SERVICE` is zero-rated export of services for Cyprus VAT (reportable on the VAT return, not VIES); distinct from `OUTSIDE_SCOPE`. Phase 05 IN-2 tightened — missing-or-invalid client VAT number on EU IN-side routes to `UNKNOWN` rather than producing an EU_REVERSE_CHARGE entry that Phase 06 would have to flag as VIES-irrelevant. Phase 06 dropped `vies_value_basis` from its return shape; Phase 08 owns that population (the field comes after VAT amount derivation). Phase 08 now declares the canonical VAT-amount placement rule for paired entries — domestic-VAT amounts live on PRIMARY; reverse-charge amounts live on the `VAT_RECLAIM` / `VAT_OUTPUT` derived rows; PRIMARY is zero in those cases, ensuring no double-counting at the report level.
- *Medium:* `LEDGER_DRAFT_ENTRY_REVIEW_FLAGGED` (Phase 01) renamed to `LEDGER_ACCOUNTANT_REVIEW_FLAGGED` to match Phase 08's emission. Phase 08 amount table footnoted with derived-entry inheritance rule (`FX_DELTA` and `ROUNDING` carry zero VAT amounts; their PRIMARY-side rows hold any actual figures). Phase 04's stray "Phase 11" reference fixed to "this phase". Phase 08 footnoted with credit-note evidence handling — credit notes route through `REFUND_OUT` / `REFUND_IN`, the credit-note number is the matched evidence; sub-doc tracks the Block 13 contract. Phase 06 "Out of scope" extended with non-EUR-bookkeeping note. The tool name changed from `ledger.compute_vat_amounts` to `ledger.compute_vat_and_evidence_flags` to reflect the unified responsibility. Phase 02 dependency list adds Phase 05 as the read-only canonical source for the eight-treatment enum. Phase 09 audit-events list now enumerates per-tool emissions explicitly so the `EXTERNAL_LLM` tool's audit visibility is unambiguous.
- *Low:* Phase 01 `entry_kind` description revised — multiple PRIMARY entries are valid (FX_EXCHANGE legs, multi-line splits) and not blocked by any DB constraint. `LEDGER_PHASE_HOLDING` trigger explicitly defined as Block-03-state-machine-driven (held-pending-classification entries don't fire it). Phase 10 fixture `vat_unknown_unresolved_country` extended to verify `LEDGER_COUNTERPARTY_UNRESOLVED` + `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED` + `LEDGER_ACCOUNTANT_REVIEW_FLAGGED` audit events. VAT rate-table sub-doc cross-referenced as shared between Phase 05 and Phase 08 (single Stage 4 sub-doc, not two). L1 (equity-vs-loan account placement) verified pass — no fix needed.

**Sign-off.** GO. Block 11 cleared; ready to start Block 12 phase decomposition.

---

### Stage 2 — Block 10 phase scan — 2026-05-08

**Scope.** Block 10 architecture doc + decisions log + 10 phase docs.

**Method.** Delegated cross-read of all 12 documents. Checked phase ordering, the cross-product `(transactions × documents)` candidate-set semantics, scoring engine signals coherence vs Block 08's vendor-memory tiers, auto-confirm rule symmetry with Block 08 Phase 07, split-payment combinatorial bounds, duplicate-detection ownership boundary against Block 07/Block 09, rejection-memory pair-scoping rules, IN-side outcome contract against Block 13's lifecycle, side-effect contracts vs Block 08 Phase 09's READ_ONLY-proposer pattern, audit-event naming convention, plain-language fallback semantics, fixture coverage, Stage 1 decision alignment.

**Findings.** **2 CRITICAL**, 5 HIGH, 6 MEDIUM, 5 LOW. The two criticals were a side-effect contract drift (all five Phase 09 tools declared `WRITES_RUN_STATE` rather than the proposer + single-writer split that Block 08 Phase 09 used), and a pro-forma filter assuming a Block 13 `Invoice` schema field that hasn't been pinned. Sign-off recommendation: GO_WITH_FIXES.

**Fixes applied (all severities):**

- *Critical:* Phase 09 now carries a documented rationale for the side-effect deviation — matching is per-pair with no aggregate write step, so each tool is inherently a writer; replay/idempotency is preserved by the unique constraint on `(transaction_id, document_id)` plus rejection-memory suppression. Phase 08 pins a durable cross-block contract: Block 13's `Invoice` schema must expose either `invoice_type ∈ {PRO_FORMA, TAX}` (preferred) or `is_pro_forma` for the pro-forma filter to work; INCOME_MATCHING wiring is gated on this contract being honored.
- *High:* Phase 08 gains an Outcome → lifecycle call mapping table (`invoice.markPaid`, `invoice.markPartiallyPaid`, `invoice.markOverpaid`) labeled as the durable cross-block contract — Block 13 must register exactly these function names. A new `INVOICE_LIFECYCLE_TRANSITION_FAILED` audit event covers the lifecycle-error path. Phase 08 candidate-set status filter justified — `OVERPAID` kept eligible for the refund-then-repayment edge case; `PAYMENT_EXPECTED` distinguished from `SENT` by the explicit reminder cycle. Phase 02 cross-period asymmetric ±60/+30 window now justified — net-30/net-60 invoices commonly trail payment by 30–60 days; invoices issued *after* payment are rare and adequately covered by +30. Phase 10 fixture set extended with `cross_period_invoice_after_transaction_within_window` and `cross_period_invoice_after_transaction_outside_window` to lock in the asymmetric-window behaviour. Phase 07 gains a dedicated Failure handling section mirroring Phase 09's fallback semantics — deterministic structured-fallback string, full `match_signals` retained, `MATCHING_REASON_FALLBACK_APPLIED` event, LOW review issue.
- *Medium:* Audit events normalised to the `<DOMAIN>_<PAST_VERB>` convention across all 10 phases — `MATCH_*` → `MATCHING_*`, IN-side `INCOME_MATCH_*` → `INCOME_MATCHING_*`. Phase 05's Pattern A split-payment-group exclusion sharpened — only `PROPOSED` and `CONFIRMED` groups confer the exclusion; `REJECTED` does not. Phase 03's `recurring_vendor_signal ≥ 0.88` cutoff source-of-truth pinned to Block 08 Phase 03's high-tier value; Stage 4 sub-doc tracks the move to a symbolic tier reference. Phase 03 vendor-memory increment helper now carries a `source` field (`matching.auto_confirm`, `matching.user_confirm`, `classification.auto_confirm`) keyed for idempotency to prevent dual-source double-counting. Phase 08 IN-side split-payment candidate set specified — same status filter as the single-pair case, narrowed by client identity, currency, and ±60-day proximity; same 20-candidate / 5-constituent bounds. Phase 03's Block 14 reference reframed as a downstream consumer (not a dependency) — review-issues writes go via Block 04's table contract.
- *Low:* Phase 01 audit list clarifies that `SPLIT_PAYMENT_GROUP_STATUS_CHANGED` is the generic fallback emitted only when no named transition fits — the named events (`SPLIT_PAYMENT_GROUP_CONFIRMED`, `SPLIT_PAYMENT_GROUP_REJECTED`) take precedence and a single transition emits exactly one event. Phase 06 privileged override scoped to Owner only (Admin denied); rationale recorded. Phase 02 Level 1 date proximity widening note added — `≥ 0.7` (±10 days) reflects real settlement gaps and prevents review-queue overflow. Phase 10 fixture `rejection_privileged_override` added for the Owner override + step-up + Admin-denied path. Phase 09 INCOME_MATCHING phase definition now explicitly sequences `matching.detect_duplicates` at exit gate (parity with `MATCHING`).

**Sign-off.** GO. Block 10 cleared; ready to start Block 11 phase decomposition.

---

### Stage 2 — Block 09 phase scan — 2026-05-07

**Scope.** Block 09 architecture doc + decisions log + 10 phase docs.

**Method.** Delegated cross-read of all 12 documents. Checked phase ordering, OCR-vs-extraction layer naming coherence, hard-coded phase-index references in Block 12, manual-stub state-transition contract, cross-source dedup invocation timing vs Phase 09's tool sequence, OCR + extraction tool combination side-effects, partial template match handling, Stage 1 decision alignment, scope coverage and leak.

**Findings.** **2 CRITICAL**, 4 HIGH, 6 MEDIUM, 2 LOW. The criticals were a real architectural drift: Phase 03's OCR output mislabeled as `DETERMINISTIC` (which would have collided with Phase 04's canonical layer taxonomy), and Phase 09's hard-coded "phases 4 and 5 of OUT_MONTHLY" before Block 12 has been decomposed.

**Fixes applied (all severities):**

- *Critical:* Phase 03 always writes `extraction_layer = 'TIER3_AI'` for Document AI output (it's a Tier 3 external API call); `DETERMINISTIC` is reserved exclusively for Phase 04 Layer 1's regex/template matching. Phase 09 phase indices in Block 12 softened — `EVIDENCE_DISCOVERY_EMAIL` and `EVIDENCE_DISCOVERY_DRIVE` are the durable contract; integer indices resolve at Block 12 decomposition.
- *High:* Cross-source dedup placement reconciled — Phase 09 now sequences `intake.cross_source_dedupe` BEFORE `intake.ocr_and_extract` in both phases, so the second-source case skips OCR (matching Phase 08's "skip OCR — already run" contract). Phase 07 manual-upload state-transition wording rewritten to match Phase 02's transitions cleanly. Phase 09 `intake.ocr_and_extract` side-effect corrected to `WRITES_RUN_STATE` (it writes `documents.extracted_fields_json` and triggers state transitions). Phase 04 partial template match handling specified — partial matches don't persist a Layer 1 row but pass matched fields as a hint to Layer 2; the final row records the layer that produced the complete output.
- *Medium:* Phase 09 Block 13 reference re-labeled as a forward note (Block 13 is NOT a consumer). Phase 09 `intake.manual_upload_handler` AI tier corrected to `NONE` (the AI calls happen in the downstream `intake.ocr_and_extract`, which carries the tier declaration). `EVIDENCE_DISCOVERY_DRIVE` now runs for every OUT_EXPENSE (not only those without email candidates), so cross-source corroboration is reachable. `DOCUMENT_FORMAT_UNSUPPORTED` renamed `DOCUMENT_FORMAT_REJECTED_UNSUPPORTED` per the past-verb convention. Phase 07 clarifies that `add explanation note` is not a stub but a comment on a still-open issue. Phase 10's `INTAKE_FIXTURE_REMOVED` event removed — fixture removal is a repo-governance concern, not a runtime audit.
- *Low:* Phase 02 clarifies `DISMISSED` is terminal; Phase 01's `document_source_links.id` annotated as UUID v7 for consistency.

**Sign-off.** GO. Block 09 cleared; ready to start Block 10 phase decomposition.

---

### Stage 2 — Block 08 phase scan — 2026-05-07

**Scope.** Block 08 architecture doc + decisions log + 10 phase docs.

**Method.** Delegated cross-read of all 12 documents. Checked phase ordering, the three-layer classifier coherence (Phase 02/03/04 layer-skip semantics + Phase 07 confidence merge), tool side-effect contracts vs claimed transaction-table writes, AI tier declarations vs Block 06's tier model, issue-group bucket consistency vs Block 14's six buckets, snapshot vs custom-tag interactions, Stage 1 decision alignment, scope coverage and leak.

**Findings.** **3 CRITICAL**, 5 HIGH, 6 MEDIUM, 3 LOW. The criticals were a real contract-drift between Phase 09's tool registrations and Phase 02/03's claimed writes, plus a Phase 09 AI-tier mislabel that would have broken Block 06's gateway authorization for Tier 3 calls, and a "retries" wording that implied silent escalation in violation of Block 06 Phase 01.

**Fixes applied (all severities):**

- *Critical:* Phase 02 outputs reframed as in-memory `Layer1Result` only; the actual `transactions` writes are owned by Phase 09's `assign_status` tool. Phase 03 same — `Layer2Result` in memory; vendor-memory `confirmations_count` increments at confirmation time, not lookup time. Phase 09 `apply_layer3` AI tier corrected to `EXTERNAL_LLM` (the maximum tier the tool can reach, so the gateway's cost ceiling and redaction scope cover both Tier 2 and the explicit Tier 3 escalation). Phase 09 "retries" wording rewritten to make explicit that Tier 2 → Tier 3 is two distinct gateway invocations per Block 06 Phase 01.
- *High:* Phase 03 entry rule corrected — Layer 2 runs **always** (regardless of Layer 1's outcome) so Phase 07's L1+L2 agreement boost is reachable; the only suppression is a Layer 1 `rule_conflict`. Phase 02 `rule_conflict` issue group changed from `'Needs Confirmation'` to `'Possible Wrong Match'` (a configuration problem, not a low-confidence one). Phase 09 entry gate adds the snapshot-freshness rule for re-entry cases. Phase 01 declares the explicit `classification_method` enum values (`RULE`, `VENDOR_MEMORY`, `AI_FALLBACK`, `NO_AI_AVAILABLE`, `MANUAL`).
- *Medium:* Phase 04 documents that Block 06's `AI_GATEWAY_INVOKED` event is emitted independently of Block 08's `AI_CLASSIFICATION_*` events. Phase 02's `CLASSIFICATION_RULES_NO_MATCH` renamed to singular `CLASSIFICATION_RULE_NO_MATCH` for symmetry. Phase 08 cross-references Phase 06's `(retired)` marker — that marker only applies to vendor-memory references, not in-run rendering. Phase 09 `apply_layer3` side-effect softened to `READ_ONLY` from the tool's perspective (the gateway writes `ai_usage_records`). Phase 10 fixture format adds `prior_finalized_runs.json` for cross-run fixtures. Phase 06 sub-doc hook added for `UNKNOWN`-mapping UX guidance.
- *Low:* Phase 02 references the seeded supplier/client registries with a forward note. Phase 09 AI-tier enum confirmed against Block 06 Phase 01's canonical values.

**Sign-off.** GO. Block 08 cleared; ready to start Block 09 phase decomposition.

---

### Stage 2 — Block 07 phase scan — 2026-05-07

**Scope.** Block 07 architecture doc + decisions log + 10 phase docs.

**Method.** Delegated cross-read of all 12 documents. Checked phase ordering, the intake-vs-workflow boundary (Phase 01 vs the workflow engine's INGESTION phase ownership), status-transition ownership across Phases 01/02/05/06/07, cross-phase coherence (parser → normalize → dedupe → evidence), Stage 1 decision alignment, sub-doc hooks, audit-event taxonomy, scope coverage and leak, AI-tier coherence with Block 06.

**Findings.** **2 CRITICAL**, 6 HIGH, 7 MEDIUM, 5 LOW. The two criticals were a real architectural drift: Phase 01's "Hands off to the parser" wording contradicted the workflow-engine-owns-INGESTION pattern from Phase 07 and Block 01 Principle 1. Cascading status-transition ownership ambiguity in Phase 02 followed the same drift.

**Fixes applied (all severities) — including a small cross-block clarification:**

- *Critical:* Phase 01 reframed: it ends at status `UPLOADED`, emits `STATEMENT_UPLOAD_COMPLETED`, and never invokes the parser directly — the workflow engine's INGESTION phase (Phase 07) owns every subsequent transition. Phase 02 reframed: parser is invoked by the workflow engine (Block 03 Phase 06), not by Phase 01.
- *High:* `STATEMENT_UPLOAD_COMPLETED` declared as a single shared event (Phase 01 emits, Block 03 Phase 09 consumes — same name, same event). Phase 04 declared as `READ_ONLY` for the normalize tool — the actual insert into `transactions` is owned by Phase 05's dedupe. Phase 04 dependencies extended to include Block 06 Phase 02 (Privacy Gateway) and Block 06 Phase 06 (Tier 2 local LLM) for the counterparty fallback. Phase 06 documents the re-entry path for `DUPLICATE_POSSIBLE`/`NEEDS_REVIEW` rows resolved as confirm-as-new — follow-up tool invocations with their own dedup key. Phase 07 dedupe-tool side-effect made specific (inserts `NEW` rows; raises `review_issues` for non-NEW; silently rejects `DUPLICATE_EXACT`). Phase 03 dependencies add Block 06 Phase 02 + Phase 03 (Document AI dispatched as Tier 3 through the gateway with redaction).
- *Medium:* Audit-event prefixes normalised to the `STATEMENT_*` family for parser/PDF/normalization events. Phase 07 documents status-transition ownership explicitly — which tool moves which status — and notes that Phase 08's partial-upload detection is co-located inside the four registered tools (no separate `detect_partial_upload` tool). Phase 09 acknowledges the manual-trigger fallback lives in Block 03; this phase contributes only the event side. Phase 09 cross-doc check on Block 03 Phase 09's consumer-side wiring. Phase 08 issue-group mapping for `partial_upload` annotated as jointly maintained with Block 14.
- *Low:* Phase 10 fixture format clarified — `expected_review_issues.json` carries `issue_type`, `issue_group`, `severity`, `recommended_action_set` precisely; severity matches must be exact.

**Sign-off.** GO. Block 07 cleared; ready to start Block 08 phase decomposition.

---

### Stage 2 — Block 06 phase scan — 2026-05-07

**Scope.** Block 06 architecture doc + decisions log + 11 phase docs.

**Method.** Delegated cross-read of all 13 documents. Checked phase ordering, gateway-pipeline step coherence (cache vs ceiling vs dispatch ordering), audit-event taxonomy across the block, Stage 1 decision alignment, sub-doc hooks, and cross-block dependencies (Blocks 02, 03, 04, 05, plus downstream consumers in Blocks 10, 12, 13, 14).

**Findings.** 0 CRITICAL, 6 HIGH, 6 MEDIUM, 4 LOW. All five Stage 1 AI decisions correctly applied. No scope leaks; no forward dependencies. Most issues clustered around three integration seams: cache-hit ↔ audit log, cache-hit ↔ cost ceiling, and the `cache_hit` field that bridges Phase 07/08/09.

**Fixes applied (all severities):**

- *High:* Phase 02 documents the `AI_GATEWAY_INVOKED ↔ AI_CACHE_HIT` replacement on cache hits and adds the canonical AI audit-event taxonomy. Phase 08 pre-call cost-ceiling check explicitly bypasses cache hits (cache lookup precedes the ceiling gate). Phase 09 restated the cache insertion point as "after redaction, before routing/dispatch and before the cost gate." Phase 07 `ai_usage_records` schema gains a `cache_hit` boolean. Phase 11 dependency list now names Block 14's resolution-driven re-scan trigger. `business_ai_config` consolidated — Phase 08 extends the same table from Phase 01 with cost-ceiling columns.
- *Medium:* Phase 02 declares the AI audit-event taxonomy as a section, not just a sub-doc hook. Phase 05 dependency list adds Block 03 Phase 08 (retry semantics consumer of the `transient` flag) and Block 05 Phase 01 (TLS + cert pinning). Phase 01 explains why Tier 2's redaction defaults are less restrictive (operator-controlled environment justifies the asymmetry). Phase 11 phase indices in Block 12/13 softened — `AI_END_SCAN` is the durable contract; integer phase numbers resolve at Block 12/13 decomposition. Phase 08 clarified that pre-call sum is Tier 3 by default; Tier 2 only when `tier_2_gating_enabled`. Phase 10 caches by `language` as part of the canonical input.
- *Low:* Phase 04 audit events renamed `PROMPT_*` → `AI_PROMPT_*` per the taxonomy. Phase 02 dependency list includes Block 03 Phase 08. Phase 11 Block 14 reference now names the resolution-driven re-scan trigger surface.

**Sign-off.** GO. Block 06 cleared; ready to start Block 07 phase decomposition.

---

### Stage 2 — Block 05 phase scan — 2026-05-07

**Scope.** Block 05 architecture doc + decisions log + 10 phase docs.

**Method.** Delegated cross-read of all 12 documents. Checked phase ordering, dependency satisfaction, cross-phase coherence (`KEY_ACCESSED` ownership, chain anchor contract with Block 04 Phase 08, Vault → pgcrypto chain, decrypt-at-use audit boundary, GDPR ↔ retention coupling), Stage 1 decision alignment, scope coverage, scope leak, audit-event taxonomy, cross-block dependencies, and privilege boundaries.

**Findings.** 0 CRITICAL, 8 HIGH, 9 MEDIUM, 6 LOW. No phase ordering bugs; no privilege-boundary violations; no scope leaks. All Stage 1 Block 05 decisions correctly applied. Most issues are documentation-level: contract drift between consumer and producer phases plus a couple of audit-event ownership ambiguities.

**Fixes applied (all severities) — including one targeted cross-block fix to Block 04 Phase 07:**

- *High:* Phase 02 wording on `event_id` clarified — globally monotonic in Phase 02, per-chain monotonicity wired by Phase 03. Phase 02 dropped its dependency on Block 04 Phase 01 (only Phase 03 uses the hashing helper). `KEY_ACCESSED` declared as Phase 04-owned only — Phase 05's `decrypt_field` emits `FIELD_DECRYPTED`, not a duplicate `KEY_ACCESSED`. Phase 09 GDPR access-export now explicitly wraps per-field decryption in Phase 06's `withAccessControl` and lists Phase 06 as a dependency. Phase 09 exposes a named entry point `gdpr.runScheduledAnonymization(request_id)` that Block 04 Phase 10's retention pass invokes. Phase 10 dependency list now includes Block 02 Phase 02 (for `LOGIN_FAILED`), Block 04 Phase 07 (for `OBJECT_LOCK_VIOLATION_DETECTED`), and Block 04 Phase 08 (backup events). Phase 10's Object-Lock rule now references the canonical event name. Phase 05 clarified that on a Phase 06 deny, `ACCESS_DENIED` is canonical and `FIELD_DECRYPTION_DENIED` is not separately emitted. **Cross-block fix:** Block 04 Phase 07's audit-event list now includes `OBJECT_LOCK_VIOLATION_DETECTED`.
- *Medium:* Phase 02 owns the audit-event taxonomy sub-doc and the naming-convention sub-doc (`<DOMAIN>_<PAST_VERB>` enforced by linting). Phase 02 action enum example now includes `LOGIN_FAILED`. Phase 04 deliverables note Vault-level access logging is enabled in addition to application-level audit. Phase 05 documents that mask values are deterministic (no audit needed for routine re-masking). Phase 06 sensitive-surface list now includes KEK and DEK rotation. Phase 07 dependency wording on Vault corrected to reflect the right direction (Vault credentials managed by the secrets manager). Phase 09 pseudonym-registry sub-doc clarifies the registry's encryption key lives in Phase 07's secrets manager (not the per-business DEK chain). Phase 10 dedup key shape spelled out as `(rule_id, subject_kind, subject_id)`.
- *Low:* All low items (forward Phase reference in Phase 01 pinning list, minor wording polish, action-enum placeholders) verified clean or already covered by sub-doc hooks.

**Sign-off.** GO. Block 05 cleared; ready to start Block 06 phase decomposition.

---

### Stage 2 — Block 04 phase scan — 2026-05-07

**Scope.** Block 04 architecture doc + decisions log + 11 phase docs.

**Method.** Delegated cross-read of all 13 documents. Checked phase ordering, dependency satisfaction, schema coherence across phases, role split (`archive_writer` / `retention_engine` / application read), placeholder-to-real-impl pattern (Phase 10 ↔ Phase 11), Stage 1 decision alignment, scope coverage and leak, audit-event taxonomy, cross-block dependencies, analytics-refresh trigger coherence, and RLS application.

**Findings.** 0 CRITICAL, 4 HIGH, 7 MEDIUM, 5 LOW. Schema coherence verified across phases. All eight Stage 1 Block 04 decisions correctly applied. No scope leaks (encryption work correctly deferred to Block 05). Cross-block dependencies (Block 02 Phases 01/02/04/05/06, Block 03 Phases 01/04, Block 05, Block 06, Block 14, Block 15, Block 16) are all marked deferred or already satisfied — none block Block 04 work.

**Fixes applied (all severities):**

- *High:* Phase 10's reference to Phase 11 moved out of Dependencies into a "Companion Phase" section (no real code dependency; placeholder pattern preserved). Hook signature unified to `legalHoldHook(business_id) → { on_hold: boolean, hold_reasons: string[] }` in both Phase 10 and Phase 11. Replacement mechanism described as runtime-registry registration at boot. Audit event canonicalised — Phase 11's `LEGAL_HOLD_DELETION_BLOCKED` removed; the canonical name `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` lives only on Phase 10.
- *Medium:* Phase 09 refresh strategy now covers `ARCHIVE_PROMOTION_FAILED` (no refresh) and adjustment-finalization triggers explicitly. Phase 10 inconsistency events now also surface as HIGH review issues in Block 14. Phase 04 Phase Goal carries explicit additive-only language for adjustment ledger rows. Phase 02 FK list includes the `transactions` reference for `evidence_pdfs`. Phase 06 polymorphic reference annotated as CHECK + validator (not a Postgres-native FK). Phase 09 RLS clarified — `analytics_writer` service role for writes, application roles SELECT-only. Phase 07 `archive.review_issues_history` renamed to `archive.review_issues` for symmetry with operational naming.
- *Low:* Phase 11's "Admin can be configured" exception moved from body to a sub-doc hook (Owner-only is the canonical MVP body rule). Block 05 cross-checks for `FILE_*` events deferred to Block 05's decomposition. Other low items (cross-block link navigation, archiveBundleHash hook listing) noted as editorial.

**Sign-off.** GO. Block 04 cleared; ready to start Block 05 phase decomposition.

---

### Stage 2 — Block 03 phase scan — 2026-05-07

**Scope.** Block 03 architecture doc + decisions log + 11 phase docs.

**Method.** Delegated cross-read of all 13 documents. Checked phase ordering, dependency satisfaction, deliverable coherence, scope coverage and leak, Stage 1 decision alignment, sub-doc hook consistency, audit-event taxonomy, cross-block circular deps, and state-machine completeness.

**Findings.** 0 CRITICAL, 5 HIGH, 6 MEDIUM, 3 LOW. Phase ordering clean (every dependency points backwards or out-of-block). All in-scope items mapped to phases; no scope leak. All eight Stage 1 Block 03 decisions correctly applied. All cross-block dependencies (Block 02 Phase 04/06/09, Block 05 audit, Block 15 archive) correctly marked deferred or already satisfied — none block Block 03 work.

**Fixes applied (all severities):**

- *High:* Phase 04 transition table now lists `null → CREATED` and labels every transition with the phase or block that triggers it (including `AWAITING_APPROVAL → FINALIZING`, `FINALIZING → FINALIZED`, and the `FINALIZING → AWAITING_APPROVAL` rollback owned by Block 15). Phase 06 step 8 clarified — execution loop only drives `RUNNING → AWAITING_APPROVAL`; finalization transitions are Block 15's. Phase 08 now states the two-level state semantics explicitly: `phase_state.status = HOLDING` AND `run.status = REVIEW_HOLD` via Phase 04. Phase 09 explicitly delegates `parent_run_id` validation for adjustment types to Phase 11. Phase 09 run creation now goes through `transitionRun(null → CREATED)` (no direct INSERTs).
- *Medium:* Audit-event prefixes standardised — Phase 03 emits `TOOL_REGISTRY_*` for startup events; Phase 07's `TOOL_DEDUP_HIT` and `TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID` renamed to `WORKFLOW_TOOL_*` to match Phases 06/08. Phase 07 now declares that `WORKFLOW_TOOL_INVOKED` is not emitted on a dedup hit. Phase 01 and Phase 07 sub-doc hooks now spell out the scope split between column-format (Phase 01) and generator playbook (Phase 07). Phase 03 added an AI-tier metadata sub-doc hook for cross-block linkage to Block 06. Phase 05 sub-doc hooks note that Block 12 owns side-phase reminder cadences.
- *Low:* Phase 06 progress API clarified — `total_phases` reflects the effective sequence per Phase 02, not the static type sequence. Phase 08 now documents the `IDEMPOTENT_AT_MOST_ONCE` failure-semantics value (no retries, fatal-error path). Phase 07 audit-events note clarifies that resume-after-restart is purely an event, not a state transition.

**Sign-off.** GO. Block 03 cleared; ready to start Block 04 phase decomposition.

---

### Stage 2 — Block 02 phase scan — 2026-05-07

**Scope.** Block 02 architecture doc + decisions log + 11 phase docs.

**Method.** Delegated cross-read of all 13 documents. Checked phase ordering validity, dependency satisfaction, deliverable coherence, scope coverage, scope leak, Stage 1 decision alignment, sub-doc hook consistency, audit-event taxonomy, and cross-block circular deps.

**Findings.** 0 CRITICAL, 5 HIGH, 8 MEDIUM, 4 LOW. All in-scope items mapped to phases; no scope leak; phase ordering clean (every dependency points backwards or out-of-block).

**Fixes applied (all severities):**

- *High:* Phase 11 mobile scope corrected — settings is desktop-only in MVP (mobile read-only applies only to dashboards/drill-down/queue per Stage 1). Audit event collision resolved — Phase 02 emits `PASSWORD_RESET_COMPLETED` (reset path), Phase 11 keeps `PASSWORD_CHANGED` (in-app change). Phase 02 audit list qualified as "auth-flow only". Phase 08 refresh-failure linked explicitly to `INTEGRATION_REFRESH_FAILED`. Phase 09 clarified as read-only on `business_user_roles` (mutation owned by Phase 07).
- *Medium:* Phase 03 MFA-required-role sub-doc retitled and scoped (general role propagation lives in Phase 09). Phase 05 added Postgres mirror of the permission matrix as a deliverable. Phase 04 declared the permission matrix as the single source of truth for `STEP_UP_REQUIRED`; Phase 06 explicitly reads from it. Phase 08 Drive convention noted as MVP-only. Phase 01 IBAN ciphertext column comment fixed (Block 05 owns encryption). Phase 11 personal audit feed marked as a Block 05 read consumer. Phase 03 Vault dependency made explicit with wrapper-interface fallback and no-plaintext rule. Phase 09 cross-block Block 03 dep marked deferred.
- *Low:* Phase 04 surface name shortened from `EXTERNAL_INTEGRATION_MANAGE` to `EXTERNAL_INTEGRATION` to match architecture wording. Phase 01 `accounting_method` comment notes accrual-only MVP. Phase 03 audit-sequence note added (`LOGIN` + `MFA_CHALLENGE_PASSED` is the canonical authenticated-login pair).

**Sign-off.** GO. Block 02 cleared; ready to start Block 03 phase decomposition.

---

### Stage 1 cross-block compatibility scan — 2026-05-07

**Scope.** All 16 architecture docs (`Docs/blocks/01..16`) plus `Docs/decisions_log.md` and this outline.

**Method.** Delegated read-and-compare across all 18 documents. Checked: cross-reference integrity, interface matching (producer/consumer pairs), Stage 1 decision-doc alignment, principle traceability against Block 01's five principles, workflow engine contract consistency between Block 03 and Blocks 12/13, storage zone consistency against Block 04's five zones, AI tier consistency against Block 06's three tiers, and terminology consistency for the closed taxonomies (12 transaction types, 8 VAT treatments, 4 match levels, 6 review groups).

**Findings.** 1 CRITICAL, 6 HIGH, 10 MEDIUM, 8 LOW. No structural contradictions; no broken decision-doc alignment; the three Batch 4 user upgrades (zip-bundle archive, multi-business full drill-down, configurable accountant pack) all verified present in the bodies of Blocks 15 and 16.

**Fixes applied.** All CRITICAL, HIGH, and actionable MEDIUM/LOW items fixed:

- *Critical:* Block 09's invented "Principle 6" corrected to Principle 4.
- *High:* Block 09 explicitly notes that Block 13's Invoice Generator bypasses its intake; Block 13 clarifies that `IN_MONTHLY` does not run document discovery; Block 13 replaces the non-canonical `UNKNOWN_POSITIVE` with `UNKNOWN` (with positive direction), aligning to Block 08's closed taxonomy; Blocks 12 and 13 added symmetric notes on refund routing (`REFUND_IN` on IN side, `REFUND_OUT` on OUT side); Block 15's bundle entry renamed `report.pdf` → `period_report.pdf` to distinguish from Block 16's on-demand accountant pack; Block 02's stale "see Open Questions" pointer replaced with the Stage 1 resolution language.
- *Medium:* Block 01 issue-group label aligned to "Tax/VAT" (was "Tax-VAT"); Block 04 entity table standardized on "Operational Database" (was "Operational DB" shorthand); Block 04 Inputs now list Processing-zone AI artefacts from Block 06; Block 14 clarifies that phase `HUMAN_REVIEW_HOLD` and run-level state `REVIEW_HOLD` always travel together but are different namespaces.
- *Low:* Block 04 retention defines the canonical "6-year legal retention window" phrasing referenced by Blocks 12 and 15; Block 04 retention engine wording clarifies it is an internal background job (not a workflow trigger); Outline Block 16 entry now points to Block 16 for the complete 13-item export catalogue.

The remaining MEDIUM/LOW items from the scan (M3, M4, M6, M9, M10, L2, L3, L5, L7, L8) were either already consistent or withdrawn on review by the scanner — no fixes required.

**Sign-off.** GO. Stage 1 cleared for Stage 2.
