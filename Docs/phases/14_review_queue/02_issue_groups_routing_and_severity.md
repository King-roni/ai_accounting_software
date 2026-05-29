# Block 14 — Phase 02: Issue Groups & Routing Table + Severity Levels

## References

- Block doc: `Docs/blocks/14_review_queue.md` (The Six Issue Groups; Severity Levels)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 5 — Simple Interface; six fixed buckets)
- Decisions log: `Docs/decisions_log.md` (Stage 2 amendment 2026-05-08 — severity enum corrected to `{LOW, MEDIUM, HIGH, BLOCKING}`)

## Phase Goal

Pin the canonical taxonomies Block 14 owns: the six fixed `issue_group` buckets and the four-value `severity` enum. Define the routing table (`issue_type → issue_group`) and the registration mechanism upstream blocks (06/07/08/10/11/13) use to declare new `issue_type` strings and which bucket they land in. After this phase, every issue raised anywhere in the system has an unambiguous bucket and severity.

## Dependencies

- Phase 01 (`review_issues` schema extensions)
- Block 04 Phase 04 (the `review_issues` table; existing `issue_type`, `issue_group`, `severity` columns)
- Block 02 Phase 04 (permission matrix — surfaces from Phase 01)
- Block 06 Phase 11 (End-Scan engine — one of the upstream issue producers)
- Block 07 Phase 05 (dedup engine — `DUPLICATE_POSSIBLE`, `NEEDS_REVIEW` issues)
- Block 08 Phase 09 (classification — `UNKNOWN`-type, `RULE_CONFLICT`)
- Block 10 Phase 09 (matching — `Missing Documents`, `Possible Wrong Match`, `Needs Confirmation`)
- Block 11 Phase 09 (ledger / VAT — `Possible Tax/VAT Issue`, `Missing Documents`)
- Block 13 Phase 12 (invoice anomalies — `Possible Wrong Match`, `Possible Tax/VAT Issue`)

## Deliverables

- **`issue_group` enum — five actionable values (canonical, stored in Postgres ENUM on `review_issues.issue_group`):**
  ```
  Missing Documents
  Needs Confirmation
  Possible Wrong Match
  Possible Tax/VAT Issue
  Unusual Transaction
  ```
  - Block 04 Phase 04 owns the column type; this phase pins the five values. `review_issues.issue_group` is constrained to exactly these five.
- **Sixth UI bucket — `Ready to Finalize` (queue-state projection, NOT an enum value):**
  - The architecture-doc "six buckets" includes `Ready to Finalize` as a green-light state. **It is NOT a value in the ENUM** — no `review_issues` row ever carries this group. It is a UI-layer projection computed at view time as: "all five actionable buckets have zero open blocking issues for this run".
  - When the projection condition is true, the queue surfaces the `Ready to Finalize` card per the rendering rule below; otherwise the card is hidden.
- **Four `severity` values (closed enum; canonical, per the decisions-log amendment):**
  ```
  LOW       — informational; doesn't block; can be deferred to next run via snooze
  MEDIUM    — should be reviewed; doesn't block finalization; snoozable
  HIGH      — should be resolved; blocks unless user documents an exception; cannot be snoozed
  BLOCKING  — must be resolved; finalization gate refuses to advance; cannot be snoozed
  ```
  - **No `CRITICAL` value exists** — the prior drift in some phase docs (Block 12 Phase 05/07, Block 13 Phase 09) was corrected via the 2026-05-08 decisions-log amendment. Any phase doc still referring to `CRITICAL` severity is incorrect.
