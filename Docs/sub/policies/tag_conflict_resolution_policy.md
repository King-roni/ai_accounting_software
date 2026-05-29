# Tag Conflict Resolution Policy

**Category:** Policies · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

Governs how conflicts are resolved when multiple classification sources assign different tags to the same transaction. The policy defines the priority chain, the manual override lock, the rule-specificity tie-break, and the conditions under which a conflict is escalated to the review queue.

---

## Conflict definition

A conflict occurs when two or more tags of the same `tag_type` are assigned to the same transaction from different sources. Tags of different types (e.g. a CATEGORY tag and a COST_CENTRE tag) do not conflict with each other — each tag_type has an independent active classification result.

A conflict is detected at write time by `classification.apply_tags`. If a new tag assignment would displace the current active tag for a given `tag_type`, the resolution rules below apply before any row is committed.

---

## Source priority order

Highest priority to lowest:

1. `MANUAL_OVERRIDE` — explicit assignment by an accountant or Owner
2. `RULE_MATCH` — deterministic rule engine result
3. `AI_CONFIRMED` — AI classification confirmed by accountant
4. `AI_PROPOSED` — AI classification, unconfirmed
5. `VENDOR_MEMORY` — tag derived from a prior confirmed vendor pattern

The highest-priority source always wins. A tag from a lower-priority source is retained in the tag history (in `transaction_tag_history`) but is not set as the active classification result in `classification_result`.

---

## Manual override lock

When `MANUAL_OVERRIDE` is the active source for a given `(transaction_id, tag_type)`, no automated process may overwrite it. This includes:
- The rule engine re-run
- AI re-classification triggered by a data change
- Vendor memory updates

The lock persists until an accountant explicitly clears it. Clearing the override is an accountant-level action that emits `CLASSIFICATION_MANUAL_OVERRIDE_SET` (LOW) with `action = CLEARED`. Once cleared, the tag_type re-enters normal priority evaluation.

The lock is enforced in `classification.apply_tags` before any write. An attempted overwrite of a locked MANUAL_OVERRIDE returns `CLASSIFICATION_OVERRIDE_LOCKED` to the caller without modifying any rows.

---

## Rule conflict tie-break

When two `RULE_MATCH` sources assign different tags to the same `(transaction_id, tag_type)`, the rule with the higher specificity score wins. Specificity is calculated from the rule definition — a rule that matches on more conditions (e.g. exact counterparty + amount range + description keyword) has a higher specificity than a rule that matches on fewer conditions (e.g. counterparty only).

If two RULE_MATCH sources have equal specificity scores, the conflict cannot be resolved automatically. It is surfaced as a `CLASSIFICATION_TAG_CONFLICT_ESCALATED` (MEDIUM) review issue in the review queue. The reviewing accountant resolves it by either confirming one of the proposed tags or applying a MANUAL_OVERRIDE. Until resolved, the existing active tag (if any) is retained; no change is made to `classification_result`.

---

## Audit trail

Every tag assignment and displacement is recorded. The `classification_result` column always reflects the current winning tag for a given `(transaction_id, tag_type)`. The full history of all assignments, displacements, and their sources is in `transaction_tag_history` per `transaction_tag_columns_schema.md`.

The audit trail must never be modified retroactively. If an error in a prior classification is corrected via MANUAL_OVERRIDE, the correction appears as a new entry in the history, not as an edit to the prior entry.

---

## Re-classification on data change

When a re-classification is triggered by a data change (e.g. the vendor memory for a counterparty is updated, or a classification rule is modified), the priority chain is re-evaluated from scratch for all affected transactions. The re-evaluation:

1. Collects all current active tag assignments for the transaction across all sources.
2. Applies the priority order to determine the winning source.
3. Checks for MANUAL_OVERRIDE lock before allowing any displacement.
4. Writes the new `classification_result` if it differs from the current one.
5. Emits `CLASSIFICATION_TAG_CONFLICT_RESOLVED` (LOW) if a previous conflict is now resolved by the re-evaluation, or creates a new `MATCH_REVIEW` issue if a new conflict is introduced.

Re-classification does not clear the vendor memory staleness status. Stale vendor memory entries remain stale after re-classification; their tags are re-applied at `VENDOR_MEMORY` priority, which means a RULE_MATCH or higher-priority source can still displace them.

---

## Conflict escalation conditions

A conflict is escalated to the review queue (`CLASSIFICATION_TAG_CONFLICT_ESCALATED`, MEDIUM) when:
- Two RULE_MATCH sources have equal specificity scores for the same `(transaction_id, tag_type)`
- A RULE_MATCH result conflicts with a MANUAL_OVERRIDE that has been explicitly cleared but not yet replaced by a new accountant action

