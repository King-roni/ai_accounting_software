# layer1_rule_evaluation_schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `layer1_rule_evaluations` table, which lives in the Processing zone and records the outcome of every classification rule evaluated against each transaction during a workflow run. The table is ephemeral: it is created for each run and purged after the run completes per `data_retention_policy`. Its purpose is to support confidence score assembly (per `confidence_score_schema`) and provide the audit trail explaining why a transaction received a particular classification.

---

## Zone placement

`layer1_rule_evaluations` is a **Processing-zone table**. Per `data_layer_conventions_policy`, Processing-zone tables:

- Are written and read exclusively by service-role connections during run execution.
- Are not accessible to end users or any client-facing role (no RLS is defined; the table is inaccessible outside service-role context by construction).
- Are purged after the workflow run completes, on the schedule defined in `data_retention_policy`.

No RLS policy is applied to this table. Access is controlled by the Postgres role used during run execution (service role only). Any attempt to query this table from a user-facing role will fail with a permission error.

---

## Table definition

```sql
CREATE TABLE layer1_rule_evaluations (
  evaluation_id    uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  workflow_run_id  uuid          NOT NULL REFERENCES workflow_runs(id),
  transaction_id   uuid          NOT NULL REFERENCES transactions(id),
  rule_id          uuid          NOT NULL REFERENCES classification_rules(rule_id),
  rule_version     text          NOT NULL,                                     -- snapshot of the rule's schema_version at evaluation time
  matched          boolean       NOT NULL,
  match_score      float         NOT NULL CHECK (match_score >= 0.0 AND match_score <= 1.0),
  evaluated_at     timestamptz   NOT NULL DEFAULT now()
);
```

### Column notes

- `evaluation_id` — UUID v7 per `data_layer_conventions_policy §2`.
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. Every evaluation row is scoped to a run. The entire table for a given run is purged together when the run is retired.
- `transaction_id` — FK to `transactions.id`. The transaction being evaluated. A single transaction may produce many evaluation rows (one per rule that was evaluated against it).
- `rule_id` — FK to `classification_rules.rule_id`. The rule that was evaluated.
- `rule_version` — a snapshot of the rule's version string at evaluation time. Stored because rules may be updated between the time a run starts and when the audit trace is reviewed. This snapshot makes the evaluation record self-contained and auditable even after the rule has been updated.
- `matched` — `true` if the rule's predicate matched the transaction; `false` if the predicate was evaluated but did not match. Only the first matching rule per `priority` ordering wins in the classifier (per `classification_rule_predicate_schema`), but all rules evaluated up to that point produce rows, enabling diagnosis of why a lower-priority rule was not selected.
- `match_score` — `1.0` for exact-match rules (any `rule_kind` where the predicate either fully matches or does not); `0.0` for rules that were evaluated and did not match. The range `(0.0, 1.0)` is reserved for future partial-match rule kinds (not used in MVP). For MVP, only `0.0` or `1.0` appear.
- `evaluated_at` — timestamp when this evaluation row was written. Useful for diagnosing timing within a run if multiple transaction batches are processed concurrently.

---

## Processing-zone access control

Because `layer1_rule_evaluations` is a Processing-zone table, the following access restrictions apply:

- **No RLS.** The table is created in the `processing` schema (or an equivalent Postgres schema that is inaccessible to the `authenticated` role). The `authenticated` and application roles have no SELECT, INSERT, UPDATE, or DELETE privilege on this table.
- **Service role only.** Access is via the Postgres `service_role` used during workflow run execution. No direct query access exists from any client-facing API endpoint.
- **No API surface.** There is no REST or GraphQL endpoint that returns rows from this table. The only consumer is the internal classification workflow phase logic.
- **Purge on run retirement.** All rows for a given `workflow_run_id` are deleted when the run reaches a terminal state. The purge is a single `DELETE WHERE workflow_run_id = $1` and runs in a background job per `data_retention_policy`.

This is consistent with all other Processing-zone tables across the codebase (e.g., intermediate extraction results, OCR output staging). The pattern is: Process, then emit durable signals (audit events + final `transaction_classifications` row); discard the working data.

---

## Evaluation scope

The Layer 1 classifier (`classification.evaluate_layer1_rules`, Block 08 Phase 02) evaluates rules in priority order and stops at the first match. All rules evaluated — including those that did not match — produce rows in this table. The complete evaluation trace enables:

1. **Confidence score assembly** — the winning rule's `match_score` becomes `layer_1_rule_score` in `confidence_score_schema`. The presence of rows with `matched = false` and higher `rule_id` priorities confirms that no higher-priority rule applied.
2. **Audit and explainability** — a reviewer in Block 14 can inspect the full rule trace to understand why a transaction was classified as it was, and why alternative rules were not applied.
3. **Rule regression testing** — Block 08 Phase 10 end-to-end tests compare evaluation traces against fixture snapshots.

---

## Indexes

