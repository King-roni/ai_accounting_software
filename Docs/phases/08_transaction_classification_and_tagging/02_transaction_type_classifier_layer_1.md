# Block 08 — Phase 02: Transaction Type Classifier (Layer 1 — Deterministic Rules)

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Layer 1 — Deterministic Rules)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 3 — AI assists, rules decide; Layer 1 is rules)

## Phase Goal

Build the deterministic rule engine that handles the high-confidence, easy cases at the very start of classification: same-owner transfers, bank fees, tax payments, recurring software subscriptions, and any business-specific rule the operator has set up. After this phase, the bulk of obvious classifications are made without invoking memory lookup or AI — they're decided by rules that anyone can read.

## Dependencies

- Phase 01 (`classification_rules` table)
- Block 04 Phase 02 (`transactions` table; this phase reads and updates classification columns)

## Deliverables

- **Default global rules** seeded at deployment:
  - **Same-owner account movement** (`OWN_ACCOUNT_TRANSFER` predicate) → `INTERNAL_TRANSFER`. Detected when both sides are bank accounts owned by the same business in `bank_accounts`.
  - **Revolut fee description** (`REGEX_DESCRIPTION` matching `^Fee|^Revolut Fee|^Card replacement`) → `BANK_FEE` + tag `Bank fee`.
  - **FX exchange marker** (set by Phase 04 of Block 07's normalization — `fx_paired_legs` populated) → `FX_EXCHANGE` + tag `Currency exchange`.
  - **Negative amount + counterparty domain in known supplier registry** → `OUT_EXPENSE`.
  - **Positive amount + counterparty in client registry** → `IN_INCOME`.
  - **Tax authority counterparty** (matches a curated list per country) → `TAX_PAYMENT` + tag `Tax payment`.
- **Per-business rules** — Owner can add/edit/disable rules via a settings UI. Each rule is scoped to the business and applies to its transactions.
- **Rule application engine:**
  - `applyRules(transaction, businessId) → RuleMatchResult[]`.
  - Evaluates all enabled rules in priority order (lower number = higher priority; per-business rules default to lower numbers than globals).
  - Returns the matched rule's `assigned_type`, `assigned_tag`, and a confidence score (`1.0` for exact match; `0.85` for fuzzy match like description regex with multiple captures).
- **Multiple-match handling:**
  - All matches against the **same** `assigned_type` reinforce the decision; final confidence is the max of the matched rules' confidences.
  - Matches against **different** `assigned_type`s are a **conflict**: no type is set, the transaction is flagged with a `classification.rule_conflict` review issue (`issue_group = 'Possible Wrong Match'`, severity `MEDIUM`) — a rule conflict is a configuration problem, closer in semantics to a wrong match than to a low-confidence confirmation. Layer 2/Layer 3 are not invoked for this transaction until the conflict is resolved.
- **Rule update API:**
  - `POST /classification-rules` (Owner only, step-up required) — adds a per-business rule.
  - `PUT /classification-rules/:id` — edits.
  - `DELETE /classification-rules/:id` — soft-disables (sets `enabled = false`); rules are never hard-deleted to preserve audit trail.
- **Outputs from this layer (in-memory only):**
  - On a clean rule match: returns a `Layer1Result` carrying the proposed `transaction_type`, optional `system_tag`, proposed `classification_method = RULE`, and the rule's confidence. **The actual writes to `transactions` happen in Phase 09's `assign_status` tool** — Layer 1 is a `READ_ONLY` tool that produces an in-memory proposal.
  - On no match: returns null; Layer 2 still runs (Phase 03 always runs for corroboration / vendor-memory updates).
- **Known supplier / client registries** (referenced by the `COUNTERPARTY_DOMAIN` rule) — these are seeded reference data populated alongside the default global rules. The seed list lives in a sub-doc and grows over time.
- **Audit events:** `CLASSIFICATION_RULE_MATCHED`, `CLASSIFICATION_RULE_CONFLICT`, `CLASSIFICATION_RULE_NO_MATCH` (silent — used for telemetry on rule coverage), `CLASSIFICATION_RULE_CREATED`, `CLASSIFICATION_RULE_UPDATED`, `CLASSIFICATION_RULE_DISABLED`.

## Definition of Done

- Standard transaction patterns (internal transfer, Revolut fee, FX exchange, tax payment) classify correctly with the default global rules.
- An Owner can add a per-business rule and it overrides the matching global on subsequent classifications.
- A transaction with conflicting rule matches lands in the review queue without a type assigned.
- Disabled rules are skipped.
- Tests cover at least one rule per `rule_kind`, plus the conflict path.
- The rule-update API requires Owner + step-up.

## Sub-doc Hooks (Stage 4)

- **Default global rules sub-doc** — the seeded rule list, predicate JSONB per rule, refresh procedure when patterns change.
- **Rule predicate evaluation sub-doc** — how each `rule_kind` is evaluated; performance characteristics; index strategy.
- **Per-business rule UI sub-doc** — settings panel layout, validation, conflict prevention.
- **Conflict resolution sub-doc** — review-issue template, resolution actions, learning-from-resolution back into the rule set.