Escalated conflicts are surfaced as `CLASSIFICATION_CONFLICT` review issues. They block the enclosing run from advancing from REVIEW_HOLD until resolved.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `CLASSIFICATION_TAG_CONFLICT_RESOLVED` | LOW | A conflict is resolved via the priority chain or accountant action |
| `CLASSIFICATION_TAG_CONFLICT_ESCALATED` | MEDIUM | Two RULE_MATCH sources tie and no automatic resolution is possible |
| `CLASSIFICATION_MANUAL_OVERRIDE_SET` | LOW | A MANUAL_OVERRIDE tag is set or explicitly cleared by an accountant |

`CLASSIFICATION_TAG_CONFLICT_RESOLVED` carries `transaction_id`, `business_id`, `tag_type`, `winning_source`, `displaced_source`, `winning_tag`, `displaced_tag`, and `run_id`.
`CLASSIFICATION_TAG_CONFLICT_ESCALATED` carries `transaction_id`, `business_id`, `tag_type`, `conflicting_sources`, `conflicting_tags`, `rule_ids`, and `run_id`.
`CLASSIFICATION_MANUAL_OVERRIDE_SET` carries `transaction_id`, `business_id`, `tag_type`, `tag`, `action` (`SET` or `CLEARED`), and `actor_user_id`.

---

## Cross-references

- `classification_rule_schema.md` — rule specificity score computation
- `transaction_tag_columns_schema.md` — transaction_tag_history table and classification_result column
- `vendor_memory_staleness_policy.md` — staleness lifecycle for VENDOR_MEMORY source tags
- `review_queue_rescan_on_resolution_policy.md` — how resolved conflicts trigger review queue rescans
- `audit_event_taxonomy` — canonical event catalogue for CLASSIFICATION domain events
- `data_layer_conventions_policy` — canonical JSON serialization for audit payloads

---

## Design rationale

**Why a strict priority chain rather than a merge or voting model?** A merge model requires a domain-specific merge function per tag_type, and accounting categorisation does not have a natural merge semantic — a transaction cannot be both a TRAVEL expense and an OFFICE_SUPPLIES expense. A voting model introduces non-determinism across re-runs. The strict priority chain is deterministic, auditable, and matches the accountant's mental model: their explicit action always wins, followed by the rule engine, followed by AI results.

**Why retain lower-priority tags in history?** The audit trail must be complete. Displacing a lower-priority tag without recording it would make it impossible to reconstruct why a transaction was re-classified after a rule change or a vendor memory update. The history also enables operators to diagnose classification drift across bulk re-classification events.

**Why escalate equal-specificity rule ties rather than choosing by insertion order?** Insertion order is not a business-meaningful tie-break. Two rules with equal specificity represent a configuration conflict that a human should resolve. Silently choosing by insertion order would hide a rule configuration defect.

---

## Relationship to run_status_enum

Unresolved `CLASSIFICATION_CONFLICT` review issues (escalated by this policy) hold the run in REVIEW_HOLD. The run cannot advance to AWAITING_APPROVAL until all such issues are resolved. Runs in COMPENSATING status re-queue conflict resolution by rolling back `classification_result` to the last committed value before the conflicting classification phase.

---

## Open items deferred to later sub-docs

- Bulk conflict resolution UI for accountants with many tied-rule conflicts — Block 08 Phase 05
- Rule specificity score computation details — `classification_rule_schema.md`
- Cross-period re-classification impact on locked ledger entries — Block 11 Phase 07

## Interaction with vendor memory staleness

When a VENDOR_MEMORY source tag is marked stale (per `vendor_memory_staleness_policy.md`), its `tag_type` entry in `classification_result` is not immediately cleared. The stale tag remains the active result until a higher-priority source provides a replacement. This means a stale vendor memory tag can persist through multiple run cycles if no rule or AI source produces a competing tag for the same transaction. If the stale entry is later pruned, the `classification_result` for `VENDOR_MEMORY`-only tags is cleared and the transaction is re-queued for classification.

## Scope: tag_type vs. tag_value conflicts

This policy governs tag_type-level conflicts — where two sources disagree on which tag value to assign to the same tag_type. It does not govern tag_value taxonomy conflicts (e.g. a tag value being renamed or retired), which are handled by `classification_rule_schema.md` and the tag taxonomy version system. A tag_value retirement does not trigger the conflict resolution chain; it triggers a bulk re-tagging via the taxonomy version bump process instead.

Finally, note that `AI_CONFIRMED` sits above `AI_PROPOSED` in the priority chain specifically to preserve an accountant's prior confirmation when a new AI re-run produces a different proposal. Without this ordering, a background AI re-run could silently displace a prior accountant confirmation, which is indistinguishable from the engine overriding human judgement.
The `AI_CONFIRMED` priority above `AI_PROPOSED` also means that if an accountant confirms a Layer 2 result and the system later runs Layer 3, the Layer 3 proposal does not automatically become the active result — it is recorded as `AI_PROPOSED` and sits below the confirmed result until the accountant reviews and confirms or rejects it.
