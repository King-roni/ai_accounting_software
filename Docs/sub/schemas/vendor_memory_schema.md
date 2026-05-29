# vendor_memory_schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `vendor_memory` table, which stores learned counterparty-to-classification mappings accumulated from transactions that an Owner or Admin has confirmed. The table is the Layer 2 classifier's primary input: before invoking any AI, the classification workflow checks whether a confirmed memory entry exists for the transaction's vendor key. A high-confidence memory hit produces a `layer_2_local_score` (per `confidence_score_schema`) and may short-circuit the AI invocation entirely.

---

## Table definition

```sql
CREATE TABLE vendor_memory (
  memory_id                    uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                  uuid          NOT NULL REFERENCES business_entities(id),
  vendor_key                   text          NOT NULL,                        -- normalised vendor identifier derived from transaction description; NOT a FK
  suggested_transaction_type   transaction_type_enum NOT NULL,
  suggested_ledger_account_id  uuid          REFERENCES chart_of_accounts(id), -- nullable; populated as the chart matures
  suggested_vat_treatment      vat_treatment_enum NOT NULL,
  confidence                   float         NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
  sample_count                 integer       NOT NULL DEFAULT 1 CHECK (sample_count >= 1),
  last_confirmed_at            timestamptz   NOT NULL,
  created_at                   timestamptz   NOT NULL DEFAULT now(),
  updated_at                   timestamptz   NOT NULL DEFAULT now(),

  CONSTRAINT uq_vendor_memory_business_vendor
    UNIQUE (business_id, vendor_key)
);
```

### Column notes

- `memory_id` — UUID v7 per `data_layer_conventions_policy §2`.
- `business_id` — non-nullable. Vendor memory is per-tenant; the same vendor key can produce different classification mappings for different businesses depending on their accounting setup.
- `vendor_key` — the normalised vendor identifier computed from the raw `transactions.description` field using the vendor-signature normalisation rules in Block 08 Phase 03. This is NOT a foreign key to any counterparty table; the normalisation produces a deterministic string from text rather than looking up a registered entity. The normalisation algorithm: lowercase, punctuation-stripped, whitespace-collapsed, merchant-prefix-stripped. Two transactions from the same merchant should produce the same `vendor_key` even if the raw narrative differs slightly.
- `suggested_transaction_type` — the transaction type learned from confirmed classifications for this vendor key. Drawn from the closed 12-value `transaction_type_enum`. The `UNKNOWN` value must never appear here (a vendor memory entry for an unclassified vendor provides no signal and must not be written).
- `suggested_ledger_account_id` — nullable FK to `chart_of_accounts.id`. Populated when the confirmed classifications include ledger account information from the reviewing user. Null during early operation when the ledger layer has not yet produced account-level mappings for this vendor.
- `suggested_vat_treatment` — the VAT treatment learned from confirmed classifications. Drawn from the closed 8-value `vat_treatment_enum`. The `UNKNOWN` value must never appear here for the same reason as `suggested_transaction_type`.
- `confidence` — float in `[0.0, 1.0]`. Reflects the uniformity of confirmed classifications across the sample set. A `sample_count` of 1 produces `confidence = 0.70` (single-confirmation baseline). Each additional confirming classification that agrees with the current `suggested_transaction_type` increments confidence toward `1.0` using a bounded accumulation formula defined in Block 08 Phase 03. Conflicting confirmations reduce confidence and may trigger a review issue.
- `sample_count` — the number of confirmed transactions that have contributed to this memory entry. Incremented by `classification.write_vendor_memory` on each confirmed classification for this `(business_id, vendor_key)` pair.
- `last_confirmed_at` — timestamp of the most recent confirmed classification that updated this entry. Used for staleness evaluation (future Stage 2 feature: decay entries not confirmed in over 12 months).

---

## Vendor key normalisation

The `vendor_key` is not a raw transaction description. It is the output of the vendor-signature normalisation pass (Block 08 Phase 03) applied to `transactions.description`. The normalisation steps are:

1. Lowercase the entire string.
2. Remove punctuation characters (retain alphanumeric and whitespace).
3. Collapse whitespace to single spaces; trim leading and trailing whitespace.
4. Strip known merchant-prefix tokens (e.g., `SQ *`, `PAYPAL *`, `STRIPE *`) that precede the actual vendor name.

The resulting string is used as-is as the `vendor_key`. No hashing is applied at the column level — the key is human-readable and appears in the review queue card so reviewers can inspect which counterparty a memory entry corresponds to. The maximum length of `vendor_key` is 500 characters (identical to the `COUNTERPARTY_EXACT` predicate limit in `classification_rule_predicate_schema`).

Because `vendor_key` is derived from text rather than from a registered entity, the same vendor may generate different keys if the bank statement format changes (e.g., a bank shortens counterparty names in a format upgrade). When this happens, a new `vendor_memory` row is created for the new key and the old row remains intact with its historical confidence. Block 08 Phase 03 handles vendor key aliasing in a future Stage 2 feature; for MVP, the keys are independent.

---

## Write path

The `classification.write_vendor_memory` tool (Block 08 Phase 03) is the only authorised writer. It is invoked after an Owner or Admin confirms or reclassifies a transaction classification. The tool performs an upsert on `(business_id, vendor_key)`:

