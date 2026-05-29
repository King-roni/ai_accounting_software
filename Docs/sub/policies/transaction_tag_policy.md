# Transaction Tag Policy

**Category:** Policies · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

This is the binding policy for how structured tags are applied to, amended on, and removed from transactions. Tags are the user-facing label layer that sits on top of the internal `transaction_type_enum`; the internal type code is never rendered to users (Block 08 Principle 5). Tags govern the ledger path in Block 11 and drive analytics reporting in Block 16. This policy states who may apply or remove tags, which tools own tag writes, and which tags carry special semantics.

Every tagging operation must be traceable to a specific actor, a specific workflow run, and a specific reason. The audit requirement for tagging is non-negotiable.

---

## Definitions

**Primary tag** — the single required tag that drives the ledger path and transaction type mapping. Stored in `transactions.system_tag` (system-assigned) or `transactions.user_tag` (owner/admin override). Exactly one primary tag per transaction at any point in time.

**Secondary tags** — zero or more optional labels stored in `transactions.secondary_tags` (JSONB array). Secondary tags are analytics-only; they carry no ledger effect, no VAT treatment implication, and no classification consequence.

**Tag taxonomy** — the versioned set of permitted tag values. The active taxonomy is resolved from `business_tag_taxonomy_assignments` for each business. Tags may only be drawn from the currently active taxonomy version; no tag outside the active version may be applied.

**Tag taxonomy version** — a named, immutable snapshot of the permitted tag set, tracked in `tag_taxonomy_versions`. The version active at classification time is snapshot-pinned to the ledger entry for finalized periods.

---

## Rule 1 — Tags are additive

A transaction may carry zero secondary tags or any number of secondary tags. The primary tag is always present (the classification pipeline ensures a fallback assignment; see Block 08 Phase 05). Secondary tags may accumulate over time without replacing each other; adding a secondary tag never removes an existing one unless the user explicitly removes it. Tag operations are append-by-default.

## Rule 2 — Active taxonomy version only

Only tags from the currently active `tag_taxonomy_version` for the business may be applied. The active version is resolved at classification time and at every manual tag operation. If the taxonomy version changes after a tag was applied but before the period is finalized, existing applied tags remain valid — they reference the version under which they were applied. Finalized periods are immune to taxonomy version changes per Block 15 finalization invariants.

## Rule 3 — Single writer: `classification.apply_tags`

The `classification.apply_tags` tool is the only authorised writer for tag operations on `transactions`. This follows the proposer + single-writer pattern per `tool_atomicity_policy`:

- The proposer pattern applies for Owner/Admin manual tag actions: the UI presents the proposed tag; the user confirms; `classification.apply_tags` executes the write.
- The single-writer pattern applies for automated tag assignment: classifier layers propose a tag internally; `classification.apply_tags` is the tool that performs the final write.
- No other code path may write directly to `transactions.system_tag`, `transactions.user_tag`, or `transactions.secondary_tags`. Direct writes outside this tool are rejected at the application layer.

Tool declaration (per `tool_naming_convention_policy`):

```
classification.apply_tags
  side_effect_class: [WRITES_RUN_STATE, WRITES_AUDIT]
  ai_tier: NONE
```

## Rule 4 — Sources authorised to apply tags

Tags may be applied by exactly three authorised sources:

1. **Layer 1 rule match** — a classification rule that includes a tag condition pins the tag as part of the Layer 1 decision. The rule's tag value must be a valid member of the active taxonomy.
2. **Layer 3 AI suggestion** — the AI fallback classifier may suggest a tag as part of its classification response. The suggestion is validated against the active taxonomy before application; invalid AI tag suggestions are discarded and the type's default tag is used as fallback.
3. **Owner or Admin manual action** — via the review queue or the transaction detail panel, an Owner or Admin may amend a primary tag or add/remove secondary tags. The change is executed by `classification.apply_tags` after the user confirms the proposed change.

Layer 2 (vendor memory) carries a `suggested_tag` field per Block 08 Phase 05. The vendor memory tag feeds into the tag proposal; `classification.apply_tags` executes the write.

Reviewer and Bookkeeper roles may not write tags. Read-only roles may not write tags.

## Rule 5 — Tag amendments during review queue resolution

Tags applied during the classification phase may be amended during review queue resolution by an Owner or Admin. The amendment path is: the reviewer proposes a new primary tag in the review queue card; the Owner or Admin confirms; `classification.apply_tags` executes the write. The amendment replaces the previous primary tag and sets `transactions.user_tag` (signalling an override of the system-assigned tag). Both the old and new tag values are captured in the `CLASSIFICATION_USER_RECLASSIFIED` audit event payload.

Secondary tags may be added at any time during review queue resolution. Secondary tag additions are captured in the audit trail.

## Rule 6 — Tag removal

Tag removal requires Owner or Admin role. The removal of a primary tag is not permitted while the transaction is unclassified — the transaction must have a replacement primary tag proposed simultaneously. Secondary tag removal is permitted at any time prior to period finalization.

All tag removal operations emit:

| Event | Severity |
|---|---|
| `TRANSACTION_TAG_REMOVED` | LOW |

The audit payload includes `transaction_id`, `business_id`, `removed_tag`, `tag_kind` (`PRIMARY` or `SECONDARY`), `removed_by_user_id`, and `workflow_run_id`.

## Rule 7 — `INTERNAL_TRANSFER` tag: special semantics

The `INTERNAL_TRANSFER` tag carries special semantics that differ from all other tags:

