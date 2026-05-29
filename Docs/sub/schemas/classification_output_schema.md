# classification_output_schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `classification_outputs` table in the Processing zone. The table holds the final assembled classification decision for each transaction, produced after all three classifier layers have run. It is the staging record before the winning decision is promoted to the `transactions.classification_*` columns in the operational database. One row exists per transaction per workflow run; promoted rows are the source of truth for ledger preparation and review queue routing.

`classification_outputs` is a Processing-zone table. It is purged after run completion per `data_retention_policy`. It has no RLS — access is service-role only.

---

## Table definition

```sql
CREATE TABLE classification_outputs (
  output_id                    uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  workflow_run_id              uuid          NOT NULL REFERENCES workflow_runs(id),
  transaction_id               uuid          NOT NULL REFERENCES transactions(id),
  business_id                  uuid          NOT NULL REFERENCES business_entities(id),
  winning_layer                text          NOT NULL,
  suggested_transaction_type   text          NOT NULL,
  suggested_vat_treatment      text          NOT NULL,
  suggested_ledger_account_id  uuid          REFERENCES chart_of_accounts(id),
  confidence_score_json        jsonb         NOT NULL,
  below_threshold              boolean       NOT NULL DEFAULT false,
  review_flag_reason           text,
  rule_id_matched              uuid,
  vendor_memory_id             uuid,
  ai_invocation_id             uuid,
  promoted                     boolean       NOT NULL DEFAULT false,
  created_at                   timestamptz   NOT NULL DEFAULT now()
);
```

---

## Column notes

- `output_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing; identifies this classification output uniquely within the Processing zone.
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. Every classification output is tied to the run that produced it. Used by the retention engine to identify all Processing-zone rows to purge when the run closes.
- `transaction_id` — non-nullable FK to `transactions.id`. The transaction being classified. Within a single run, at most one non-promoted `classification_outputs` row exists per `transaction_id` at any given time; if re-classification is triggered, the existing row is replaced by a new row rather than updated in place.
- `business_id` — non-nullable. Tenant-scoping for within-run queries. Not used for RLS; Processing-zone tables are service-role only.
- `winning_layer` — the classifier layer that produced the accepted decision. Closed enum: `LAYER_1 | LAYER_2 | LAYER_3 | NONE`. `LAYER_1` indicates a rule-based match. `LAYER_2` indicates a vendor-memory hit. `LAYER_3` indicates the AI fallback classifier decided. `NONE` means no layer produced a result above the confidence threshold; the transaction is unclassified and enters the review queue. Stored as text; validated by the application layer against the closed enum at write time.
- `suggested_transaction_type` — the transaction type code recommended by the winning layer. Must be a valid value from `transaction_type_enum` (12 values). The `UNKNOWN` value is permitted only when `winning_layer = NONE`. Stored as text; validated against the enum at write time.
- `suggested_vat_treatment` — the VAT treatment recommended by the winning layer. Must be a valid value from `vat_treatment_enum` (8 values). The `UNKNOWN` value is permitted when `winning_layer = NONE` or when the winning layer could not determine a VAT treatment. Stored as text; validated against the enum at write time.
- `suggested_ledger_account_id` — nullable FK to `chart_of_accounts.id`. The ledger account the winning layer recommends mapping this transaction to. Populated when the winning layer has a ledger account suggestion (Layer 1 rules may include account-level guidance; Layer 2 vendor memory may carry a `suggested_ledger_account_id`; Layer 3 AI may suggest an account code). Null when no account suggestion is available; the ledger preparation layer (Block 11) resolves the account independently in that case.
- `confidence_score_json` — the full confidence score object conforming to `confidence_score_schema`. Stored as JSONB. Contains `overall_score`, `layer_scores`, `winning_layer`, `threshold_applied`, `threshold_source`, `below_threshold`, and `review_flag_reason`. This is the authoritative confidence record for the classification decision; downstream consumers (auto-confirm gate, review queue, accountant pack) read from this JSONB object.
- `below_threshold` — denormalized boolean mirroring `confidence_score_json->>'below_threshold'`. Stored at the row level to allow efficient index-based queries without JSONB extraction on hot paths. Must remain consistent with `confidence_score_json.below_threshold`; the application layer enforces this invariant at write time.
- `review_flag_reason` — short text description of why a review flag was raised. Null when no flag is warranted. Mirrors `confidence_score_json.review_flag_reason` for cases where `below_threshold = true` or a layer conflict was detected. Maximum 500 characters.
- `rule_id_matched` — UUID of the Layer 1 rule (`classification_rules.rule_id`) that produced the `LAYER_1` decision. Null when `winning_layer != LAYER_1`. Provides the traceability link from the output to the specific rule that fired.
- `vendor_memory_id` — UUID of the `vendor_memory.memory_id` row that produced the `LAYER_2` decision. Null when `winning_layer != LAYER_2`. Provides the traceability link to the vendor memory entry.
- `ai_invocation_id` — UUID of the `ai_invocation_records.invocation_id` row from the `ai_gateway_schema` that produced the `LAYER_3` decision. Null when `winning_layer != LAYER_3` (and null when Layer 3 was invoked as a tiebreaker but did not become the winning layer). Provides the traceability link to the AI gateway invocation.
- `promoted` — `false` on creation. Set to `true` by the zone-promotion step (Block 04 Phase 08) when the classification decision is written to `transactions.classification_*` columns. Rows with `promoted = false` at run completion are anomalies (they indicate a transaction that was classified but not promoted) and are logged as warnings before purge.
- `created_at` — wall-clock timestamp of row insertion. Not updated.

---

## Winning layer and nullable FK invariants

The three provenance FK columns (`rule_id_matched`, `vendor_memory_id`, `ai_invocation_id`) are mutually exclusive based on `winning_layer`:

| `winning_layer` | `rule_id_matched` | `vendor_memory_id` | `ai_invocation_id` |
|---|---|---|---|
| `LAYER_1` | Non-null | Null | Null (unless Layer 3 ran as tiebreaker) |
| `LAYER_2` | Null | Non-null | Null (unless Layer 3 ran as tiebreaker) |
| `LAYER_3` | Null | Null | Non-null |
| `NONE` | Null | Null | Null (unless Layer 3 ran and produced no result) |

When Layer 3 is invoked as a tiebreaker between Layer 1 and Layer 2 but neither the tiebreaker result nor the original layers exceeded the threshold, `ai_invocation_id` may be non-null even when `winning_layer != LAYER_3`. This edge case is documented in `confidence_score_schema §Layer 3 score invariant`.

---

## Processing zone and data retention

`classification_outputs` is a Processing-zone table as defined in `data_layer_conventions_policy`. This carries the following operational constraints:

- **No RLS.** Access is service-role only. Client applications and mobile clients cannot read or write this table directly.
- **Purged after run completion.** The retention engine purges all rows associated with a `workflow_run_id` after the run transitions to a terminal state. The purge is governed by `data_retention_policy`.
- **No archive.** The promoted classification data in `transactions.classification_*` columns and the audit log provide the post-run evidence trail.

Mobile clients cannot write to this table. Any write attempt from a mobile client is rejected per `mobile_write_rejection_endpoints.md`.

---

## Indexes

```sql
-- Run-level batch queries (promotion pass, retention purge)
CREATE INDEX idx_classification_outputs_run
  ON classification_outputs (workflow_run_id, promoted);

