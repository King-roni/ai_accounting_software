# Block 08 — Phase 05: Tag System & Default Taxonomy

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Tagging section)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 02 — `transactions.system_tag`, `secondary_tags` columns)
- Decisions log: `Docs/decisions_log.md` (multi-tag = primary + optional secondary)

## Phase Goal

Build the tag system that sits on top of the type classifier: every transaction gets one **primary tag** (which drives the ledger path in Block 11) and optionally **secondary tags** (analytics-only, no ledger effect). Ship a default Cyprus-friendly tag taxonomy. After this phase, the user sees plain-language tags everywhere and the 12 internal type codes stay internal.

## Dependencies

- Phase 01 (`tag_taxonomy_versions`, `business_tag_taxonomy_assignments` tables)
- Phase 02 / 03 / 04 (the classifier layers can pin a tag alongside the type)
- Block 04 Phase 02 (`transactions.system_tag` + `secondary_tags` JSONB)
- Block 06 Phase 10 (plain-language rendering for tag-derived UI strings, where AI is involved)

## Deliverables

- **Default tag taxonomy** seeded at deployment as the platform's `is_default = true` row in `tag_taxonomy_versions`. The default taxonomy includes (each entry maps to exactly one of the 12 transaction types):
  - `Software & subscriptions` → `OUT_EXPENSE`
  - `Office expenses` → `OUT_EXPENSE`
  - `Travel & transport` → `OUT_EXPENSE`
  - `Marketing & advertising` → `OUT_EXPENSE`
  - `Professional services` → `OUT_EXPENSE` (legal, accounting, consulting)
  - `Contractor payment` → `PAYROLL_OR_TEAM_PAYMENT`
  - `Team member invoice` → `PAYROLL_OR_TEAM_PAYMENT`
  - `Bank fees` → `BANK_FEE`
  - `Tax payment` → `TAX_PAYMENT`
  - `Internal transfer` → `INTERNAL_TRANSFER`
  - `Currency exchange` → `FX_EXCHANGE`
  - `Customer payment` → `IN_INCOME`
  - `Refund received` → `REFUND_IN`
  - `Refund issued` → `REFUND_OUT`
  - `Chargeback` → `CHARGEBACK`
  - `Loan / shareholder movement` → `LOAN_OR_SHAREHOLDER_MOVEMENT`
  - `Unknown` → `UNKNOWN`
- **Primary vs secondary semantics** per Stage 1:
  - **Primary tag** (`transactions.system_tag` or `user_tag` if overridden) — required, drives the ledger path in Block 11. Exactly one per transaction.
  - **Secondary tags** (`transactions.secondary_tags` JSONB array) — optional, zero or more, analytics-only. They do NOT affect the ledger entry; they're for cross-cutting reporting (e.g., a transaction tagged primary `Software & subscriptions` could carry secondary tag `Marketing tools` for finer reporting).
- **Tag-assignment logic** during classification:
  - **Layer 1 (rules):** if a matched rule pins both type and tag, the rule's tag becomes the primary tag.
  - **Layer 2 (vendor memory):** the memory row's `suggested_tag` becomes the primary tag.
  - **Layer 3 (AI):** the AI response's `suggested_tag` becomes the primary tag, validated against the active taxonomy + custom tags.
  - **Fallback (no tag suggested):** the type's default tag (one per type) is assigned as primary. Every type has exactly one default tag (the first match in the taxonomy ordered table).
- **Plain-language tag rendering:**
  - The user-facing string is the `tag_name` from the taxonomy as-is (e.g., `"Software & subscriptions"`).
  - The internal `transaction_type` ENUM is never rendered to users (Principle 5).
- **Active taxonomy resolution per business:**
  - At classification time, the active taxonomy is resolved from `business_tag_taxonomy_assignments` for the business.
  - Finalized periods preserve their version (Phase 08 owns the snapshotting); this phase only handles current-run resolution.
- **Audit events:** `TAG_ASSIGNED` (with primary tag), `SECONDARY_TAG_ADDED`, `TAG_OVERRIDDEN_BY_USER`, `TAG_DEFAULT_FALLBACK_USED` (telemetry — high counts mean classifier prompts/rules need work on tag suggestions).

## Definition of Done

- The default tag taxonomy is seeded; every transaction type has at least one tag mapping.
- A clean Layer 1 match with a tag-pinning rule produces the right primary tag on the transaction.
- A vendor-memory hit propagates the stored tag.
- A type whose tag couldn't be derived falls back to the type's default tag, with `TAG_DEFAULT_FALLBACK_USED` emitted.
- The user can add a secondary tag from the UI; it appears in `secondary_tags` JSONB; reports filter on it correctly.
- Tests cover happy path per type, multi-tag round-trip, AI-suggested tag validation against the active taxonomy.

## Sub-doc Hooks (Stage 4)

- **Default taxonomy content sub-doc** — exact tag list with descriptions, tone guide, type mappings, refresh policy.
- **Primary vs secondary semantics sub-doc** — exact UX, validation rules, ledger-effect contract.
- **Tag rendering sub-doc** — display rules, internationalisation hook (locale-aware tag names — deferred per Stage 1 EU-default).
- **Default fallback telemetry sub-doc** — how `TAG_DEFAULT_FALLBACK_USED` rates feed back into prompt and rule tuning.