- **VAT treatment suppression.** When a transaction carries the `INTERNAL_TRANSFER` primary tag, the VAT treatment is set to `OUTSIDE_SCOPE` and the ledger preparation layer (Block 11) does not compute a VAT amount for the entry. Any VAT treatment previously suggested by the classifier is overridden.
- **Ledger account suggestion suppression.** The ledger preparation layer does not suggest a standard expense or income account for an `INTERNAL_TRANSFER` transaction. The entry uses the internal transfer accounts from the chart of accounts as configured in `chart_of_accounts_mappings`.
- **Match bypass.** The matching engine (Block 10) does not evaluate `INTERNAL_TRANSFER` transactions as invoice-matching candidates.
- **Bilateral linking.** When two transactions are tagged `INTERNAL_TRANSFER` and their amounts and dates align (same amount, opposite direction, within the configured date window), the end-scan engine (Block 06 Phase 11) emits an `INTERNAL_TRANSFER_DETECTED` finding and Block 11 links them via `INTERNAL_TRANSFER_BILATERAL_LINKED`.

No other tag carries ledger-level or matching-level suppression semantics in MVP. Any future tag requiring similar treatment requires a `decisions_log.md` amendment before implementation.

## Rule 8 — No tag changes after finalization

Tag changes are prohibited for transactions whose period has been finalized. The period lock (Block 15) prevents writes to `transactions` rows in the locked period. Any attempt to apply, amend, or remove a tag on a finalized transaction is rejected at the application layer and logged as `MANUAL_OVERRIDE_REJECTED_FINALIZED_PERIOD`.

---

## Mobile write rejection

The `classification.apply_tags` tool is a server-side workflow tool. Mobile clients may view tags through read-only surfaces but cannot execute tag write operations directly. Any direct write attempt to tag columns from a mobile client is rejected per `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | Severity | Emitted by |
|---|---|---|
| `CLASSIFICATION_LAYER_1_DECIDED` | LOW | Layer 1 classifier (includes tag decision) |
| `CLASSIFICATION_LAYER_2_DECIDED` | LOW | Layer 2 vendor memory (includes tag) |
| `CLASSIFICATION_LAYER_3_DECIDED` | LOW | Layer 3 AI fallback (includes tag) |
| `CLASSIFICATION_USER_CONFIRMED` | LOW | Owner/Admin confirms classification |
| `CLASSIFICATION_USER_RECLASSIFIED` | LOW | Owner/Admin overrides primary tag |
| `TRANSACTION_TAG_REMOVED` | LOW | Owner/Admin removes a tag |

All events are emitted via `emitAudit()` per `audit_log_policies`. Events exist in `audit_event_taxonomy` under the `CLASSIFICATION` domain.

---

## Tag conflict resolution

When two classification sources assign conflicting primary tags for the same transaction (e.g., a Layer 1 rule assigns `OFFICE_SUPPLIES` while a Layer 3 AI suggestion assigns `PROFESSIONAL_SERVICES`), the resolution order is:

1. **Layer 1 rule match wins** — if a Layer 1 rule fires for this transaction and includes a tag assignment, that tag is used and no other source can override it at classification time.
2. **Layer 2 vendor memory** — if no Layer 1 tag is present and vendor memory carries a `suggested_tag`, vendor memory takes precedence over Layer 3.
3. **Layer 3 AI suggestion** — used only when neither Layer 1 nor Layer 2 produced a tag.
4. **User override** — an Owner or Admin manual action always wins, regardless of which automated source originally assigned the tag. A user override sets `transactions.user_tag` and records `CLASSIFICATION_USER_RECLASSIFIED`.

Conflicts between secondary tags do not arise by definition — secondary tags are additive and non-exclusive.

## Mobile write rejection note

All tag write operations (primary tag assignment, secondary tag add/remove, user override) are blocked on mobile clients per `mobile_write_rejection_endpoints.md`. The `classification.apply_tags` tool checks `client_form_factor` before executing any write and returns `MOBILE_WRITE_REJECTED` if the request originates from a mobile session. Mobile clients may read tag values through the transaction detail read surface.

## Cross-references

- `tag_taxonomy_version_schema` — versioned tag taxonomy; active version resolution; version snapshot at finalization
- `transaction_tag_columns_schema` — `transactions.system_tag`, `transactions.user_tag`, `transactions.secondary_tags` column definitions (Layer 1 schema contract)
- `tool_atomicity_policy` (Block 03) — proposer + single-writer pattern; `classification.apply_tags` is the designated single writer
- `tool_naming_convention_policy` — `classification.apply_tags` tool name; `classification.*` namespace
- `classification_output_schema` — the Processing-zone record that carries the tag suggestion before promotion
- `vendor_memory_schema` — `suggested_tag` field on vendor memory entries; Layer 2 tag source
- `confidence_score_schema` — confidence object produced alongside the tag decision
- `audit_log_policies` — `CLASSIFICATION_*` domain; `TRANSACTION_TAG_REMOVED` event naming
- `audit_event_taxonomy` — `CLASSIFICATION_USER_RECLASSIFIED`, `TRANSACTION_TAG_REMOVED`
- Block 08 Phase 02 — Layer 1 rule-based classifier; tag-pinning rules
- Block 08 Phase 03 — Layer 2 vendor memory; `suggested_tag` on memory entries
- Block 08 Phase 04 — Layer 3 AI fallback; tag suggestion from AI response
- Block 08 Phase 05 — tag system and default taxonomy; primary and secondary tag semantics; default fallback assignment
- Block 08 Phase 08 — tag taxonomy versioning; immutable version snapshots
- Block 11 Phase 05 — VAT treatment classifier; reads primary tag; `INTERNAL_TRANSFER` tag suppresses VAT treatment
- Block 14 — review queue; Owner/Admin tag amendment surface
- Block 15 Phase 03 — period finalization and locking; prohibits tag changes post-lock
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