```sql
-- Primary access pattern: all evaluations for a transaction in a run
CREATE INDEX idx_l1_evaluations_run_transaction
  ON layer1_rule_evaluations (workflow_run_id, transaction_id);

-- Rule-level analysis: all transactions where a specific rule matched
CREATE INDEX idx_l1_evaluations_rule_matched
  ON layer1_rule_evaluations (rule_id, matched)
  WHERE matched = true;
```

---

## Evaluation row volume

For a typical workflow run processing 300 transactions against a rule set of 40 active rules, the maximum theoretical row count is 300 × 40 = 12,000 rows. In practice the count is significantly lower because:

1. Rules are evaluated in priority order and evaluation stops at the first match. A transaction matched by priority-1 rule produces exactly one row (the matched rule). Subsequent rules are not evaluated.
2. Global rules are evaluated after per-business rules; most transactions match a per-business rule before the global rule set is reached.
3. The `BANK_FEE_MARKER` rule kind short-circuits immediately when the fee marker is detected.

The expected average is 3–6 evaluation rows per transaction. For a 300-transaction run, this is approximately 900–1,800 rows — manageable entirely in memory during the run without materialising to disk. The table is written to Postgres only for durability during multi-phase runs that may resume from a checkpoint; single-phase runs complete before the Process zone purge fires.

Index size at maximum volume: with 12,000 rows and two indexes, the estimated index size is under 2 MB. This is well within the memory budget for Processing-zone tables.

---

## Retention and purge

Processing-zone tables are purged per `data_retention_policy` after the run completes. The purge is run-scoped: all rows with a given `workflow_run_id` are deleted in a single operation after the run reaches a terminal state (`FINALIZED`, `FAILED`, or `CANCELLED`). The audit trail for classification decisions is preserved in `audit_log` events emitted by the classifier (`CLASSIFICATION_LAYER_1_DECIDED`, `CLASSIFICATION_RUN_COMPLETED`) — the `layer1_rule_evaluations` table is supplemental operational data, not the authoritative record.

---

## No mobile access

This table is entirely service-side. No client or mobile path exists. There is no API endpoint that surfaces rows from this table to end users. Summaries derived from this table (the winning rule identity, the confidence score) are surfaced through the `transaction_classifications` table and the review queue card in Block 14.

---

## Relationship to audit events

This table does not emit audit events directly. The audit signal for Layer 1 classification decisions is `CLASSIFICATION_LAYER_1_DECIDED`, emitted by the classifier tool after it writes to this table. The event payload includes `transaction_id`, `workflow_run_id`, `winning_rule_id`, `match_score`, and the resulting `transaction_type`. The `layer1_rule_evaluations` rows are the internal working data that backs this event; the event is the durable external record.

If a reviewer or accountant needs to understand why a transaction was classified by a specific rule, the `CLASSIFICATION_LAYER_1_DECIDED` audit event payload contains the `winning_rule_id`. Cross-referencing `winning_rule_id` with `classification_rules` (which is not purged) gives the full rule predicate. The evaluation rows in this table add detail about which other rules were evaluated and rejected, but this detail is ephemeral and is only accessible during the run window. For post-run forensics, the audit event payload plus the `classification_rules` table is the authoritative source.

---

## Audit events

This table produces no direct audit events. The classifier tool emits `CLASSIFICATION_LAYER_1_DECIDED` (LOW) after writing evaluation rows and selecting the winning rule; that event is the durable audit record. `CLASSIFICATION_RUN_STARTED` (LOW) and `CLASSIFICATION_RUN_COMPLETED` (LOW) bound the run-level lifecycle. All three are emitted via `emitAudit()` per `audit_log_policies`; see `audit_event_taxonomy` for payload shapes.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; Processing-zone placement; purge lifecycle
- `classification_rule_predicate_schema` — `classification_rules` table; `rule_id` FK; predicate shapes evaluated to produce rows here
- `confidence_score_schema` — `layer_1_rule_score` in the confidence object is assembled from rows in this table
- `data_retention_policy` — Processing-zone purge schedule; run-scoped deletion
- `audit_log_policies` — `CLASSIFICATION_*` domain; events emitted alongside this table's data
- `audit_event_taxonomy` — `CLASSIFICATION_LAYER_1_DECIDED`, `CLASSIFICATION_RUN_STARTED`, `CLASSIFICATION_RUN_COMPLETED`
- Block 08 Phase 01 — classification schema foundation; `transaction_classifications` table
- Block 08 Phase 02 — Layer 1 classifier; primary writer of this table
- Block 08 Phase 07 — confidence scoring and auto-confirm gate; reads the assembled `layer_1_rule_score`
- Block 08 Phase 10 — end-to-end classifier tests; regression testing via evaluation trace comparison
- `tool_naming_convention_policy` — `classification.*` namespace; `classification.evaluate_layer1_rules` tool name
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy (no client write path to this table exists by design)
