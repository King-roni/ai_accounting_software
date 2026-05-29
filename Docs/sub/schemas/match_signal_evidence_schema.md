# match_signal_evidence_schema

**Category:** Schemas · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `match_signal_evidence` table in the Processing zone. The table stores the per-signal breakdown that produced a match score for a candidate transaction-invoice pair. Its sole purpose is explainability: it enables the review queue to show a reviewer exactly which signals fired, how strong each signal was, and what contribution each made to the overall match score. Without this table, the score is an opaque float; with it, the reviewer can understand and challenge the match proposal.

`match_signal_evidence` is a Processing-zone table. It is purged after run completion per `data_retention_policy`. It has no RLS — access is service-role only.

---

## Table definition

```sql
CREATE TABLE match_signal_evidence (
  evidence_id            uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  workflow_run_id        uuid          NOT NULL REFERENCES workflow_runs(id),
  match_candidate_id     uuid          NOT NULL,
  business_id            uuid          NOT NULL REFERENCES business_entities(id),
  signal_name            text          NOT NULL,
  raw_value              text,
  signal_score           float         NOT NULL CHECK (signal_score >= 0.0 AND signal_score <= 1.0),
  weight_applied         float         NOT NULL CHECK (weight_applied >= 0.0),
  weighted_contribution  float         NOT NULL CHECK (weighted_contribution >= 0.0),
  created_at             timestamptz   NOT NULL DEFAULT now()
);
```

---

## Column notes

- `evidence_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing; identifies this signal evidence row uniquely within the Processing zone.
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. All evidence rows are tied to the run that produced them. Used by the retention engine to identify rows to purge when the run closes.
- `match_candidate_id` — UUID identifying the candidate pair that was being evaluated when this signal was computed. This is not a FK to a confirmed `match_records` or `income_match_records` row — it references the in-flight candidate evaluation record created during the scoring pass. Candidates that do not produce a confirmed or proposed match record may still generate `match_signal_evidence` rows (the evidence exists for explainability even if the pair was ultimately rejected during scoring). UUID v7.
- `business_id` — non-nullable. Tenant-scoping for within-run queries. Not used for RLS; Processing-zone tables are service-role only.
- `signal_name` — the registered name of the scoring signal. The signal name is from the closed set defined in `match_scoring_weights_policy`. Standard signal names for MVP:
  - `amount_match` — how closely the transaction amount matches the invoice amount or a combination of invoice amounts
  - `date_proximity` — how close the transaction date is to the invoice issue date and due date
  - `description_similarity` — text similarity between the transaction description and the invoice counterparty or reference fields
  - `vendor_memory_hit` — whether the transaction's vendor key matched a vendor memory entry associated with this invoice's counterparty
  - `document_reference_match` — whether the invoice number or payment reference appeared verbatim in the transaction description or reference field
  - Signal names not in this list are rejected by the scoring engine at runtime.
- `raw_value` — the human-readable representation of the inputs to this signal computation. Stored as text for display in the explainability panel. Examples: `"amount_signed=12500, invoice_total=12500"` for `amount_match`; `"delta=2 days"` for `date_proximity`; `"similarity=0.87"` for `description_similarity`. Null is permitted when the raw inputs are not available (e.g., for signals computed entirely from indexed lookups where the raw form is not surfaced). Maximum 1,000 characters.
- `signal_score` — the normalized score for this signal, in `[0.0, 1.0]`. Computed by the signal function per the scoring algorithm defined in `match_scoring_weights_policy`. A score of `1.0` represents a perfect signal match; `0.0` represents no signal match.
- `weight_applied` — the weight factor applied to this signal for this specific candidate pair evaluation. Drawn from `match_scoring_weights_policy` (or from the income-specific weight table for IN-side matches). Stored at the time of evaluation — weights may be updated by an admin via `matching.update_scoring_config`; the stored value captures the weight as-of the scoring run, not the current configured value.
- `weighted_contribution` — the product of `signal_score × weight_applied`. Represents this signal's additive contribution to the final unnormalized match score. The final match score is the sum of all `weighted_contribution` values for the candidate pair, normalized to `[0.0, 1.0]` by the scoring engine. The invariant `weighted_contribution = signal_score × weight_applied` is enforced by the application layer at write time.

---

## Explainability panel integration

The `match_signal_evidence` table feeds the explainability panel in the review queue (Block 14). When a reviewer views a proposed match card, the UI queries this table for all evidence rows where `match_candidate_id` corresponds to the candidate that produced the proposed match. The panel renders:

- A breakdown of each signal with its name, raw inputs, score, weight, and contribution
- A bar chart visualizing relative signal contributions
- A total score computation showing how the weighted contributions sum to the final match score

The panel is read-only. No write path exists through the explainability UI.

Because `match_signal_evidence` is purged after run completion, the explainability panel is available only during the active run and during the review window before finalization. Post-finalization, the archived `match_records` row preserves the final `match_score` but not the signal breakdown. This is an accepted limitation for MVP — the explainability signal is most useful before the reviewer confirms or rejects the match, which happens before finalization.

---

## Score reconstruction invariant

For any given `match_candidate_id`, the sum of all `weighted_contribution` values before normalization must equal the unnormalized score input to the normalization step. The scoring engine validates this invariant at write time: if the sum of `weighted_contribution` for a candidate diverges from the pre-normalization score by more than a floating-point epsilon of `1e-6`, the write is rejected and `MATCHING_PAIR_SCORED` is not emitted for that candidate. This invariant is the key integrity guarantee that makes the explainability panel trustworthy — a reviewer who sums the contributions in the panel can reproduce the score.

The normalization step (dividing the raw weighted sum by the sum of all weights to produce a `[0.0, 1.0]` score) is performed by the scoring engine after all signal evidence rows are written. The `match_score` on the resulting `match_records` or `income_match_records` row is the normalized form.

If the scoring engine is reconfigured (new signal weights, new signal added), the `weight_applied` values on existing evidence rows are not retroactively updated. Historical evidence rows faithfully record the weights that were active at the time of the scoring run. The `MATCHING_SCORING_CONFIG_UPDATED` event marks weight-change boundaries in the audit trail, allowing operators to identify runs evaluated under a different weight configuration.

---

## Processing zone and data retention

`match_signal_evidence` is a Processing-zone table per `data_layer_conventions_policy`. This carries the following operational constraints:

- **No RLS.** Access is service-role only. No client or mobile read path exists.
- **Purged after run completion.** The retention engine purges all rows associated with a `workflow_run_id` after the run transitions to a terminal state. The purge is governed by `data_retention_policy`.
- **No archive.** Signal evidence is ephemeral by design. The `match_records.match_score` column is the permanent record of the scoring outcome.

Mobile clients cannot write to this table. Any write attempt from a mobile client is rejected per `mobile_write_rejection_endpoints.md`. The explainability panel is accessible to mobile clients as a read-only view surface via the review queue API, but the underlying `match_signal_evidence` rows are read by the server-side API layer and returned as a structured payload — no direct table access is granted to the mobile client.

---

## Indexes

```sql
-- Primary explainability query: all signals for a candidate pair
CREATE INDEX idx_match_signal_evidence_candidate
  ON match_signal_evidence (match_candidate_id, workflow_run_id);

