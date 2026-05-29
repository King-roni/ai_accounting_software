# classification_rule_predicate_schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the full `classification_rules` table and the exact shape of its `predicate` JSONB column for each `rule_kind`. The predicate is the discriminating payload that the Layer 1 classifier evaluates against each transaction. Per Block 01 Principle 3 (Rules Decide), classification rules are deterministic and evaluated before any AI layer is invoked. Adding a new `rule_kind` requires a schema migration and a test-corpus addition; no `rule_kind` is removed in MVP.

---

## Classification rules table

The `classification_rules` table DDL is defined in `classification_rule_schema.md`. This file defines the predicate and condition structures that attach to classification rules.

The `rule_kind_enum` type used in classification rule predicates has the following values:

```sql
CREATE TYPE rule_kind_enum AS ENUM (
  'COUNTERPARTY_EXACT',
  'COUNTERPARTY_PATTERN',
  'AMOUNT_RANGE',
  'DESCRIPTION_CONTAINS',
  'BANK_FEE_MARKER',
  'TRANSACTION_TYPE_OVERRIDE'
);
```

---

## Predicate shapes per `rule_kind`

All predicate objects use canonical JSON key ordering per `data_layer_conventions_policy §3` in storage; the validation layer normalizes key order before computing any hash.

### `COUNTERPARTY_EXACT`

Matches transactions whose `counterparty_signature` exactly equals the provided string after the vendor-signature normalization pass (Block 08 Phase 03).

```json
{
  "counterparty": "<normalized counterparty signature string>"
}
```

**Validation rules:**
- `counterparty` is required, non-empty string.
- Maximum length: 500 characters.
- Value is stored post-normalization (the normalization function is called by `classification.validate_rule_predicate` at rule creation time, not at evaluation time).

---

### `COUNTERPARTY_PATTERN`

Matches transactions whose `counterparty_signature` matches the provided regular expression.

```json
{
  "pattern": "<regex string>",
  "flags": "<regex flags string>"
}
```

**Validation rules:**
- `pattern` is required, non-empty string.
- `flags` is required; valid values: any combination of `i` (case-insensitive), `s` (dot-all). No other flags permitted in MVP (the `g` and `m` flags are not applicable for single-match evaluation; `u` is always on by default).
- The pattern must compile without error at validation time (tested via a dry-run compile in `classification.validate_rule_predicate`).
- Maximum pattern length: 1000 characters.

---

### `AMOUNT_RANGE`

Matches transactions whose `amount_signed` (in minor units, account currency) falls within the specified range. The range is inclusive on both bounds.

```json
{
  "min": 500,
  "max": 100000,
  "currency": "EUR"
}
```

**Validation rules:**
- `currency` is required; must be a valid ISO 4217 3-letter code.
- At least one of `min` or `max` must be present. Both may be present.
- `min` and `max` are integers (minor units). Floating-point amounts are rejected per `data_layer_conventions_policy §3` currency special case.
- `min` ≤ `max` when both are provided (enforced at validation).
- Sign convention: negative values for outgoing (expense); positive for incoming (income). Rules covering expenses should use negative `min`/`max` values.

---

### `DESCRIPTION_CONTAINS`

Matches transactions whose `normalized_description` contains all terms in the provided array (AND semantics — all terms must be present).

```json
{
  "terms": ["aws", "amazon web services"]
}
```

**Validation rules:**
- `terms` is required; must be a non-empty array.
- Each element is a non-empty string, maximum 200 characters.
- Array maximum length: 10 terms.
- Matching is case-insensitive (comparison is `ilike '%term%'` against `normalized_description`).
- All terms must match (AND). OR semantics require multiple rules with the same `result_transaction_type` and adjacent priorities.

---

### `BANK_FEE_MARKER`

Triggered by bank-specific structural markers in the parsed row that indicate a fee (e.g., Revolut's fee-category fields in the CSV, or a zero-counterparty row with a negative amount below a threshold). No parameters.

```json
{}
```

**Validation rules:**
- Predicate must be the empty object `{}`. Any other value is rejected.
- The marker set is maintained internally by Block 07 Phase 03's format-specific parser; this rule kind delegates to that parser's fee-detection output. The rule itself carries no configuration.

---

### `TRANSACTION_TYPE_OVERRIDE`

Forces the transaction type regardless of other rule matches. Used for cases where a specific counterparty or description pattern should always resolve to a particular type, bypassing the normal classifier path.

```json
{
  "force_type": "BANK_FEE"
}
```

**Validation rules:**
- `force_type` is required; must be one of the 12 values from `transaction_type_enum` (closed — do not add values).
- `UNKNOWN` is not a valid `force_type`; a rule cannot force a transaction into the unclassified state (that would defeat the purpose of the rules engine).

---

## Rule evaluation order

Per-business rules (non-null `business_id`) are always evaluated before global rules even when their `priority` integer is higher. Within each group, rules are sorted `priority ASC, rule_id ASC`. First matching rule wins. If no rule matches, the classifier proceeds to Layer 2 (vendor memory) and Layer 3 (AI).

---

## Evolution policy

New `rule_kind` values require: a schema migration adding the value to `rule_kind_enum`, a validation branch in `classification.validate_rule_predicate`, and a test-corpus addition covering the new kind across at least five transaction fixtures. No new kinds are added in MVP without a `decisions_log.md` amendment. Old `rule_kind` values are never removed in MVP. Predicate shape changes within an existing `rule_kind` are additive-only: new optional fields may be added; existing required fields may not be removed or renamed. A breaking shape change requires a new `rule_kind` name.

---

## Indexes

```sql
-- Primary lookup: active rules for a business (includes global rules via NULL check)
CREATE INDEX idx_classification_rules_business_active
  ON classification_rules (business_id, rule_kind, priority)
  WHERE is_active = true;

-- Global rule lookup (NULL business_id)
CREATE INDEX idx_classification_rules_global_active
  ON classification_rules (rule_kind, priority)
  WHERE business_id IS NULL AND is_active = true;
```

---

## RLS

```sql
CREATE POLICY classification_rules_isolation ON classification_rules
  FOR ALL
  USING (
    business_id IS NULL   -- global rules are readable by all tenants
    OR business_id = ANY (auth.business_ids_for_session())
  );
```

Global rules (`business_id IS NULL`) are readable by all authenticated sessions. Writes to global rules are restricted to platform-admin role (enforced by Block 02 Phase 04's `canPerform` check, not by RLS alone).

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `CLASSIFICATION_RULE_CREATED` | New rule inserted (per-business or global) | LOW |
| `CLASSIFICATION_RULE_UPDATED` | Rule predicate, priority, or `result_transaction_type` changed | LOW |
| `CLASSIFICATION_RULE_DEACTIVATED` | `is_active` set to `false` | LOW |

All events emitted via `emitAudit()` per `audit_log_policies` and exist in `audit_event_taxonomy`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; canonical JSON for predicate JSONB; integer minor units for `AMOUNT_RANGE` amounts
- `audit_log_policies` — `CLASSIFICATION_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `CLASSIFICATION_RULE_CREATED`, `CLASSIFICATION_RULE_UPDATED`, `CLASSIFICATION_RULE_DEACTIVATED`
- `transaction_type_enum` — closed 12-value enum; `result_transaction_type` and `TRANSACTION_TYPE_OVERRIDE.force_type` must be values from this enum
- Block 08 Phase 01 — classification schema foundation · Block 08 Phase 02 — Layer 1 classifier · Block 08 Phase 03 — vendor-signature normalization
- `tool_naming_convention_policy` — `classification.*` namespace for all tools referencing this schema
