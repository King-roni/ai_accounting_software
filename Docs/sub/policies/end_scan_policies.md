# end_scan_policies

**Category:** Policies · **Owning block:** 06 — AI Layer · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

Three sub-policies bound together: which checks re-run for which entities during End-Scan, per-check determinism rationale, and severity-default operator-feedback calibration. Per the Layer 0 compression merge of `end_scan_affected_only_rescan_policy` + `end_scan_determinism_policy` + `end_scan_severity_calibration_policy`.

End-Scan is Block 06 Phase 11's pre-finalization integrity pass: a final sweep that runs every check across the period's records and surfaces any anomalies not caught by the per-phase gates. The three sections below pin how it operates without over-running on every re-evaluation.

---

## Section 1 — Affected-only re-scan signal contract

Per Stage 1: "Re-scan after resolution: End-Scan auto-re-runs only on issues affected by the resolved record (transaction, document, match) — not full re-scan."

When a user resolves a review issue, Block 14 emits `REVIEW_ISSUE_RESOLVED` with a payload describing the affected entity. Block 06's End-Scan re-scan subscriber consumes the event and re-runs **only the checks affected by the resolved entity** — not the full End-Scan.

### The signal contract

```ts
{
  resolved_issue_id,
  business_id,
  workflow_run_id,
  affected_entities: [
    { kind: "transaction" | "document" | "match_record" | "invoice", id: uuid }
  ],
  resolution_action_type,
  resolution_change_summary: {                  // what specifically changed
    field_changed: "transaction_type" | "match_status" | "vat_treatment" | "...",
    old_value, new_value
  }
}
```

The `affected_entities` array typically has 1-3 entities. Block 06's subscriber consults the per-check entity mapping to determine which checks apply.

### Per-check entity mapping

| Check kind | Triggered when affected entity is |
| --- | --- |
| `vat_treatment_consistency` | Transaction with vat_treatment change |
| `match_completeness` | Match_record changed; or transaction with effective_match_status changed |
| `ledger_balance` | Any transaction; or any match_record affecting ledger entries |
| `evidence_threshold` | Transaction; or document linked to a transaction |
| `cross_period_consistency` | Any transaction or invoice |
| `anomaly_detection` | Any transaction |

A check is invoked only on the entities relevant to it. Cross-checks (e.g., `ledger_balance` requires re-summing all entries in the period) re-run from scratch but only when an upstream change might affect them.

### Audit shape

```ts
emitAudit("END_SCAN_AFFECTED_ONLY_RESCAN_TRIGGERED", {
  resolved_issue_id,
  affected_entities,
  checks_re_run: ["..."],
  rescan_duration_ms
});
```

If a re-run discovers a new finding, `END_SCAN_FINDING_RAISED` fires per `audit_event_taxonomy`. Cascading findings (a fix surfaces a new issue) are normal; they don't recurse indefinitely per `rescan_recursion_safety_policy` (now part of `rescan_policies` cluster).

## Section 2 — Per-check determinism vs AI

Each check is classified per Block 01 Principle 3: "AI assists / rules decide / user finalizes."

### Deterministic-first

The default classification:

- `vat_treatment_consistency` — deterministic (compares treatments across entries with shared counterparty)
- `match_completeness` — deterministic (counts matched vs unmatched in period)
- `ledger_balance` — deterministic (sums DR vs CR by account)
- `evidence_threshold` — deterministic (counts transactions over the €15 threshold without evidence)
- `cross_period_consistency` — deterministic (compares period boundary effects to predecessor period)

These run with no AI involvement; results are fully predictable.

### AI-assisted

Two checks use AI:

- `anomaly_detection` — Tier 3 prompt classifies transactions as "typical for this business" vs "unusual" based on amount, vendor, transaction_type
- `plain_language_summarization` — Tier 3 prompt summarizes findings in human-readable form per `plain_language_pipeline_prompt`

Per `gateway_bypass_detection_policy`: the AI calls flow through the AI Privacy Gateway. Per `redaction_policies`: counterparty PII redacted before the prompt.

### Why some checks resist AI

Per Block 01 Principle 3: AI explains, doesn't decide. Deterministic checks are deterministic on purpose — auditors expect repeatable rule-driven evaluations. AI is reserved for anomaly detection (where "typical" is fuzzy by nature) and plain-language summarization (where AI's strength is most visible).

A check that COULD be done by AI but is deterministic is intentional — the determinism is the feature.

## Section 3 — Severity-default calibration

End-Scan findings have a default severity per check. The defaults are calibrated to balance:

- Too-strict defaults: every finalization blocked by a HIGH issue; user frustration
- Too-lax defaults: real problems pass through; trust erodes

### Default severities

| Check | Default severity | Rationale |
| --- | --- | --- |
| `vat_treatment_consistency` (mismatch) | HIGH | VAT errors compound across periods; worth blocking |
| `match_completeness` (unmatched OUT_EXPENSE) | MEDIUM | Expected case; user reviews exceptions |
| `ledger_balance` (DR/CR drift) | BLOCKING | Books that don't balance can't finalize — period |
| `evidence_threshold` (missing evidence above €15) | MEDIUM | Expected occasionally; user reviews |
| `cross_period_consistency` (boundary mismatch) | HIGH | Suggests data quality issue |
| `anomaly_detection` (statistical outlier) | LOW | Informational; doesn't block |

### Operator-feedback calibration

The defaults are starting points. Per Stage 4 sub-doc-level refinement:

- Per-business override available via `per_business_severity_override_policy` (now part of `review_queue.review_policies`)
- Calibration data: how often users dismiss-as-false-positive at each severity tells us if the default is too strict
- Adjustments require a `Docs/decisions_log.md` amendment

### Per-business override

A business can configure: "End-Scan anomaly detection severity = MEDIUM for this business" (e.g., a business with naturally high transaction variance). Per `per_business_severity_override_policy`:

- Override stored in `business_settings.end_scan_severity_overrides_json`
- Maximum 1 level escalation (LOW → MEDIUM) or 1 level reduction (HIGH → MEDIUM)
- BLOCKING cannot be reduced

### Calibration cycle

Per `live_integration_test_runbook`'s drift-report shape: monthly review of:

- Dismissal rate per check (high dismissal suggests too-strict default)
- False-negative reports from users (suggests too-lax)
- Decisions-log amendment if a default needs changing

## Cross-references

- `rescan_policies` (consolidated) — sibling resolution-side policies
- `severity_enum` — closed enum
- `redaction_policies` — pre-AI-call redaction
- `gateway_bypass_detection_policy` — AI Privacy Gateway routing
- `plain_language_pipeline_prompt` — Tier 3 prompt
- `audit_log_policies` — `END_SCAN_*` events
- `live_integration_test_runbook` — drift-report cycle
- `issue_type_to_group_mapping` — End-Scan findings route per their issue_type
- Block 01 — Principle 3 (rules decide, AI explains)
- Block 06 Phase 11 — End-Scan engine (architecture)
- Block 14 Phase 08 — re-scan on resolution (consumer)
- Stage 1 decision — affected-only re-scan