-- Run-level retention purge
CREATE INDEX idx_match_signal_evidence_run
  ON match_signal_evidence (workflow_run_id);

-- Business-scoped queries during active run
CREATE INDEX idx_match_signal_evidence_business
  ON match_signal_evidence (business_id, created_at);
```

---

## RLS

`match_signal_evidence` is a Processing-zone table. No RLS policy is applied. Access is service-role only. The table must not be exposed through any role-filtered view or API endpoint that would give client sessions direct row access.

---

## Audit events

`match_signal_evidence` is a Processing-zone table. No row-level audit events are emitted. The scoring engine's run-level events cover the relevant operational facts:

| Event | Owner | Severity |
|---|---|---|
| `MATCHING_PAIR_SCORED` | Block 10 Phase 02 | LOW |
| `MATCHING_SCORING_CONFIG_UPDATED` | Block 10 admin path | LOW |

These events are defined in `audit_event_taxonomy` and emitted per `audit_log_policies`.

---

## Evidence weight validation rule

When the scoring engine writes evidence rows for a candidate pair, it validates that the `weight_applied` values across all signals for that candidate are internally consistent with the active weight configuration from `match_scoring_weights_policy`. Specifically:

- All `weight_applied` values for a single candidate must reflect the same weight snapshot (the weights active at the moment `tool_matching_score_pair` was invoked for that candidate).
- The sum of all `weight_applied` values across signals for a candidate must equal 1.00 (within 1e-6 epsilon). If the active configuration is self-consistent (validated at boot), this invariant holds automatically; the per-candidate check catches any runtime drift.
- If the sum deviates (indicating a partial weight update or a code bug), the write is rejected and `MATCHING_SCORING_CONFIG_INVALID` is emitted (BLOCKING for that run).

This rule ensures the explainability panel can accurately display "X% of the match score came from signal Y" without silent normalization artifacts.

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; Processing zone definition; purge-on-completion rule; `weighted_contribution` stored as float (not currency — scores are pure dimensionless values)
- `match_record_schema` — `match_score` on confirmed match records is the aggregated result; this table provides the per-signal decomposition; `match_level_enum` context
- `match_scoring_weights_policy` — defines the closed set of valid `signal_name` values; specifies `weight_applied` defaults; governs `weighted_contribution` formula
- `match_signal_weights` — the per-signal weight configuration table read by the scoring engine at runtime
- `data_retention_policy` — Processing-zone purge on run completion; retention schedule for this table
- `audit_log_policies` — `MATCHING_*` domain; events from the scoring engine
- `audit_event_taxonomy` — `MATCHING_PAIR_SCORED`, `MATCHING_SCORING_CONFIG_UPDATED`
- Block 10 Phase 02 — match scoring engine; primary writer; computes all signal scores and writes evidence rows
- Block 10 Phase 08 — income matching variant; also writes evidence rows for IN-side candidate pairs using income-specific signal weights
- Block 10 Phase 09 — matching workflow phase registration; declares `match_signal_evidence` as a Processing-zone output table of the MATCHING phase
- Block 14 — review queue; primary consumer; explainability panel reads this table during the active run window
- Block 14 Phase 11 — affected-only re-scan signal; when a match is re-evaluated, the stale evidence rows for the re-scored candidate are replaced
- `income_matching_schema` — `income_match_records` rows reference the same `match_candidate_id` pattern; income-matching signal evidence rows are written by Block 10 Phase 08
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
