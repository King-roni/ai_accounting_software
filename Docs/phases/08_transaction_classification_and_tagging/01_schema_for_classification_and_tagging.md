# Block 08 — Phase 01: Schema for Classification & Tagging

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md`
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 02 — `transactions` already has classification columns)

## Phase Goal

Lay down the database tables this block needs beyond what Block 04 already provided: rule definitions, recurring-vendor memory, tag taxonomy versions, and per-business custom tags. After this phase, Phases 02–08 have the schema they read and write — and the `transactions` table's classification columns (already provisioned in Block 04 Phase 02) have backing tables to populate them.

## Dependencies

- Block 02 Phase 01 (tenancy schema)
- Block 02 Phase 05 (RLS template)
- Block 04 Phase 02 (`transactions.transaction_type`, `system_tag`, `secondary_tags`, `classification_status`, `classification_confidence` columns already exist; this phase doesn't redefine them)
- Block 04 Phase 04 (`review_issues` for the `NEEDS_CONFIRMATION` routing)

## Deliverables

- **`classification_rules` table:**
  - `id` (UUID v7), `organization_id`, `business_id` (nullable — global rule when null), `rule_kind` (`REGEX_DESCRIPTION`, `COUNTERPARTY_NAME`, `COUNTERPARTY_DOMAIN`, `AMOUNT_THRESHOLD`, `MERCHANT_CATEGORY_CODE`, `OWN_ACCOUNT_TRANSFER`)
  - `rule_predicate` (JSONB — shape varies by `rule_kind`)
  - `assigned_type` (one of the 12 transaction types)
  - `assigned_tag` (nullable — when set, the rule pins both type and tag)
  - `priority` (smaller wins; per-business rules default to higher priority than global)
  - `enabled`, `created_at`, `updated_at`, `created_by`
- **`recurring_vendor_memory` table:**
  - `id` (UUID v7), `organization_id`, `business_id`
  - `counterparty_signature` (normalized name + identifier — see Phase 03 for the normalization rules)
  - `suggested_type`, `suggested_tag`
  - `confirmations_count` (default 0; incremented on confirm)
  - `first_seen_at`, `last_confirmation_at`
  - `status` (`ACTIVE`, `REVOKED`)
  - Unique constraint: `(business_id, counterparty_signature)` — one memory row per `(business, counterparty)`.
- **`tag_taxonomy_versions` table:**
  - `id`, `version_label` (e.g., `default-2026-05`), `definition` (JSONB — array of `{ tag_name, transaction_type, description? }`)
  - `is_default` (boolean — exactly one row may be the platform-wide default)
  - `created_at`, `retired_at` (nullable; non-null means the version is no longer assignable to new periods but historical periods still reference it)
- **`business_tag_taxonomy_assignments` table:**
  - `business_id`, `tag_taxonomy_version_id`, `assigned_at`, `assigned_by`
  - Tracks which taxonomy a business currently uses for new runs. Finalized periods preserve their assignment via a snapshot field on `workflow_runs`.
- **`business_custom_tags` table:**
  - `id`, `organization_id`, `business_id`, `tag_name`, `mapped_transaction_type` (one of the 12), `created_at`, `created_by`
  - Unique constraint: `(business_id, tag_name)` — a custom tag name is unique within a business.
  - The custom tag's mapping to exactly one transaction type is enforced as a NOT NULL on `mapped_transaction_type` (Stage 1 decision).
- **`classification_method` ENUM** declared on `transactions` (extends Block 04 Phase 02's column shape) with values: `RULE`, `VENDOR_MEMORY`, `AI_FALLBACK`, `NO_AI_AVAILABLE` (set when Phase 09's per-business config disabled `apply_layer3` and Layers 1+2 didn't resolve), `MANUAL` (set when a user manually overrides via the review queue).
- **RLS** on every table per the Block 02 Phase 05 standard template (global rules where `business_id IS NULL` are readable across tenants; only platform admins can insert global rules).
- **Indexes:**
  - `classification_rules(business_id, rule_kind, enabled)`.
  - `recurring_vendor_memory(business_id, counterparty_signature)` — primary lookup index.
  - `business_custom_tags(business_id, tag_name)`.

## Definition of Done

- All tables exist with their columns, FKs, and constraints.
- RLS prevents cross-tenant reads and writes; the global-rule exception is verified.
- Indexes are confirmed via `EXPLAIN` for the dominant queries (rule lookup by business, vendor memory lookup by signature).
- A test inserts a global rule, a per-business rule, a vendor memory entry, a tag taxonomy version, an assignment, and a custom tag — round-trips read.
- The `business_custom_tags` constraint forces every custom tag to map to a single transaction type.

## Sub-doc Hooks (Stage 4)

- **Rule predicate JSONB schema sub-doc** — exact shape per `rule_kind`, validation rules, evolution policy.
- **Vendor signature normalization sub-doc** — see Phase 03 for the actual normalization; this sub-doc anchors the column-shape decisions.
- **Tag taxonomy version structure sub-doc** — `definition` JSONB layout, retirement semantics, default-flag uniqueness.
- **Custom tag uniqueness sub-doc** — case sensitivity, whitespace handling, conflict resolution with default-taxonomy names.
