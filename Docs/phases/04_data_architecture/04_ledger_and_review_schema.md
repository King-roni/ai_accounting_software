# Block 04 — Phase 04: Ledger & Review Schema

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Canonical Entities section)
- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Draft Ledger Entry consumer)
- Block doc: `Docs/blocks/14_review_queue.md` (Review Issue consumer)

## Phase Goal

Add the operational tables for draft ledger entries and review issues. These are the last two entity types before zone work begins. After this phase, Block 11 has somewhere to write draft entries, and every issue-producing block (06, 07, 08, 10, 11, 13) has a target table for the issues that flow into Block 14's queue.

**Adjustment runs are additive only.** Original `draft_ledger_entries` rows are never modified after creation — corrections come as **new** rows linked via `parent_finalized_run_id`, with the adjustment fields populated together. This phase's schema enforces the additive contract via the all-null-or-all-populated constraint on `adjustment_*` columns (per the Stage 1 decision).

## Dependencies

- Phase 01 (hashing)
- Phase 02 (`transactions` FK)
- Phase 03 (`match_records` FK)
- Block 02 Phase 05 (RLS)
- Block 03 Phase 01 (`workflow_runs` FK)

## Deliverables

- **`draft_ledger_entries` table:**
  - `id` (UUID v7), `organization_id`, `business_id`
  - `workflow_run_id` (FK), `transaction_id` (FK), `match_record_id` (FK, nullable for non-evidence-bearing types like `INTERNAL_TRANSFER`, `BANK_FEE`)
  - `entry_type` (`DEBIT`, `CREDIT`)
  - `account_code`, `account_name` (resolved against the Cyprus-friendly default chart per Stage 1; per-business overrides allowed)
  - `chart_of_accounts_version` (per Stage 1 versioned tag taxonomy and chart — finalized periods preserve their version)
  - `debit_amount`, `credit_amount`, `currency`
  - **VAT fields:** `vat_treatment` (one of the 8 from Block 11), `input_vat_reclaimable`, `output_vat_due`, `reverse_charge_relevant`, `vies_relevant`, `vat_amount`
  - **Compliance evidence flags:** `requires_invoice`, `requires_receipt`, `requires_contract`, `requires_accountant_review`, `accountant_review_reason`
  - `counterparty_country`, `counterparty_vat_number`
  - `consolidated_from_line_count` (per Stage 1's one-consolidated-entry-per-multi-line-invoice decision)
  - `non_deductible_subaccount` (nullable; per Stage 1's separate-sub-accounts-per-category for non-deductible expenses)
  - `approval_status` (`DRAFT`, `APPROVED`, `LOCKED`)
  - `parent_finalized_run_id` (nullable; populated for adjustment-run entries pointing at the original finalized run)
  - `adjustment_reason`, `adjustment_delta` (JSONB; Stage 1: explicit reason + structured delta — populated only for adjustment entries)
  - `created_at`, `updated_at`
- **`review_issues` table:**
  - `id` (UUID v7), `organization_id`, `business_id`
  - `workflow_run_id` (FK)
  - `transaction_id` (FK, nullable), `document_id` (FK, nullable), `match_record_id` (FK, nullable), `draft_ledger_entry_id` (FK, nullable) — at least one must be populated
  - `issue_type` (internal taxonomy string owned by the producing block)
  - `issue_group` (one of the 5 actionable buckets — enforced as ENUM; `Ready to Finalize` is a queue-state projection, not a row value, per Block 14 Phase 02 H8 fix)
  - `severity` (`LOW`, `MEDIUM`, `HIGH`, `BLOCKING`; no `CRITICAL` per the 2026-05-08 amendment)
  - `plain_language_title`, `plain_language_description` (generated content per Block 06's plain-language pipeline; populated at issue-creation time per Block 14 Phase 03's frozen-card-content rule)
  - `recommended_action`
  - **Card-content metadata** (added per Block 14 Phase 03):
    - `card_payload_json` (JSONB; structured context for the card UI — transaction context, attached documents, expand-payload reference)
    - `card_content_generated_at` (timestamp)
    - `card_content_tier_used` (enum: `NONE`, `TIER_2_LOCAL_LLM`, `TIER_3_EXTERNAL_LLM`)
    - `card_content_fallback_applied` (boolean; `true` when AI-call failure forced the deterministic fallback)
  - **Status:** `status` (`OPEN`, `RESOLVED`, `SNOOZED`, `DISMISSED`, `AUTO_RESOLVED_BY_RESCAN` — the last value added per Block 14 Phase 08's targeted-rescan auto-closure)
  - `resolution_action` (the Block 14 action chosen by the resolver — one of the 13-action vocabulary)
  - `resolution_note` (per Stage 1's single-notes-field-per-issue decision; Block 14 phases use this canonical column name)
  - `assigned_to` (user_id, nullable; per Stage 1's optional assignment)
  - `assigned_by`, `assigned_at`
  - `assignment_notification_sent_at` (timestamp; populated when in-app + email notification has been delivered)
  - `snoozed_at`, `snoozed_by`, `snoozed_until`, `snooze_reason` (per Stage 1's snooze-with-explicit-reason decision; `snoozed_until` populated lazily at next-run-start per Block 14 Phase 07)
  - `auto_resolution_trigger_issue_id` (FK to `review_issues.id`; nullable; populated when `status = AUTO_RESOLVED_BY_RESCAN` to record the resolved issue whose closure triggered this auto-close)
  - `resolved_by`, `resolved_at`
  - `created_at`, `updated_at`
- **RLS policies** on both tables.
- **Indexes:**
  - `draft_ledger_entries(workflow_run_id)`, `draft_ledger_entries(business_id, account_code)`, `draft_ledger_entries(parent_finalized_run_id)` for adjustment lookups.
  - `review_issues(workflow_run_id, status)`, `review_issues(business_id, severity, status)` for queue filtering, `review_issues(assigned_to, status)` for "my queue".
- **Constraints:**
  - `review_issues` CHECK that at least one of the entity FKs is populated.
  - `review_issues.issue_group` ENUM strictly limited to the **five actionable bucket names** (Missing Documents, Needs Confirmation, Possible Wrong Match, Possible Tax/VAT Issue, Unusual Transaction). The architecture-doc sixth bucket `Ready to Finalize` is a queue-state projection, not a row value, per Block 14 Phase 02's H8 fix.
  - `draft_ledger_entries.adjustment_*` columns must be all-null or all-populated together.

## Definition of Done

- Both tables exist with correct columns, FKs, and constraints.
- RLS in place; invariant tests extended.
- A draft ledger entry can be inserted with VAT fields populated and read back consistently.
- A review issue with a snoozed status correctly stores `snoozed_until` and a non-empty reason.
- The `issue_group` ENUM constraint rejects any value not in the six-bucket set.
- Adjustment-run entries pointing at a finalized parent populate the adjustment fields together.

## Sub-doc Hooks (Stage 4)

- **VAT treatment ENUM sub-doc** — the eight values, semantics, and integration with Block 11's classifier.
- **Account-code resolution sub-doc** — chart-of-accounts schema, the Cyprus-friendly default content, version-tag mechanics.
- **Issue type → group mapping sub-doc** — the canonical mapping table owned by Block 14, sourced from each producing block's issue types.
- **Resolution action ENUM sub-doc** — every available resolution action and which `issue_type` permits which.
- **Adjustment delta JSONB shape sub-doc** — exact structure of `{ field_name: { old_value, new_value }, ... }` per Stage 1.
