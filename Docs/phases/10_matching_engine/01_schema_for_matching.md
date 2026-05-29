# Block 10 — Phase 01: Schema for Matching

## References

- Block doc: `Docs/blocks/10_matching_engine.md`
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 03 — `match_records` already provisioned with the score breakdown, plain-language reason, and `split_payment_group_id`)

## Phase Goal

Add the supporting schema beyond what Block 04 already provisioned: the rejection-memory table that lets the engine remember `(transaction, document)` rejections forever (Stage 1), and the split-payment-groups table that ties together the multiple match records of a proactively detected split payment. After this phase, Phases 02–10 have the data infrastructure they need.

## Dependencies

- Block 02 Phase 01 (tenancy schema)
- Block 02 Phase 05 (RLS template)
- Block 04 Phase 03 (`match_records` table already exists with `match_signals` JSONB, `match_reason_plain_language`, `split_payment_flag`, `split_payment_group_id`)

## Deliverables

- **`match_rejection_memory` table** — the forever-remembered rejections (Stage 1):
  - `id` (UUID v7), `organization_id`, `business_id`
  - `transaction_id` (FK to `transactions`), `document_id` (FK to `documents`) — both required
  - `rejected_by` (user_id), `rejected_at`
  - `rejection_reason` (free text — optional but encouraged)
  - `original_match_record_id` (nullable; the `match_records` row that was rejected, kept for traceability even if its row is later cleaned up)
  - **Unique constraint** on `(business_id, transaction_id, document_id)` — Phase 06's "never re-suggest a rejected pair" is enforced at the database layer.
- **`split_payment_groups` table** — Phase 04's combinatorial-detection results:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `parent_target_kind` (`INVOICE` for OUT side or `EXTERNAL_INVOICE` for documents from intake; or `MULTIPLE` when the group spans multiple parent docs)
  - `parent_target_id` (nullable; populated when `parent_target_kind != MULTIPLE`)
  - `proposed_total_amount`, `currency` (the sum the engine proposes the group covers)
  - `status` (`PROPOSED`, `CONFIRMED`, `REJECTED`)
  - `proposed_at`, `confirmed_by`, `confirmed_at`, `rejected_by`, `rejected_at`
  - `member_count` (denormalised count of `match_records` rows in the group; updated on insert/delete)
- **Match-records integration:**
  - When a split-payment group is confirmed, every constituent `match_records` row gets `split_payment_flag = true` and `split_payment_group_id = group.id`.
  - The unique constraint on `(transaction_id, document_id)` (Block 04 Phase 03) still applies — the same transaction can be matched to multiple invoices via separate match records (one per group member), each with a distinct `document_id`.
- **RLS** on both new tables per the Block 02 Phase 05 template.
- **Indexes:**
  - `match_rejection_memory(business_id, transaction_id)` and `(business_id, document_id)` — both directions for the rejection-suppression lookup in Phase 02.
  - `split_payment_groups(business_id, status)` — review-queue filter.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention):
  - `MATCHING_REJECTION_RECORDED`
  - `SPLIT_PAYMENT_GROUP_CREATED`
  - `SPLIT_PAYMENT_GROUP_STATUS_CHANGED` — fallback/generic transition event; emitted ONLY when the destination state isn't covered by a named transition. The named transitions `SPLIT_PAYMENT_GROUP_CONFIRMED` and `SPLIT_PAYMENT_GROUP_REJECTED` (Phase 04) are preferred for queryability and replace the generic event when applicable. A single state change emits exactly one audit event — never both the named and the generic.

## Definition of Done

- Both new tables exist with correct columns, FKs, and constraints.
- The unique constraint on `match_rejection_memory` blocks duplicate rejection records.
- RLS prevents cross-tenant access (Block 02 invariant tests extended).
- A test inserts a rejection, attempts to suggest the same pair again, and the suppression lookup correctly skips it.
- A test confirms a split-payment group with three constituent match records; all three rows correctly carry the flag and group id.

## Sub-doc Hooks (Stage 4)

- **Rejection-memory schema sub-doc** — exact column types, retention, archival rules.
- **Split-payment-group schema sub-doc** — exact rules for `parent_target_kind = MULTIPLE`, member-count maintenance, lifecycle.
- **Index strategy sub-doc** — query plans for the hot lookups (rejection check, group filter).
