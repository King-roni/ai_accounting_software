# dedup_pattern_ownership_map

**Category:** Reference data · **Owning block:** 10 — Matching Engine · **Co-owners:** 03, 05, 07, 08, 09, 13, 14 · **Stage:** 4 sub-doc (Layer 1 reference)

The single canonical map of every distinct deduplication pattern in the platform: the owning block, the cross-block consumers, the mechanism class, the canonical source-of-truth doc, and the schema migration that materialised it.

Per the hook: "kept in sync if patterns move between blocks." Maintenance rules in §6.

---

## 1. Why this map exists

Dedup logic is scattered across 7+ blocks (intake, classification, matching, ledger, invoice generation, IN, OUT) with overlapping mechanisms. BOOK-196 surfaced two distinct dedup mechanisms living in the same hook (composite-key + pg_trgm fuzzy at Block 10·P05 vs SHA-256 fingerprint at Block 07's intake) — both legitimate, both canonical, but operating at different lifecycle stages and detecting different patterns.

Without a single source-of-truth map:

- Two blocks can independently add overlapping dedup mechanisms for the same conceptual entity.
- Pattern moves (e.g., consolidating two near-duplicate mechanisms) lose their cross-block consumer list.
- Drift between docs (per BOOK-170, BOOK-188, BOOK-190, BOOK-193 reconciliation queue) compounds with each migration.

This map is the artefact that prevents those failure modes.

---

## 2. The pattern table

One row per *named* dedup pattern. The `pattern_name` column is the canonical identifier referenced elsewhere.

| pattern_name | Owning block | Phase | Mechanism class (§3) | Canonical doc | Cross-block consumers |
|---|---|---|---|---|---|
| `transactions_intake_fingerprint` | **07** Bank Statement Pipeline | P03 (intake parse) | Hash-based | `deduplication_policy.md` + `deduplication_fingerprint_schema.md` | 10 (matching-time check), 14 (SOFT-duplicate review queue) |
| `transactions_pattern_pgtrgm` | **10** Matching Engine | P05 (duplicate detection) | Probabilistic / fuzzy | `tool_dedup_check.md` (composite-key exact + pg_trgm fuzzy) | 14 (DUPLICATE_PROBABLE review issues) |
| `match_records_pair_dedup` | **10** Matching Engine | P02 (scoring) | Composite-key uniqueness | `match_records_schema.md` + `rejection_memory_schema.md` (BOOK-166) | Self-contained within Block 10 |
| `vendor_memory_canonical_dedup` | **08** Classification & Tagging | P03 (vendor memory) | Composite-key uniqueness | `vendor_memory_schema.md` + `fuzzy_match_algorithm_policy.md` (BOOK-172) | 10 (scoring), 13 (vendor lookups for invoice generation) |
| `documents_content_hash_dedup` | **09** Document Intake & Extraction | P02 (upload) | Hash-based | `documents_schema.md` + `raw_uploads_schema.md` | 10 (matching), 14 (duplicate-document review) |
| `invoice_number_uniqueness` | **13** IN Workflow + Invoice Generator | P04 (invoice generation) | Composite-key uniqueness | `invoice_lifecycle_schema.md` + `invoice_numbering_policy.md` | 12 (OUT workflow consumes for OUT invoices), 15 (finalization gate) |
| `split_payment_group_dedup` | **10** Matching Engine | P04 (combinatorial detection) | State-machine exclusion | `split_payment_relationship_schema.md` + `split_payment_combinatorial_bounds.md` (BOOK-188) step 6 | Self-contained within B10·P04 |
| `audit_event_idempotency` | **05** Security & Audit | P02 (emit_audit) | Optional idempotency-key | `audit_log_policies.md` + `audit_event_payload_schemas.md` | All blocks (every audit-emit caller) |
| `workflow_run_idempotency` | **03** Workflow Engine | P02 (run creation) | Composite-key uniqueness | `workflow_run_schema.md` | All workflow-spawning blocks (07, 12, 13, 15) |
| `bulk_preview_token_single_use` | **14** Review Queue | P05 (bulk actions) | Single-use token | `bulk_action_policies.md` + `bulk_preview_tokens_schema.md` | Self-contained within B14·P05 |

---

## 3. Mechanism classes

The "Mechanism class" column above maps to one of these six taxonomic categories. The class determines the test-fixture shape and the regression-detection approach.

| Class | Description | Example patterns |
|---|---|---|
| Hash-based | Deterministic hash (SHA-256) of a canonical field tuple + UNIQUE constraint. Re-derivation produces the same fingerprint; collisions are mathematically impossible at SHA-256 strength. | `transactions_intake_fingerprint`, `documents_content_hash_dedup` |
| Composite-key uniqueness | Multi-column UNIQUE constraint or UNIQUE index. Direct DB enforcement; INSERT failure is the dedup signal. | `match_records_pair_dedup`, `invoice_number_uniqueness`, `vendor_memory_canonical_dedup`, `workflow_run_idempotency` |
| Probabilistic / fuzzy | Similarity threshold (pg_trgm, Jaro-Winkler, Levenshtein) + manual review when above threshold but below identity. Outputs a confidence score rather than a binary verdict. | `transactions_pattern_pgtrgm` |
| State-machine exclusion | An existing row in a particular state (PROPOSED, CONFIRMED, ACTIVE) excludes new attempts. Differs from composite-key UNIQUE because the exclusion is state-conditional. | `split_payment_group_dedup` |
| Optional idempotency-key | Caller opts in by providing an `idempotency_key`; system enforces uniqueness on that key but allows duplicate calls without a key. Used where the caller can decide whether replay-safety is needed. | `audit_event_idempotency` |
| Single-use token | A token row carries a `consumed_at` field; first consumer sets it; subsequent attempts fail. Distinct from composite-key UNIQUE because the row pre-exists and the dedup is across consumption events, not inserts. | `bulk_preview_token_single_use` |

---

## 4. Reverse view — by owning block

Same data, indexed by block. Lets each block-owner see at a glance what they're responsible for.

| Block | Owned patterns |
|---|---|
| 03 Workflow Engine | `workflow_run_idempotency` |
| 05 Security & Audit | `audit_event_idempotency` |
| 07 Bank Statement Pipeline | `transactions_intake_fingerprint` |
| 08 Classification & Tagging | `vendor_memory_canonical_dedup` |
| 09 Document Intake & Extraction | `documents_content_hash_dedup` |
| 10 Matching Engine | `transactions_pattern_pgtrgm`, `match_records_pair_dedup`, `split_payment_group_dedup` |
| 13 IN Workflow + Invoice Generator | `invoice_number_uniqueness` |
| 14 Review Queue | `bulk_preview_token_single_use` |

Block 10 owns the most patterns (3) — appropriate for a matching engine whose primary domain is correctness of pair-identity decisions.

---

## 5. Cross-block consumer matrix

Which block reads from which dedup mechanism. Critical when a pattern's mechanism changes — consumers need notification.

| Pattern | Consumers |
|---|---|
| `transactions_intake_fingerprint` | 10, 14 |
| `transactions_pattern_pgtrgm` | 14 |
| `match_records_pair_dedup` | — (terminal) |
| `vendor_memory_canonical_dedup` | 10, 13 |
| `documents_content_hash_dedup` | 10, 14 |
| `invoice_number_uniqueness` | 12, 15 |
| `split_payment_group_dedup` | — (terminal) |
| `audit_event_idempotency` | All blocks |
| `workflow_run_idempotency` | 07, 12, 13, 15 |
| `bulk_preview_token_single_use` | — (terminal) |

Terminal patterns are self-contained — changes don't ripple. Non-terminal patterns require coordinated updates when changing.

---

## 6. Maintenance rules

**These rules are binding. Violations are CI-lint-failing.**

1. **Adding a new dedup pattern** → must add a row to §2 in the same PR that introduces the mechanism. The PR description must include the pattern_name + owning block + canonical doc reference.

2. **Moving a pattern between blocks** → update this map AND the cross-references in both the old and new owning docs. The move requires a `Docs/decisions_log.md` amendment because consumer-block ownership shifts.

3. **Changing a pattern's mechanism class** (e.g., from probabilistic to composite-key uniqueness) → update this row + the §3 mechanism-class column + the canonical-doc references + flag every consumer block for re-verification via a `Docs/decisions_log.md` amendment.

4. **Renaming a pattern** → permitted in MVP via PR + decisions-log amendment; not permitted after Stage 2 launch without a deprecation cycle.

5. **CI lint** (Stage 2+): scan source for UNIQUE constraints, pg_trgm similarity calls, SHA-256 fingerprint generations, and `idempotency_key` parameters. Each occurrence must appear in this map. New constraints without a map row block CI.

6. **Consumer-side notification**: when a non-terminal pattern's mechanism changes, the owning block opens a coordination issue against each consumer's Plane phase. The consumer-block reviewer must sign off before the PR merges.

---

## 7. Explicit non-overlaps

Pairs that look like they might overlap but don't:

| Pair | Why they don't overlap |
|---|---|
| `transactions_intake_fingerprint` (B07) and `transactions_pattern_pgtrgm` (B10) | Different lifecycle stages (intake vs matching) and different patterns (exact-content vs probabilistic-near-match). The intake fingerprint catches re-uploaded statement rows; the pg_trgm pattern catches typo'd / re-keyed duplicates that slipped through intake. Per BOOK-196 drift note. |
| `documents_content_hash_dedup` (B09) and any "semantic document dedup" | Block 09's hash is on raw file bytes only; semantic / extracted-content dedup is a Block-10 matching concern not a dedup mechanism. No competing pattern exists at the document layer. |
| `invoice_number_uniqueness` (B13) and `workflow_run_idempotency` (B03) | Different identity surfaces. Invoice numbers are per-business-per-series human-readable; workflow run idempotency keys are system-internal event-id tuples. No cross-talk. |
| `audit_event_idempotency` and any per-event UNIQUE constraint | The `audit_event_idempotency` mechanism is opt-in via `idempotency_key`; absent the key, audit events are NOT deduplicated (per project-meta drawer's "audit_events is IMMUTABLE" — meaning the chain accepts duplicate emits when the caller didn't request idempotency). |

---

## 8. Explicitly NOT in scope of this map

To forestall conflation:

- **Audit chain hash-pointer linking** — that's a tamper-detection mechanism (chain-of-custody integrity), not a dedup mechanism. Lives in `audit_log_policies` chain-linkage rules.
- **Step-up token single-use** (per BOOK-195 `step_up_validity_window_policy.md`) — authorization-token state, not dedup.
- **Session-token single-use** (per BOOK-167 `session_lifetime_policy.md`) — same — authorization-token state.
- **Backup-code single-use** (per BOOK-175 `mfa_backup_codes_policy.md`) — same — credential state.
- **Bank-account IBAN canonical uniqueness** — counterparty-resolution concern (a vendor with one IBAN should resolve to one counterparty), handled by Block 08 vendor memory; not a dedup mechanism in the sense of "same data row inserted twice."

The unifying distinction: **dedup mechanisms operate on observation-of-the-same-data; the excluded mechanisms operate on credential-or-state-uniqueness.** Both involve UNIQUE constraints in some form; only the former belongs in this map.

---

## 9. Drift watchlist

Patterns where multiple docs currently disagree (rooted in this session's BOOK-170 / BOOK-188 / BOOK-190 / BOOK-193 / BOOK-194 drift items):

| Pattern | Drift item | Reconciliation status |
|---|---|---|
| `transactions_pattern_pgtrgm` | Fuzzy-match algorithm choice (pg_trgm here vs Jaro-Winkler in BOOK-172 `fuzzy_match_algorithm_policy.md`) | Open — Stage-6 must pick one algorithm or document which path uses which. Likely both legitimate (intake-time bulk pg_trgm vs scoring-time Jaro-Winkler per-pair). |
| `match_records_pair_dedup` | The "rejection-memory exclusion" path interacts with the 5 conflicting scoring docs from BOOK-170 / BOOK-190 (different signal-set definitions). | Open — depends on Stage-6 scoring-docs unified cleanup pass. |
| `split_payment_group_dedup` | The Pattern-A-vs-B exclusion rule (per BOOK-168) excludes `PROPOSED` and `CONFIRMED` but not `REJECTED` groups — verify against the actual shipped `split_payment_groups.status` enum at B10·P04 migration. | Open — Stage-6 schema verification. |
| `transactions_intake_fingerprint` | The fingerprint field-order and SHA-256 derivation here vs the live Block-07 migration. | Open — verify the live schema matches the documented derivation. |

When a watchlist item is reconciled, this row moves from "Open" to "Resolved" with the decision date.

---

## 10. Per-block owner contact

When a pattern needs changing, the consumer raises an issue against the owning phase's Plane ticket:

| Pattern | Plane ticket reference |
|---|---|
| `transactions_intake_fingerprint` | BOOK-56..65 (Block 07 phases) |
| `transactions_pattern_pgtrgm` | BOOK-86..95 (Block 10 phases) — specifically the P05 ticket |
| `match_records_pair_dedup` | BOOK-86..95 (Block 10 phases) — P02 |
| `vendor_memory_canonical_dedup` | BOOK-66..75 (Block 08 phases) — P03 |
| `documents_content_hash_dedup` | BOOK-76..85 (Block 09 phases) — P02 |
| `invoice_number_uniqueness` | BOOK-116..127 (Block 13 phases) — P04 |
| `split_payment_group_dedup` | BOOK-86..95 (Block 10 phases) — P04 |
| `audit_event_idempotency` | BOOK-24..33 (Block 05 phases) — P02 |
| `workflow_run_idempotency` | BOOK-34..44 (Block 03 phases) — P02 |
| `bulk_preview_token_single_use` | BOOK-128..137 (Block 14 phases) — P05 |

Stage 2+ will add an automated notification mechanism when a Plane ticket scope changes a pattern documented here. MVP relies on PR review across owning blocks.

---

## 11. Schema migration cross-link

For each pattern, the migration file(s) that materialised it. Useful for verifying the live PG schema state matches the documented pattern. Migration filenames are illustrative — verify against actual `supabase/migrations/` filenames at audit time.

| Pattern | Migration file(s) |
|---|---|
| `transactions_intake_fingerprint` | `YYYYMMDD_b07_p03_transactions_dedup_fingerprint.sql` |
| `transactions_pattern_pgtrgm` | `YYYYMMDD_b10_p05_pgtrgm_extension_enable.sql` + `YYYYMMDD_b10_p05_dedup_results_table.sql` |
| `match_records_pair_dedup` | `YYYYMMDD_b10_p02_match_records_schema.sql` |
| `vendor_memory_canonical_dedup` | `YYYYMMDD_b08_p03_recurring_vendor_memory.sql` |
| `documents_content_hash_dedup` | `YYYYMMDD_b09_p02_documents_schema.sql` |
| `invoice_number_uniqueness` | `YYYYMMDD_b13_p04_invoice_numbering.sql` |
| `split_payment_group_dedup` | `YYYYMMDD_b10_p04_split_payment_groups.sql` |
| `audit_event_idempotency` | `YYYYMMDD_b05_p02_audit_events_schema.sql` |
| `workflow_run_idempotency` | `YYYYMMDD_b03_p02_workflow_runs_schema.sql` |
| `bulk_preview_token_single_use` | `YYYYMMDD_b14_p05_bulk_preview_tokens.sql` |

Stage-6 polish: populate the actual migration filenames from `supabase/migrations/` listing once the 38 currently-shipped migrations are inventoried per pattern.

---

## 12. Cross-references

- `deduplication_policy.md` — `transactions_intake_fingerprint` mechanism
- `deduplication_fingerprint_schema.md` — fingerprint field-order DDL
- `tool_dedup_check.md` — `transactions_pattern_pgtrgm` SQL queries (BOOK-196 canonical pair)
- `dedup_result_schema.md` — dedup_results table
- `dedup_key_generator_policy.md` — fingerprint generator
- `internal_transfer_cross_workflow_dedup_policy.md` — cross-workflow dedup variant
- `rejection_memory_schema.md` (BOOK-166) — match-record rejection memory
- `match_records_schema.md` — pair-dedup composite key
- `vendor_memory_schema.md` — vendor canonical dedup
- `documents_schema.md` + `raw_uploads_schema.md` — document content-hash dedup
- `invoice_lifecycle_schema.md` + `invoice_numbering_policy.md` — invoice number uniqueness
- `split_payment_relationship_schema.md` (BOOK-168) + `split_payment_combinatorial_bounds.md` (BOOK-188) — split-payment group dedup
- `audit_log_policies.md` + `audit_event_payload_schemas.md` — audit idempotency
- `workflow_run_schema.md` — workflow-run idempotency
- `bulk_action_policies.md` + `bulk_preview_tokens_schema.md` — bulk-preview-token single-use
- `fuzzy_match_algorithm_policy.md` (BOOK-172) — fuzzy algorithm choices (drift watchlist §9)
- `Docs/decisions_log.md` — source of truth for pattern moves between blocks
- All owning-block phase docs per §10