-- Transaction lookup within a run
CREATE INDEX idx_classification_outputs_tx
  ON classification_outputs (transaction_id, workflow_run_id);

-- Below-threshold filter for review queue routing
CREATE INDEX idx_classification_outputs_below_threshold
  ON classification_outputs (workflow_run_id, below_threshold)
  WHERE below_threshold = true;

-- Business-scoped queries during active run
CREATE INDEX idx_classification_outputs_business
  ON classification_outputs (business_id, created_at);
```

---

## Audit events

`classification_outputs` is a Processing-zone table. No row-level audit events are emitted for individual row insertions. Run-level and decision-level events from the classification pipeline cover the relevant facts:

| Event | Owner | Severity |
|---|---|---|
| `CLASSIFICATION_LAYER_1_DECIDED` | Block 08 Phase 02 | LOW |
| `CLASSIFICATION_LAYER_2_DECIDED` | Block 08 Phase 03 | LOW |
| `CLASSIFICATION_LAYER_3_DECIDED` | Block 08 Phase 04 | LOW |
| `CLASSIFICATION_RUN_COMPLETED` | Block 08 Phase 09 | LOW |
| `CLASSIFICATION_RULE_NO_MATCH` | Block 08 Phase 02 | LOW |

These events are defined in `audit_event_taxonomy` and emitted per `audit_log_policies`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; JSONB canonical serialization for `confidence_score_json`; Processing zone definition
- `confidence_score_schema` — `confidence_score_json` JSONB shape; `winning_layer` enum; `below_threshold` semantics; Layer 3 tiebreaker invariant
- `vendor_memory_schema` — `vendor_memory_id` FK; Layer 2 decision provenance; `suggested_transaction_type` and `suggested_vat_treatment` from vendor memory
- `ai_gateway_schema` — `ai_invocation_id` FK to `ai_invocation_records`; Layer 3 decision provenance
- `transaction_type_enum` — closed 12-value enum; `suggested_transaction_type` must be a valid value
- `vat_treatment_enum` — closed 8-value enum; `suggested_vat_treatment` must be a valid value
- `layer1_rule_evaluation_schema` — `rule_id_matched` FK; Layer 1 decision provenance
- `data_retention_policy` — Processing-zone purge on run completion
- `audit_log_policies` — `CLASSIFICATION_*` domain; events emitted by the classification pipeline
- `audit_event_taxonomy` — `CLASSIFICATION_LAYER_1_DECIDED`, `CLASSIFICATION_LAYER_2_DECIDED`, `CLASSIFICATION_LAYER_3_DECIDED`, `CLASSIFICATION_RUN_COMPLETED`
- Block 08 Phase 02 — Layer 1 rule-based classifier; writes `rule_id_matched`
- Block 08 Phase 03 — Layer 2 vendor memory; writes `vendor_memory_id`
- Block 08 Phase 04 — Layer 3 AI fallback; writes `ai_invocation_id`
- Block 08 Phase 07 — confidence scoring and auto-confirm gate; reads `confidence_score_json` and `below_threshold`
- Block 04 Phase 08 — zone-promotion pipeline; sets `promoted = true` and writes to `transactions.classification_*`
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