- **`issue_type → issue_group` routing table** — owned by this phase; consumed by every upstream block when raising an issue:
  - The table is a per-`issue_type` row in a `issue_type_registry` table (Phase 01 deliverable; declared as a Postgres table) with the registration mechanism `registerIssueType({ issue_type, default_group, default_severity, allowed_resolution_actions, producing_block, plain_language_template_ref, validity_check_fn_ref? })`.
  - Adding a new `issue_type` always declares which `issue_group` it belongs to. `review_issues.issue_type` carries a deferred FK to `issue_type_registry.issue_type` — issues with an unregistered `issue_type` are rejected at insertion by FK violation.
  - **Namespacing convention (canonical):** `issue_type` strings follow the format `<block_short_name>.<check_name>` in lowercase snake_case (e.g., `endscan.unusual_amount`, `matching.no_match_out_expense`, `ledger.missing_required_evidence`). Each producing block registers its `issue_type` strings at boot using this convention; coordinated edits to producing-block phase docs land via the sub-doc-stage updates.
  - **Stage 1 illustrative mappings** (representative subset; the canonical exhaustive table is the sub-doc artifact assembled from each producing block's `registerIssueType` calls — not a Block 14 owned list):

    | Producing block | Example `issue_type` | `issue_group` | Default `severity` |
    | --- | --- | --- | --- |
    | Block 06 (End-Scan) | `endscan.unusual_amount` | `Unusual Transaction` | `MEDIUM` |
    | Block 06 (End-Scan) | `endscan.large_outlier` | `Unusual Transaction` | `HIGH` |
    | Block 07 (dedup) | `dedup.possible_duplicate` | `Possible Wrong Match` | `MEDIUM` |
    | Block 07 (dedup) | `dedup.needs_review` | `Possible Wrong Match` | `MEDIUM` |
    | Block 08 (classify) | `classification.unknown_type` | `Possible Wrong Match` | `BLOCKING` (per architecture line 82 — `UNKNOWN`-classified is one of the canonical BLOCKING cases) |
    | Block 08 (classify) | `classification.rule_conflict` | `Possible Wrong Match` | `HIGH` |
    | Block 10 (matching) | `matching.no_match_out_expense` | `Missing Documents` | `HIGH` |
    | Block 10 (matching) | `matching.possible_match` | `Needs Confirmation` | `MEDIUM` |
    | Block 10 (matching) | `matching.matched_needs_confirmation` | `Needs Confirmation` | `MEDIUM` |
    | Block 10 (matching) | `matching.split_payment_proposal` | `Possible Wrong Match` | `MEDIUM` |
    | Block 10 (matching) | `matching.document_used_multiple_times` | `Possible Wrong Match` | `HIGH` |
    | Block 10 (matching) | `matching.transaction_multi_match` | `Possible Wrong Match` | `HIGH` |
    | Block 11 (VAT/ledger) | `ledger.accountant_review_unknown_treatment` | `Possible Tax/VAT Issue` | `HIGH` |
    | Block 11 (VAT/ledger) | `ledger.tag_mismatch_detected` | `Possible Tax/VAT Issue` | `MEDIUM` |
    | Block 11 (VAT/ledger) | `ledger.missing_required_evidence` | `Missing Documents` | `HIGH` |
    | Block 11 (VAT/ledger) | `ledger.vies_vat_number_missing` | `Possible Tax/VAT Issue` | `MEDIUM` |
    | Block 13 (invoice) | `invoice.numbering_gap_detected` | `Possible Wrong Match` | `HIGH` |
    | Block 13 (invoice) | `invoice.duplicate_payment_against_same_invoice` | `Possible Wrong Match` | `MEDIUM` |
    | Block 13 (matching) | `matching.multi_invoice_one_payment` | `Possible Wrong Match` | `MEDIUM` |
    | Block 13 (matching) | `matching.possible_refund_or_transfer` | `Possible Wrong Match` | `MEDIUM` |
    | Several | `*.duplicate_invoice_claim_across_transactions` | `Possible Wrong Match` | `BLOCKING` |
- **Severity → finalization gating contract** (consumed by Block 12 Phase 05's `gate.out.ai_end_scan_complete` and Block 13 Phase 09's `gate.in.ai_end_scan_complete`):
  - **Blocking issues** = `severity ∈ {HIGH, BLOCKING}` AND `status = OPEN`. Both gates use this exact predicate.
  - `MEDIUM` / `LOW` issues do NOT block, but `MEDIUM` ones strongly suggest review.
  - `HIGH` can be cleared by **documented exception** (`out_workflow.document_exception` for Block 12; Phase 04's resolution actions for other types). `BLOCKING` cannot be exception-cleared — the underlying problem must be fixed.
- **`Ready to Finalize` group rendering:**
  - When all five work-item groups are empty for a run, the queue UI surfaces a single `Ready to Finalize` card with the run summary and a "Record approval" button. Click-through invokes the run's per-workflow user-approval tool (`out_workflow.user_approval` for OUT runs per Block 12 Phase 07, `in_workflow.user_approval` for IN runs per Block 13 Phase 09). Block 15's `FINALIZATION` phase runs as a downstream effect once the approval-driven gate clears — Block 14 does not invoke Block 15 directly.
  - The card itself is NOT a `review_issues` row — it's a queue-state projection. `Ready to Finalize` is therefore NOT a value in the `review_issues.issue_group` ENUM (which is reduced to five actionable buckets per the H8 fix); the projection is computed at view time.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `REVIEW_QUEUE`):
  - `REVIEW_ISSUE_TYPE_REGISTERED` (boot; one per `registerIssueType` call)
  - `REVIEW_ISSUE_RAISED` (declared in Block 04 Phase 04; emitted by upstream blocks at insertion; payload includes resolved `issue_group` and `severity`)
  - `REVIEW_ISSUE_TYPE_REJECTED` (when an unregistered `issue_type` is attempted at insertion)

## Definition of Done

- The five actionable `issue_group` values are pinned in a closed enum; an attempt to insert a `review_issues` row with any value outside the five (including `Ready to Finalize`) is rejected. A test verifies no row exists with `issue_group = 'Ready to Finalize'`.
- The four `severity` values are pinned; no `CRITICAL` anywhere.
- The `issue_type` registration mechanism rejects unregistered types at insertion.
- The Stage 1 canonical mapping table covers every issue type currently produced by Blocks 06–13.
- The blocking-issue predicate (`severity ∈ {HIGH, BLOCKING}` AND `status = OPEN`) is used identically by Block 12 Phase 05's gate and Block 13 Phase 09's gate.
- A test verifies that an `endscan.unusual_amount` issue raised by Block 06 lands in `Unusual Transaction` with severity `MEDIUM`.
- A test verifies that a `BLOCKING`-severity issue blocks both OUT and IN finalization gates.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Full `issue_type → issue_group` routing table sub-doc** — exhaustive list across all producing blocks; per-row `default_severity` + `allowed_resolution_actions`.
- **`registerIssueType` registration mechanism sub-doc** — exact JSON / TypeScript shape; boot-time vs runtime registration.
- **Per-business severity override sub-doc (deferred Stage 2+)** — letting a business escalate certain `MEDIUM` to `HIGH` for stricter compliance.
- **`Ready to Finalize` queue-state-projection sub-doc** — exact UI rendering; card content; click-through to Block 15's finalization flow.
- **`BLOCKING`-severity catalog sub-doc** — the exhaustive list of cases that warrant `BLOCKING` (e.g., `UNKNOWN`-classified transaction, failed mandatory VAT classification, duplicate-invoice claim across transactions, missing chart-mapping for an entry).