- On first confirmation for a vendor key: inserts a new row with `sample_count = 1` and baseline confidence.
- On subsequent confirmations that agree with the existing `suggested_transaction_type`: increments `sample_count` and accumulates confidence.
- On a conflicting confirmation: records the conflict in the `vendor_memory_conflicts` table (forward reference, Block 08 Phase 03) and may lower confidence if the conflict rate exceeds a threshold.

Direct writes to `vendor_memory` outside of `classification.write_vendor_memory` are rejected at the RLS layer (service-role only for direct writes; the application layer routes all writes through the tool).

---

## Read path

The Layer 2 classifier (`classification.lookup_vendor_memory`, Block 08 Phase 03) queries this table at the start of each transaction classification run, after Layer 1 rule evaluation. If a row exists for `(business_id, vendor_key)` with `confidence >= layer_2_confidence_threshold` (system default: 0.70; per-business override stored in `business_classification_config`), the classifier uses the `suggested_transaction_type` and `suggested_vat_treatment` as the Layer 2 decision and skips Layer 3 AI invocation.

---

## RLS

```sql
CREATE POLICY vendor_memory_isolation ON vendor_memory
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));

-- Write access via service role only (enforced by application layer)
-- Direct writes outside classification.write_vendor_memory are not permitted.
```

---

## Indexes

```sql
-- Layer 2 lookup hot path
CREATE UNIQUE INDEX idx_vendor_memory_business_vendor
  ON vendor_memory (business_id, vendor_key);

-- Staleness scan (future Stage 2 decay pass)
CREATE INDEX idx_vendor_memory_last_confirmed
  ON vendor_memory (business_id, last_confirmed_at);
```

The unique index on `(business_id, vendor_key)` serves double duty: enforces the uniqueness constraint and is the primary read-path index for the Layer 2 classifier lookup.

---

## Confidence accumulation model

The confidence value on a `vendor_memory` row is updated using a bounded accumulation formula. The design intent: confidence should reach `0.90+` after approximately 5 consistent confirmations, and a single conflicting confirmation should reduce it by a meaningful but not catastrophic amount.

The accumulation formula applied by `classification.write_vendor_memory`:

| Event | Formula |
|---|---|
| New row (first confirmation) | `confidence = 0.70` (baseline) |
| Agreeing confirmation (same `suggested_transaction_type`) | `confidence = min(1.0, confidence + ((1.0 - confidence) * 0.35))` |
| Conflicting confirmation (different `suggested_transaction_type`) | `confidence = max(0.0, confidence - 0.20)` |

The agreeing-confirmation formula uses a diminishing-increment approach so that confidence approaches `1.0` asymptotically. The conflicting-confirmation penalty is fixed at `0.20` rather than proportional, so that a long history of confirmed agreements cannot be completely negated by a single conflict — but two consecutive conflicts will push confidence below the `0.70` Layer 2 activation threshold, causing the entry to stop short-circuiting Layer 3.

The formula is internal to Block 08 Phase 03 and may be adjusted in Stage 2 based on empirical false-positive rates. Any change to the formula requires a `decisions_log.md` amendment and re-evaluation of the existing confidence values in production (a migration script is needed).

---

## Mobile write rejection

`classification.write_vendor_memory` is a server-side tool invoked by the classification workflow phase. Mobile clients cannot directly write to `vendor_memory`. Any such attempt is rejected per `mobile_write_rejection_endpoints.md`. Mobile clients may trigger the confirmation action through the review queue UI, but the write tool executes server-side.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `VENDOR_MEMORY_WRITTEN` | A `vendor_memory` row is inserted or updated by `classification.write_vendor_memory` | LOW |

The `VENDOR_MEMORY_WRITTEN` payload includes `memory_id`, `business_id`, `vendor_key`, `suggested_transaction_type`, `suggested_vat_treatment`, `confidence`, `sample_count`, and a `write_kind` discriminator (`INSERT` or `UPDATE`). Existing taxonomy events `CLASSIFICATION_VENDOR_MEMORY_INCREMENTED` and `CLASSIFICATION_VENDOR_MEMORY_TIER_TRANSITION` (Block 08) cover richer classification-domain semantics; `VENDOR_MEMORY_WRITTEN` is the table-level event tied to this schema.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; `vendor_key` derivation uses canonical string normalisation
- `classification_rule_predicate_schema` — Layer 1 rule evaluation precedes the vendor memory lookup; if Layer 1 produces a high-confidence match, Layer 2 is skipped
- `rejection_memory_schema` (Block 10) — complements vendor memory; records vendor-document pairings that should never be re-suggested
- `confidence_score_schema` — `layer_2_local_score` in the confidence object is produced by the vendor memory lookup
- `transaction_type_enum` — closed 12-value enum; `suggested_transaction_type` must be a valid non-UNKNOWN value
- `vat_treatment_enum` — closed 8-value enum; `suggested_vat_treatment` must be a valid non-UNKNOWN value
- `audit_log_policies` — `CLASSIFICATION_*` domain (parent domain); `VENDOR_MEMORY_WRITTEN` event
- `audit_event_taxonomy` — `VENDOR_MEMORY_WRITTEN`, `CLASSIFICATION_VENDOR_MEMORY_INCREMENTED`, `CLASSIFICATION_VENDOR_MEMORY_TIER_TRANSITION`
- Block 08 Phase 03 — recurring vendor memory (Layer 2); implementation owner; `classification.write_vendor_memory` and `classification.lookup_vendor_memory` tools
- Block 08 Phase 07 — confidence scoring and auto-confirm gate; reads Layer 2 scores from this table
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
